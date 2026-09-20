-- =============================================
-- Phase 1: Analytical Dry Run (Count Only)
-- Checks NOT_FOUND directly against Group Target Table
-- =============================================

CREATE OR REPLACE PROCEDURE run_data_deletion_dry_run(
    p_batch_id       VARCHAR,
    p_key_type       VARCHAR DEFAULT NULL,  -- NULL = run ALL key_types in this batch
    p_group_code     VARCHAR DEFAULT NULL   -- NULL = run ALL matching table groups
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_grp             RECORD;
    v_rule            RECORD;
    v_top_rule        RECORD;
    v_estimated_count BIGINT;
    v_all_keys        VARCHAR[];
    v_sql             TEXT;
    v_not_found_count BIGINT;
    v_validated_count BIGINT;
    v_tasks_created   BIGINT;
    v_groups_run      INT := 0;
BEGIN
    RAISE NOTICE '==================================================';
    RAISE NOTICE '[DRY RUN] Starting for Batch: % | Filter KeyType: % | Filter Group: %',
        p_batch_id, COALESCE(p_key_type, 'ALL'), COALESCE(p_group_code, 'ALL');
    RAISE NOTICE '==================================================';

    -- Step 1: Task Expansion (Expand raw staging items into group deletion tasks)
    INSERT INTO staging_deletion_task (batch_id, item_id, group_code, key_no, status)
    SELECT 
        s.batch_id, 
        s.id, 
        g.group_code, 
        s.key_no, 
        'PENDING'
    FROM staging_deletion_item s
    JOIN deletion_group g ON g.key_type = s.key_type AND g.is_active = TRUE
    WHERE s.batch_id = p_batch_id
      AND (p_key_type IS NULL OR s.key_type = p_key_type)
      AND (p_group_code IS NULL OR g.group_code = p_group_code)
    ON CONFLICT (batch_id, group_code, key_no) DO NOTHING;
    GET DIAGNOSTICS v_tasks_created = ROW_COUNT;
    RAISE NOTICE '[DRY RUN] Task Expansion completed: % task(s) mapped/created', v_tasks_created;

    -- Step 2: Iterate through all active groups that have tasks in this batch
    FOR v_grp IN (
        SELECT DISTINCT g.group_code, g.key_type
        FROM staging_deletion_task t
        JOIN deletion_group g ON g.group_code = t.group_code
        WHERE t.batch_id = p_batch_id
          AND g.is_active = TRUE
          AND (p_group_code IS NULL OR g.group_code = p_group_code)
          AND (p_key_type IS NULL OR g.key_type = p_key_type)
        ORDER BY g.group_code
    ) LOOP
        v_groups_run := v_groups_run + 1;

        RAISE NOTICE '--------------------------------------------------';
        RAISE NOTICE '[DRY RUN] Processing GROUP: % (KeyType: %) | Batch: %', 
            v_grp.group_code, v_grp.key_type, p_batch_id;
        RAISE NOTICE '--------------------------------------------------';

        -- Clear previous dry run results for this batch and group
        DELETE FROM deletion_dry_run_summary 
        WHERE batch_id = p_batch_id AND group_code = v_grp.group_code;

        -- Step 3: Find top-level target table (highest execution_order) to check existence directly
        SELECT target_table, where_clause_template
        INTO v_top_rule
        FROM deletion_rule
        WHERE group_code = v_grp.group_code
        ORDER BY execution_order DESC
        LIMIT 1;

        -- Check NOT_FOUND directly against Target Table
        IF v_top_rule.target_table IS NOT NULL AND v_top_rule.where_clause_template IS NOT NULL THEN
            v_sql := format('
                UPDATE staging_deletion_task t
                SET status = ''NOT_FOUND''
                WHERE t.batch_id = %L AND t.group_code = %L AND t.status = ''PENDING''
                  AND NOT EXISTS (
                      SELECT 1 FROM %I %s
                  )',
                p_batch_id, v_grp.group_code, v_top_rule.target_table,
                replace(v_top_rule.where_clause_template, '$1', 'ARRAY[t.key_no]'));

            RAISE NOTICE '[DRY RUN][%] Checking NOT_FOUND directly against Target Table: %...',
                v_grp.group_code, v_top_rule.target_table;
            EXECUTE v_sql;
            GET DIAGNOSTICS v_not_found_count = ROW_COUNT;
            RAISE NOTICE '[DRY RUN][%] Not Found keys (no rows in target table): %', 
                v_grp.group_code, v_not_found_count;
        END IF;

        -- All remaining PENDING -> VALIDATED
        UPDATE staging_deletion_task
        SET status = 'VALIDATED'
        WHERE batch_id = p_batch_id AND group_code = v_grp.group_code AND status = 'PENDING';
        GET DIAGNOSTICS v_validated_count = ROW_COUNT;
        RAISE NOTICE '[DRY RUN][%] Validated keys: %', v_grp.group_code, v_validated_count;

        -- Collect all validated keys for this group
        SELECT ARRAY(
            SELECT key_no FROM staging_deletion_task
            WHERE batch_id = p_batch_id AND group_code = v_grp.group_code AND status = 'VALIDATED'
        ) INTO v_all_keys;

        -- Count estimated rows for each target table bottom-up
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
        RAISE NOTICE 'No matching active groups/tasks found for Batch "%" (KeyType: %, Group: %)',
            p_batch_id, COALESCE(p_key_type, 'ALL'), COALESCE(p_group_code, 'ALL');
    ELSE
        RAISE NOTICE '=== Dry Run Complete for % group(s) in Batch % ===', v_groups_run, p_batch_id;
    END IF;
END;
$$;
