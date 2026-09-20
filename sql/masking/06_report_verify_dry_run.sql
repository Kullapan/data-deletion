-- =============================================================================
-- Data Masking System: Verification Reports for Dry Run
-- Run these queries after calling run_data_masking_dry_run(:batch_id)
-- =============================================================================

\set batch_id 'MASK-2026-TEST'

-- 1. Overall Task Status Breakdown (VALIDATED vs NOT_FOUND)
SELECT 
    group_code,
    status,
    COUNT(*) AS task_count,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (PARTITION BY group_code), 2) AS pct
FROM staging_masking_task
WHERE batch_id = :'batch_id'
GROUP BY group_code, status
ORDER BY group_code, status;

-- 2. Estimated Rows to Mask per Table and Column
SELECT 
    group_code,
    target_table,
    column_name,
    execution_order,
    mask_expression,
    estimated_rows_to_mask
FROM masking_dry_run_summary
WHERE batch_id = :'batch_id'
ORDER BY group_code, execution_order, target_table, column_name;

-- 3. Data Privacy Officer (DPO) Sample Preview Inspection
-- Unpacks Before vs After values to verify masking compliance
SELECT 
    s.group_code,
    s.target_table,
    s.column_name,
    s.mask_expression,
    p.sample_index,
    p.preview->>'before' AS sample_original_value,
    p.preview->>'after'  AS sample_masked_value
FROM masking_dry_run_summary s,
     jsonb_array_elements(s.sample_preview) WITH ORDINALITY AS p(preview, sample_index)
WHERE s.batch_id = :'batch_id'
ORDER BY s.group_code, s.target_table, s.column_name, p.sample_index;

-- 4. Not Found Keys (Keys in Excel but absent from database)
SELECT 
    group_code,
    key_no,
    status,
    created_at
FROM staging_masking_task
WHERE batch_id = :'batch_id' AND status = 'NOT_FOUND'
LIMIT 50;
