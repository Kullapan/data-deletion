-- =============================================================================
-- Data Masking System: Procedure run_data_masking_dry_run
-- Engine: PostgreSQL 16+
-- Analytical Dry Run:
--   1. Expands 1:N Tasks from staging_masking_item to staging_masking_task
--   2. Validates keys against target table (sets VALIDATED vs NOT_FOUND)
--   3. Computes estimated rows to mask for each configured rule
--   4. Samples up to 5 rows and generates Before/After preview JSON for DPO approval
-- =============================================================================

CREATE OR REPLACE PROCEDURE run_data_masking_dry_run(
    p_batch_id   VARCHAR(100),
    p_group_code VARCHAR(50) DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_group_record          RECORD;
    v_rule_record           RECORD;
    v_validated_keys        TEXT[];
    v_all_keys              TEXT[];
    v_count_sql             TEXT;
    v_sample_sql            TEXT;
    v_estimated_rows        BIGINT;
    v_sample_json           JSONB;
    v_items_count           INT;
    v_tasks_count           INT;
    v_not_found_count       INT;
    v_validated_count       INT;
    v_root_table            VARCHAR(100);
    v_root_where            TEXT;
    v_validate_sql          TEXT;
BEGIN
    RAISE NOTICE '================================================================================';
    RAISE NOTICE '🚀 Starting Data Masking Analytical Dry Run for Batch: %', p_batch_id;
    RAISE NOTICE '================================================================================';

    -- 1. Check if batch exists in staging_masking_item
    SELECT COUNT(*) INTO v_items_count
    FROM staging_masking_item
    WHERE batch_id = p_batch_id;

    IF v_items_count = 0 THEN
        RAISE EXCEPTION 'Batch % has no records in staging_masking_item!', p_batch_id;
    END IF;

    RAISE NOTICE '📦 Total Master Keys in staging_masking_item: %', v_items_count;

    -- 2. Clear previous Dry Run summary for this batch
    IF p_group_code IS NOT NULL THEN
        DELETE FROM masking_dry_run_summary WHERE batch_id = p_batch_id AND group_code = p_group_code;
    ELSE
        DELETE FROM masking_dry_run_summary WHERE batch_id = p_batch_id;
    END IF;

    -- 3. Loop through active groups
    FOR v_group_record IN
        SELECT g.group_code, g.key_type, g.chunk_size, g.throttle_sec
        FROM masking_group g
        WHERE g.is_active = TRUE
          AND (p_group_code IS NULL OR g.group_code = p_group_code)
          AND EXISTS (
              SELECT 1 FROM staging_masking_item i
              WHERE i.batch_id = p_batch_id AND i.key_type = g.key_type
          )
        ORDER BY g.group_code
    LOOP
        RAISE NOTICE '--------------------------------------------------------------------------------';
        RAISE NOTICE '👉 Processing Masking Group: % (Key Type: %)', v_group_record.group_code, v_group_record.key_type;

        -- 3.1 Task Expansion: Insert into staging_masking_task
        INSERT INTO staging_masking_task (batch_id, group_code, key_no, status)
        SELECT i.batch_id, v_group_record.group_code, i.key_no, 'PENDING'
        FROM staging_masking_item i
        WHERE i.batch_id = p_batch_id
          AND i.key_type = v_group_record.key_type
        ON CONFLICT (batch_id, group_code, key_no) DO NOTHING;

        -- 3.2 Determine primary validation table from rules (lowest execution order)
        SELECT target_table, where_clause_template
        INTO v_root_table, v_root_where
        FROM masking_rule
        WHERE group_code = v_group_record.group_code
          AND is_active = TRUE
        ORDER BY execution_order ASC, id ASC
        LIMIT 1;

        IF v_root_table IS NULL THEN
            RAISE NOTICE '⚠️ No active masking rules configured for group %, skipping validation.', v_group_record.group_code;
            CONTINUE;
        END IF;

        -- 3.3 Validate keys against target table
        SELECT array_agg(key_no) INTO v_all_keys
        FROM staging_masking_task
        WHERE batch_id = p_batch_id
          AND group_code = v_group_record.group_code;

        IF v_all_keys IS NOT NULL AND array_length(v_all_keys, 1) > 0 THEN
            -- Check which keys exist
            v_validate_sql := format(
                'UPDATE staging_masking_task t ' ||
                'SET status = CASE WHEN EXISTS (SELECT 1 FROM %I %s) THEN ''VALIDATED'' ELSE ''NOT_FOUND'' END ' ||
                'WHERE t.batch_id = %L AND t.group_code = %L AND t.key_no = ANY($1)',
                v_root_table,
                replace(v_root_where, '$1', 'ARRAY[t.key_no]'),
                p_batch_id,
                v_group_record.group_code
            );
            EXECUTE v_validate_sql USING v_all_keys;
        END IF;

        SELECT COUNT(*) INTO v_not_found_count
        FROM staging_masking_task
        WHERE batch_id = p_batch_id AND group_code = v_group_record.group_code AND status = 'NOT_FOUND';

        SELECT COUNT(*) INTO v_validated_count
        FROM staging_masking_task
        WHERE batch_id = p_batch_id AND group_code = v_group_record.group_code AND status = 'VALIDATED';

        RAISE NOTICE '   Key Validation: VALIDATED = %, NOT_FOUND = %', v_validated_count, v_not_found_count;

        -- Get array of validated keys for this group
        SELECT array_agg(key_no) INTO v_validated_keys
        FROM staging_masking_task
        WHERE batch_id = p_batch_id
          AND group_code = v_group_record.group_code
          AND status = 'VALIDATED';

        IF v_validated_keys IS NULL OR array_length(v_validated_keys, 1) = 0 THEN
            RAISE NOTICE '   ⚠️ No VALIDATED keys found to estimate masking for group %.', v_group_record.group_code;
            CONTINUE;
        END IF;

        -- 3.4 Process each rule: Estimate Count and Generate Sample Preview
        FOR v_rule_record IN
            SELECT r.id, r.target_table, r.column_name, r.mask_expression, r.execution_order, r.where_clause_template
            FROM masking_rule r
            WHERE r.group_code = v_group_record.group_code
              AND r.is_active = TRUE
            ORDER BY r.execution_order ASC, r.id ASC
        LOOP
            -- Build dynamic COUNT query
            v_count_sql := format(
                'SELECT COUNT(*) FROM %I %s',
                v_rule_record.target_table,
                v_rule_record.where_clause_template
            );
            EXECUTE v_count_sql INTO v_estimated_rows USING v_validated_keys;

            -- Build dynamic Before/After preview JSON (Up to 5 samples)
            -- Evaluates both the original column value and the configured mask_expression
            v_sample_sql := format(
                'SELECT COALESCE(jsonb_agg(jsonb_build_object(''before'', sub.original_val, ''after'', sub.masked_val)), ''[]''::jsonb) ' ||
                'FROM (' ||
                '  SELECT %I::text AS original_val, (%s)::text AS masked_val ' ||
                '  FROM %I %s ' ||
                '  AND %I IS NOT NULL ' ||
                '  LIMIT 5' ||
                ') sub',
                v_rule_record.column_name,
                v_rule_record.mask_expression,
                v_rule_record.target_table,
                v_rule_record.where_clause_template,
                v_rule_record.column_name
            );

            BEGIN
                EXECUTE v_sample_sql INTO v_sample_json USING v_validated_keys;
            EXCEPTION WHEN OTHERS THEN
                RAISE WARNING '   Could not generate sample preview for %.%: %', 
                    v_rule_record.target_table, v_rule_record.column_name, SQLERRM;
                v_sample_json := '[]'::jsonb;
            END;

            -- Record summary
            INSERT INTO masking_dry_run_summary (
                batch_id, group_code, target_table, column_name,
                execution_order, mask_expression, estimated_rows_to_mask, sample_preview
            )
            VALUES (
                p_batch_id, v_group_record.group_code, v_rule_record.target_table, v_rule_record.column_name,
                v_rule_record.execution_order, v_rule_record.mask_expression, v_estimated_rows, v_sample_json
            )
            ON CONFLICT (batch_id, group_code, target_table, column_name)
            DO UPDATE SET
                execution_order = EXCLUDED.execution_order,
                mask_expression = EXCLUDED.mask_expression,
                estimated_rows_to_mask = EXCLUDED.estimated_rows_to_mask,
                sample_preview = EXCLUDED.sample_preview,
                created_at = NOW();

            RAISE NOTICE '   ✅ Rule [%.%] (Order %): ~% rows | Logic: %',
                v_rule_record.target_table, v_rule_record.column_name,
                v_rule_record.execution_order, v_estimated_rows, v_rule_record.mask_expression;
        END LOOP;

    END LOOP;

    RAISE NOTICE '================================================================================';
    RAISE NOTICE '🎉 Data Masking Dry Run Completed Successfully for Batch: %', p_batch_id;
    RAISE NOTICE '💡 Review sample previews: SELECT * FROM masking_dry_run_summary WHERE batch_id = %L;', p_batch_id;
    RAISE NOTICE '================================================================================';
END;
$$;
