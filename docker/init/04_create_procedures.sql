-- =============================================
-- Stored Procedures: Dry Run & Real Deletion
-- Auto-loaded by Docker on first container start
-- Supports running a single group or ALL groups in one command
-- =============================================

-- =============================================
-- Phase 1: Analytical Dry Run (Count Only)
-- =============================================

CREATE OR REPLACE PROCEDURE run_data_deletion_dry_run(
    p_batch_id       VARCHAR,
    p_group_code     VARCHAR DEFAULT NULL,  -- NULL = run ALL groups in this batch
    p_parent_table   VARCHAR DEFAULT NULL,  -- Optional override
    p_parent_key_col VARCHAR DEFAULT NULL   -- Optional override
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_grp             RECORD;
    v_rule            RECORD;
    v_estimated_count BIGINT;
    v_all_keys        VARCHAR[];
    v_sql             TEXT;
    v_not_found_count BIGINT;
    v_validated_count BIGINT;
    v_parent_table    VARCHAR;
    v_parent_key_col  VARCHAR;
    v_groups_run      INT := 0;
BEGIN
    FOR v_grp IN (
        SELECT DISTINCT g.group_code, g.parent_table, g.parent_key_col
        FROM staging_deletion_item s
        JOIN deletion_group g ON g.group_code = s.group_code
        WHERE s.batch_id = p_batch_id
          AND g.is_active = TRUE
          AND (p_group_code IS NULL OR g.group_code = p_group_code)
        ORDER BY g.group_code
    ) LOOP
        v_groups_run := v_groups_run + 1;

        RAISE NOTICE '==================================================';
        RAISE NOTICE '[DRY RUN] GROUP: % | Batch: %', v_grp.group_code, p_batch_id;
        RAISE NOTICE '==================================================';

        v_parent_table := COALESCE(p_parent_table, v_grp.parent_table);
        v_parent_key_col := COALESCE(p_parent_key_col, v_grp.parent_key_col);

        DELETE FROM deletion_dry_run_summary 
        WHERE batch_id = p_batch_id AND group_code = v_grp.group_code;

        IF v_parent_table IS NOT NULL AND v_parent_key_col IS NOT NULL THEN
            v_sql := format('
                UPDATE staging_deletion_item s
                SET status = ''NOT_FOUND''
                WHERE s.batch_id = %L AND s.group_code = %L AND s.status = ''PENDING''
                  AND NOT EXISTS (SELECT 1 FROM %I p WHERE p.%I = s.key_no)',
                p_batch_id, v_grp.group_code, v_parent_table, v_parent_key_col);

            RAISE NOTICE '[DRY RUN][%] Checking Not Found against % (%)...',
                v_grp.group_code, v_parent_table, v_parent_key_col;
            EXECUTE v_sql;
            GET DIAGNOSTICS v_not_found_count = ROW_COUNT;
            RAISE NOTICE '[DRY RUN][%] Not Found keys: %', v_grp.group_code, v_not_found_count;
        END IF;

        UPDATE staging_deletion_item
        SET status = 'VALIDATED'
        WHERE batch_id = p_batch_id AND group_code = v_grp.group_code AND status = 'PENDING';
        GET DIAGNOSTICS v_validated_count = ROW_COUNT;
        RAISE NOTICE '[DRY RUN][%] Validated keys: %', v_grp.group_code, v_validated_count;

        SELECT ARRAY(
            SELECT key_no FROM staging_deletion_item
            WHERE batch_id = p_batch_id AND group_code = v_grp.group_code AND status = 'VALIDATED'
        ) INTO v_all_keys;

        FOR v_rule IN (
            SELECT target_table, execution_order, where_clause_template
            FROM deletion_rule
            WHERE group_code = v_grp.group_code
            ORDER BY execution_order ASC
        ) LOOP
            v_sql := format('SELECT COUNT(*) FROM %I %s',
                v_rule.target_table, v_rule.where_clause_template);

            RAISE NOTICE '[DRY RUN][%] Table: % (order %) | SQL: %',
                v_grp.group_code, v_rule.target_table, v_rule.execution_order, v_sql;

            EXECUTE v_sql INTO v_estimated_count USING v_all_keys;

            INSERT INTO deletion_dry_run_summary (
                batch_id, group_code, target_table, execution_order, estimated_rows_to_delete
            ) VALUES (
                p_batch_id, v_grp.group_code, v_rule.target_table, 
                v_rule.execution_order, v_estimated_count
            );

            RAISE NOTICE '[DRY RUN][%] Table: % -> estimated rows to delete: %',
                v_grp.group_code, v_rule.target_table, v_estimated_count;
        END LOOP;

        COMMIT;
    END LOOP;

    IF v_groups_run = 0 THEN
        RAISE NOTICE 'No active groups with items found for Batch "%" (Filter: %)',
            p_batch_id, COALESCE(p_group_code, 'ALL');
    ELSE
        RAISE NOTICE '=== Dry Run Complete for % group(s) in Batch % ===', v_groups_run, p_batch_id;
    END IF;
END;
$$;


-- =============================================
-- Phase 2: Real Deletion (Bottom-Up Safe, Granular)
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

        LOOP
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

            IF v_chunk_keys IS NULL OR array_length(v_chunk_keys, 1) IS NULL THEN
                EXIT;
            END IF;

            v_chunk_count := v_chunk_count + 1;
            RAISE NOTICE '--- [%] Chunk #% | Keys: % ---', 
                v_grp.group_code, v_chunk_count, array_length(v_chunk_keys, 1);

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

            IF v_max_order = (SELECT MAX(execution_order) FROM deletion_rule WHERE group_code = v_grp.group_code) THEN
                UPDATE staging_deletion_item
                SET status = 'COMPLETED', processed_at = CURRENT_TIMESTAMP
                WHERE batch_id = p_batch_id AND group_code = v_grp.group_code AND key_no = ANY(v_chunk_keys);
            ELSE
                UPDATE staging_deletion_item
                SET status = 'PARTIAL_COMPLETED', processed_at = CURRENT_TIMESTAMP
                WHERE batch_id = p_batch_id AND group_code = v_grp.group_code AND key_no = ANY(v_chunk_keys);
            END IF;

            COMMIT;

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
