-- =============================================================================
-- Data Masking System: Procedure run_data_masking
-- Engine: PostgreSQL 16+
-- Chunked Micro-Transactions Real Masking:
--   1. Processes tasks in chunks (FOR UPDATE SKIP LOCKED LIMIT chunk_size)
--   2. Groups rules by target_table to produce single composite UPDATE per table
--   3. Executes dynamically configured mask_expression directly from masking_rule
--   4. Micro-transaction COMMIT per chunk with configurable pg_sleep throttle
--   5. Logs audit records into masking_audit_log
-- =============================================================================

CREATE OR REPLACE PROCEDURE run_data_masking(
    p_batch_id   VARCHAR(100),
    p_group_code VARCHAR(50) DEFAULT NULL,
    p_max_order  INT DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_group_record          RECORD;
    v_table_record          RECORD;
    v_chunk_keys            TEXT[];
    v_chunk_task_ids        BIGINT[];
    v_chunk_size            INT;
    v_throttle_sec          NUMERIC;
    v_set_clause            TEXT;
    v_where_template        TEXT;
    v_update_sql            TEXT;
    v_rows_affected         BIGINT;
    v_chunk_num             INT := 0;
    v_start_time            TIMESTAMPTZ;
    v_duration              NUMERIC;
    v_columns_list          TEXT;
    v_has_more              BOOLEAN := TRUE;
    v_total_updated         BIGINT := 0;
BEGIN
    RAISE NOTICE '================================================================================';
    RAISE NOTICE '🚀 Starting Real Data Masking Engine for Batch: %', p_batch_id;
    RAISE NOTICE '================================================================================';

    -- Loop through active groups
    FOR v_group_record IN
        SELECT g.group_code, g.key_type, COALESCE(g.chunk_size, 500) AS chunk_size, COALESCE(g.throttle_sec, 0.05) AS throttle_sec
        FROM masking_group g
        WHERE g.is_active = TRUE
          AND (p_group_code IS NULL OR g.group_code = p_group_code)
          AND EXISTS (
              SELECT 1 FROM staging_masking_task t
              WHERE t.batch_id = p_batch_id
                AND t.group_code = g.group_code
                AND t.status = 'VALIDATED'
          )
        ORDER BY g.group_code
    LOOP
        v_chunk_size := v_group_record.chunk_size;
        v_throttle_sec := v_group_record.throttle_sec;
        v_chunk_num := 0;
        v_has_more := TRUE;

        RAISE NOTICE '--------------------------------------------------------------------------------';
        RAISE NOTICE '👉 Masking Group: % | Chunk Size: % | Throttle: %s',
            v_group_record.group_code, v_chunk_size, v_throttle_sec;

        -- Process in Chunks
        WHILE v_has_more LOOP
            v_chunk_num := v_chunk_num + 1;
            v_start_time := clock_timestamp();

            -- 1. Fetch chunk of VALIDATED tasks using FOR UPDATE SKIP LOCKED
            SELECT array_agg(id), array_agg(key_no)
            INTO v_chunk_task_ids, v_chunk_keys
            FROM (
                SELECT id, key_no
                FROM staging_masking_task
                WHERE batch_id = p_batch_id
                  AND group_code = v_group_record.group_code
                  AND status = 'VALIDATED'
                ORDER BY id ASC
                LIMIT v_chunk_size
                FOR UPDATE SKIP LOCKED
            ) sub;

            -- If no more tasks, terminate loop for this group
            IF v_chunk_keys IS NULL OR array_length(v_chunk_keys, 1) = 0 THEN
                v_has_more := FALSE;
                EXIT;
            END IF;

            -- 2. Process masking by Target Table (grouping columns to issue 1 UPDATE per table)
            FOR v_table_record IN
                SELECT 
                    r.target_table,
                    r.where_clause_template,
                    r.execution_order,
                    string_agg(format('%I = (%s)', r.column_name, r.mask_expression), ', ') AS set_clause,
                    string_agg(r.column_name, ', ') AS columns_list
                FROM masking_rule r
                WHERE r.group_code = v_group_record.group_code
                  AND r.is_active = TRUE
                  AND (p_max_order IS NULL OR r.execution_order <= p_max_order)
                GROUP BY r.target_table, r.where_clause_template, r.execution_order
                ORDER BY r.execution_order ASC
            LOOP
                -- Compile dynamic composite UPDATE statement
                v_update_sql := format(
                    'UPDATE %I SET %s %s',
                    v_table_record.target_table,
                    v_table_record.set_clause,
                    v_table_record.where_clause_template
                );

                -- Execute UPDATE with chunk keys array
                EXECUTE v_update_sql USING v_chunk_keys;
                GET DIAGNOSTICS v_rows_affected = ROW_COUNT;
                v_total_updated := v_total_updated + v_rows_affected;

                -- Log into Audit Trail
                v_duration := EXTRACT(EPOCH FROM (clock_timestamp() - v_start_time));
                INSERT INTO masking_audit_log (
                    batch_id, group_code, target_table, columns_masked,
                    masked_row_count, chunk_number, duration_sec, processed_at
                )
                VALUES (
                    p_batch_id, v_group_record.group_code, v_table_record.target_table,
                    v_table_record.columns_list, v_rows_affected, v_chunk_num,
                    ROUND(v_duration, 3), NOW()
                );

                RAISE NOTICE '   [Chunk #%] Table %: masked % rows on columns [%] (% s)',
                    v_chunk_num, v_table_record.target_table, v_rows_affected,
                    v_table_record.columns_list, ROUND(v_duration, 3);
            END LOOP;

            -- 3. Mark tasks as COMPLETED
            UPDATE staging_masking_task
            SET status = 'COMPLETED', processed_at = NOW()
            WHERE id = ANY(v_chunk_task_ids);

            -- 4. Micro-transaction COMMIT
            COMMIT;

            -- 5. Throttle pause
            IF v_throttle_sec > 0 THEN
                PERFORM pg_sleep(v_throttle_sec);
            END IF;

        END LOOP;

        RAISE NOTICE '🏁 Group % processing finished. Total chunks: %', v_group_record.group_code, v_chunk_num;

    END LOOP;

    RAISE NOTICE '================================================================================';
    RAISE NOTICE '🎉 Data Masking Engine Completed Successfully for Batch: %', p_batch_id;
    RAISE NOTICE '📊 Total Records Masked: %', v_total_updated;
    RAISE NOTICE '================================================================================';
END;
$$;
