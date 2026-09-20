-- ============================================================================
-- Verification Report: Phase 1 - Analytical Dry Run (Target Table Level)
-- Script: sql/05_report_verify_dry_run.sql
-- Purpose: Verify Task Mapping, Key Validation against Target Tables,
--          identify NOT_FOUND exceptions, and generate Business Sign-off summary
--          at the TARGET TABLE level.
-- Usage:
--   psql -h localhost -U postgres -d deletion_db -v target_batch='BATCH-2025' -f sql/05_report_verify_dry_run.sql
-- ============================================================================

-- กำหนดรหัส Batch ที่ต้องการตรวจสอบ (เปิดคอมเมนต์เมื่อรันใน pgAdmin/DBeaver หรือส่งผ่าน CLI: psql -v target_batch='YOUR_BATCH')
-- \set target_batch 'BATCH-2025'


\echo '============================================================================'
\echo 'REPORT 1: Ingestion & Target Table Mapping Verification'
\echo 'วัตถุประสงค์: ตรวจสอบจำนวน Master Keys จากไฟล์เทียบกับ Tasks ที่กระจายลงสู่ Target Tables'
\echo '============================================================================'

SELECT 
    r.target_table,
    r.execution_order,
    i.key_type,
    COUNT(DISTINCT i.key_no) AS master_keys_count,
    COUNT(t.id) AS mapped_tasks_count,
    MIN(i.created_at) AS ingested_at
FROM staging_deletion_item i
JOIN staging_deletion_task t ON t.item_id = i.id
JOIN deletion_rule r ON r.group_code = t.group_code
WHERE i.batch_id = :'target_batch'
GROUP BY r.target_table, r.execution_order, i.key_type
ORDER BY r.execution_order;


\echo ''
\echo '============================================================================'
\echo 'REPORT 2: Task Validation Summary & Match Rate (per Target Table)'
\echo 'วัตถุประสงค์: ตรวจสอบสัดส่วนคีย์ที่พบ (VALIDATED/COMPLETED) vs ไม่พบ (NOT_FOUND) รายตาราง'
\echo '============================================================================'

SELECT 
    r.target_table,
    r.execution_order,
    COUNT(t.id) AS total_tasks,
    COUNT(*) FILTER (WHERE t.status IN ('VALIDATED', 'COMPLETED')) AS valid_matched_keys,
    COUNT(*) FILTER (WHERE t.status = 'NOT_FOUND') AS not_found_keys,
    COUNT(*) FILTER (WHERE t.status = 'PENDING') AS pending_tasks,
    ROUND(
        COUNT(*) FILTER (WHERE t.status IN ('VALIDATED', 'COMPLETED')) * 100.0 / NULLIF(COUNT(t.id), 0), 
        2
    ) AS match_rate_pct
FROM staging_deletion_task t
JOIN deletion_rule r ON r.group_code = t.group_code
WHERE t.batch_id = :'target_batch'
GROUP BY r.target_table, r.execution_order
ORDER BY r.execution_order;


\echo ''
\echo '============================================================================'
\echo 'REPORT 3: Exception List: Missing Keys (NOT_FOUND List per Root Target Table)'
\echo 'วัตถุประสงค์: รายการคีย์ที่ไม่พบข้อมูลในตารางหลัก สำหรับส่งกลับให้ Data Owner ตรวจสอบ'
\echo '============================================================================'

SELECT 
    r.target_table AS root_target_table,
    i.key_type,
    t.key_no,
    t.status,
    t.created_at
FROM staging_deletion_task t
JOIN staging_deletion_item i ON i.id = t.item_id
JOIN deletion_rule r ON r.group_code = t.group_code AND r.execution_order = (
    SELECT MAX(r2.execution_order) FROM deletion_rule r2 WHERE r2.group_code = t.group_code
)
WHERE t.batch_id = :'target_batch'
  AND t.status = 'NOT_FOUND'
ORDER BY r.target_table, t.key_no;


\echo ''
\echo '============================================================================'
\echo 'REPORT 4: Bottom-Up Estimated Rows to Delete (per Target Table)'
\echo 'วัตถุประสงค์: ประมาณการจำนวนแถวที่จะถูกลบจริงในแต่ละตารางเป้าหมายตามลำดับ Bottom-Up'
\echo '============================================================================'

SELECT 
    target_table,
    execution_order,
    estimated_rows_to_delete,
    executed_at AS estimated_at
FROM deletion_dry_run_summary
WHERE batch_id = :'target_batch'
ORDER BY execution_order;


\echo ''
\echo '============================================================================'
\echo 'REPORT 5: Formal Executive Sign-off Summary (Target Table Level)'
\echo 'วัตถุประสงค์: รายงานสรุปภาพรวมรายตารางสำหรับแนบเอกสารขออนุมัติลบข้อมูล (Sign-off Template)'
\echo '============================================================================'

WITH item_stats AS (
    SELECT 
        batch_id,
        COUNT(DISTINCT key_no) AS total_master_keys,
        string_agg(DISTINCT key_type, ', ') AS key_types
    FROM staging_deletion_item
    WHERE batch_id = :'target_batch'
    GROUP BY batch_id
),
table_task_stats AS (
    SELECT 
        t.batch_id,
        r.target_table,
        r.execution_order,
        COUNT(t.id) AS total_tasks,
        COUNT(*) FILTER (WHERE t.status IN ('VALIDATED', 'COMPLETED')) AS valid_matched_keys,
        COUNT(*) FILTER (WHERE t.status = 'NOT_FOUND') AS not_found_keys
    FROM staging_deletion_task t
    JOIN deletion_rule r ON r.group_code = t.group_code
    WHERE t.batch_id = :'target_batch'
    GROUP BY t.batch_id, r.target_table, r.execution_order
)
SELECT 
    t.batch_id,
    t.target_table,
    t.execution_order,
    i.key_types,
    i.total_master_keys,
    t.valid_matched_keys,
    t.not_found_keys,
    ROUND(t.valid_matched_keys * 100.0 / NULLIF(t.total_tasks, 0), 2) AS match_rate_pct,
    COALESCE(d.estimated_rows_to_delete, 0) AS estimated_rows_to_purge
FROM table_task_stats t
JOIN item_stats i ON t.batch_id = i.batch_id
LEFT JOIN deletion_dry_run_summary d 
       ON d.batch_id = t.batch_id 
      AND d.target_table = t.target_table 
      AND d.execution_order = t.execution_order
ORDER BY t.execution_order;
