-- =============================================
-- Phase 2: Real Deletion (Bottom-Up Safe, Granular)
-- Supports running a single group or ALL groups in a batch
-- =============================================

CREATE OR REPLACE PROCEDURE run_data_deletion(
    p_batch_id     VARCHAR,
    p_group_code   VARCHAR DEFAULT NULL,  -- NULL = delete ALL groups in this batch
    p_up_to_order  INT DEFAULT NULL       -- NULL = all levels; or up to specific order
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_grp           RECORD;
    v_chunk_size    INT;
    v_throttle_sec  NUMERIC;
    v_chunk_keys    VARCHAR[];
    v_rule          RECORD;
    v_deleted_count BIGINT;
    v_chunk_count   INT;
    v_max_order     INT;
    v_sql           TEXT;
    v_groups_run    INT := 0;
BEGIN
    -- Iterate through all active groups with VALIDATED keys in this batch
    FOR v_grp IN (
        SELECT DISTINCT g.group_code, g.chunk_size, g.throttle_sec
        FROM staging_deletion_item s
        JOIN deletion_group g ON g.group_code = s.group_code
        WHERE s.batch_id = p_batch_id
          AND s.status = 'VALIDATED'
          AND g.is_active = TRUE
          AND (p_group_code IS NULL OR g.group_code = p_group_code)
        ORDER BY g.group_code
    ) LOOP
        v_groups_run := v_groups_run + 1;
        v_chunk_size := v_grp.chunk_size;
        v_throttle_sec := v_grp.throttle_sec;
        v_chunk_count := 0;

        -- Determine deletion scope for this group
        IF p_up_to_order IS NULL THEN
            SELECT MAX(execution_order) INTO v_max_order
            FROM deletion_rule WHERE group_code = v_grp.group_code;
        ELSE
            v_max_order := p_up_to_order;
        END IF;

        RAISE NOTICE '==================================================';
        RAISE NOTICE 'STARTING DELETION: GROUP % | Batch: %', v_grp.group_code, p_batch_id;
        RAISE NOTICE '  Chunk Size: %', v_chunk_size;
        RAISE NOTICE '  Throttle:   % sec', v_throttle_sec;
        RAISE NOTICE '  Run orders: 1 -> %', v_max_order;
        RAISE NOTICE '==================================================';

        -- Chunk processing loop for this group
        LOOP
            -- Fetch next chunk of VALIDATED keys
            SELECT ARRAY(
                SELECT key_no 
                FROM staging_deletion_item
                WHERE batch_id = p_batch_id 
                  AND group_code = v_grp.group_code 
                  AND status = 'VALIDATED'
                ORDER BY id
                LIMIT v_chunk_size
                FOR UPDATE SKIP LOCKED
            ) INTO v_chunk_keys;

            -- No more keys -> exit chunk loop
            IF v_chunk_keys IS NULL OR array_length(v_chunk_keys, 1) IS NULL THEN
                EXIT;
            END IF;

            v_chunk_count := v_chunk_count + 1;
            RAISE NOTICE '--- [%] Chunk #% | Keys: % ---', 
                v_grp.group_code, v_chunk_count, array_length(v_chunk_keys, 1);

            -- Delete Bottom-Up (order 1 -> v_max_order)
            FOR v_rule IN (
                SELECT target_table, execution_order, where_clause_template
                FROM deletion_rule
                WHERE group_code = v_grp.group_code
                  AND execution_order <= v_max_order
                ORDER BY execution_order ASC
            ) LOOP
                v_sql := format('DELETE FROM %I %s', 
                    v_rule.target_table, v_rule.where_clause_template);

                RAISE NOTICE '[EXEC][%] Order % | %', v_grp.group_code, v_rule.execution_order, v_sql;

                EXECUTE v_sql USING v_chunk_keys;
                GET DIAGNOSTICS v_deleted_count = ROW_COUNT;

                INSERT INTO deletion_audit_log (
                    batch_id, group_code, target_table, deleted_row_count
                ) VALUES (
                    p_batch_id, v_grp.group_code, v_rule.target_table, v_deleted_count
                );

                RAISE NOTICE '  -> Deleted % rows from %', 
                    v_deleted_count, v_rule.target_table;
            END LOOP;

            -- Always update staging status to prevent infinite loop
            IF v_max_order = (SELECT MAX(execution_order) FROM deletion_rule WHERE group_code = v_grp.group_code) THEN
                UPDATE staging_deletion_item
                SET status = 'COMPLETED', processed_at = CURRENT_TIMESTAMP
                WHERE batch_id = p_batch_id AND group_code = v_grp.group_code AND key_no = ANY(v_chunk_keys);
            ELSE
                UPDATE staging_deletion_item
                SET status = 'PARTIAL_COMPLETED', processed_at = CURRENT_TIMESTAMP
                WHERE batch_id = p_batch_id AND group_code = v_grp.group_code AND key_no = ANY(v_chunk_keys);
            END IF;

            -- Micro-Transaction Commit
            COMMIT;

            -- Throttle
            IF v_throttle_sec > 0 THEN
                PERFORM pg_sleep(v_throttle_sec);
            END IF;
        END LOOP;

        RAISE NOTICE 'Group % completed. Total chunks processed: %', v_grp.group_code, v_chunk_count;
    END LOOP;

    IF v_groups_run = 0 THEN
        RAISE NOTICE 'No VALIDATED items found for Batch "%" (Filter: %)',
            p_batch_id, COALESCE(p_group_code, 'ALL');
    ELSE
        RAISE NOTICE '==================================================';
        RAISE NOTICE 'Batch % completed for % group(s).', p_batch_id, v_groups_run;
        RAISE NOTICE '==================================================';
    END IF;
END;
$$;
