-- =============================================================================
-- Data Masking System: Verification Reports for Real Masking
-- Run these queries after calling run_data_masking(:batch_id)
-- =============================================================================

\set batch_id 'MASK-2026-TEST'

-- 1. Masking Execution Progress & Status Breakdown
SELECT 
    group_code,
    status,
    COUNT(*) AS total_tasks,
    MIN(processed_at) AS first_processed,
    MAX(processed_at) AS last_processed
FROM staging_masking_task
WHERE batch_id = :'batch_id'
GROUP BY group_code, status
ORDER BY group_code, status;

-- 2. Audit Trail Summary per Target Table
SELECT 
    group_code,
    target_table,
    columns_masked,
    COUNT(*) AS total_chunks,
    SUM(masked_row_count) AS total_rows_masked,
    ROUND(AVG(masked_row_count), 1) AS avg_rows_per_chunk,
    ROUND(SUM(duration_sec), 2) AS total_duration_seconds,
    CASE 
        WHEN SUM(duration_sec) > 0 THEN ROUND(SUM(masked_row_count) / SUM(duration_sec), 0)
        ELSE 0 
    END AS rows_per_second
FROM masking_audit_log
WHERE batch_id = :'batch_id'
GROUP BY group_code, target_table, columns_masked
ORDER BY group_code, target_table;

-- 3. Chunk Timeline and Throughput
SELECT 
    chunk_number,
    target_table,
    masked_row_count,
    duration_sec,
    processed_at
FROM masking_audit_log
WHERE batch_id = :'batch_id'
ORDER BY chunk_number ASC
LIMIT 100;

-- 4. Verify Failed Tasks (if any)
SELECT 
    group_code,
    key_no,
    error_message,
    processed_at
FROM staging_masking_task
WHERE batch_id = :'batch_id' AND status = 'FAILED';
