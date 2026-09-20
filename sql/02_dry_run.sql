-- =============================================
-- Phase 1: Analytical Dry Run (Count Only)
-- Supports running a single group or ALL groups in a batch
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
    -- Iterate through all active groups that have items in this batch
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

        -- Determine parent table and key column (parameters override group table config)
        v_parent_table := COALESCE(p_parent_table, v_grp.parent_table);
        v_parent_key_col := COALESCE(p_parent_key_col, v_grp.parent_key_col);

        -- Clear previous dry run results for this batch and group
        DELETE FROM deletion_dry_run_summary 
        WHERE batch_id = p_batch_id AND group_code = v_grp.group_code;

        -- Check Not Found (if parent table configured or provided)
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

        -- All remaining PENDING -> VALIDATED
        UPDATE staging_deletion_item
        SET status = 'VALIDATED'
        WHERE batch_id = p_batch_id AND group_code = v_grp.group_code AND status = 'PENDING';
        GET DIAGNOSTICS v_validated_count = ROW_COUNT;
        RAISE NOTICE '[DRY RUN][%] Validated keys: %', v_grp.group_code, v_validated_count;

        -- Collect all validated keys
        SELECT ARRAY(
            SELECT key_no FROM staging_deletion_item
            WHERE batch_id = p_batch_id AND group_code = v_grp.group_code AND status = 'VALIDATED'
        ) INTO v_all_keys;

        -- Count estimated rows for each target table
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
