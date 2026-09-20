-- ============================================================================
-- Verification Report: Phase 2 - Real Deletion Execution & Audit (Target Table Level)
-- Script: sql/06_report_verify_real_deletion.sql
-- Purpose: Monitor execution progress, verify 100% reconciliation (Variance = 0),
--          audit throughput, check zero-leakage residual, and generate compliance certificate
--          at the TARGET TABLE level.
-- Usage:
--   psql -h localhost -U postgres -d deletion_db -v target_batch='BATCH-2025' -f sql/06_report_verify_real_deletion.sql
-- ============================================================================

-- กำหนดรหัส Batch ที่ต้องการตรวจสอบ (เปิดคอมเมนต์เมื่อรันใน pgAdmin/DBeaver หรือส่งผ่าน CLI: psql -v target_batch='YOUR_BATCH')
-- \set target_batch 'BATCH-2025'


\echo '============================================================================'
\echo 'REPORT 1: Task Execution Progress & Completion Audit (per Target Table)'
\echo 'วัตถุประสงค์: ยืนยันว่างานทั้งหมดในแต่ละตารางประมวลผลเสร็จสิ้น 100% ไม่มี Tasks ตกค้าง'
\echo '============================================================================'

SELECT 
    r.target_table,
    r.execution_order,
    COUNT(t.id) AS total_tasks,
    COUNT(*) FILTER (WHERE t.status = 'COMPLETED') AS completed_tasks,
    COUNT(*) FILTER (WHERE t.status = 'VALIDATED') AS remaining_tasks,
    COUNT(*) FILTER (WHERE t.status = 'NOT_FOUND') AS skipped_not_found,
    COUNT(*) FILTER (WHERE t.status = 'FAILED') AS failed_errors,
    ROUND(
        (COUNT(*) FILTER (WHERE t.status IN ('COMPLETED', 'NOT_FOUND')) * 100.0) / NULLIF(COUNT(t.id), 0), 
        2
    ) AS progress_pct,
    CASE 
        WHEN COUNT(*) FILTER (WHERE t.status = 'VALIDATED') = 0 
         AND COUNT(*) FILTER (WHERE t.status = 'FAILED') = 0 
        THEN 'PASSED: 100% COMPLETED'
        ELSE 'INCOMPLETE / HAS FAILURES'
    END AS execution_status
FROM staging_deletion_task t
JOIN deletion_rule r ON r.group_code = t.group_code
WHERE t.batch_id = :'target_batch'
GROUP BY r.target_table, r.execution_order
ORDER BY r.execution_order;


\echo ''
\echo '============================================================================'
\echo 'REPORT 2: 100% Reconciliation & Variance Report (Dry Run vs Actual Deleted)'
\echo 'วัตถุประสงค์: ตรวจสอบความถูกต้องว่ายอดลบจริงตรงกับยอดประเมินรายตารางเป้าหมาย (Variance = 0)'
\echo '============================================================================'

SELECT 
    COALESCE(d.batch_id, a.batch_id) AS batch_id,
    COALESCE(d.target_table, a.target_table) AS target_table,
    COALESCE(d.execution_order, a.exec_order) AS exec_order,
    COALESCE(d.estimated_rows_to_delete, 0) AS dry_run_estimated,
    COALESCE(a.actual_deleted_rows, 0) AS actual_deleted,
    COALESCE(a.actual_deleted_rows, 0) - COALESCE(d.estimated_rows_to_delete, 0) AS variance,
    CASE 
        WHEN COALESCE(d.estimated_rows_to_delete, 0) = COALESCE(a.actual_deleted_rows, 0) THEN 'MATCH (100%)'
        ELSE 'MISMATCH - CHECK REQUIRED'
    END AS reconciliation_status
FROM deletion_dry_run_summary d
FULL OUTER JOIN (
    SELECT 
        l.batch_id, 
        l.target_table, 
        r.execution_order AS exec_order,
        SUM(l.deleted_row_count) AS actual_deleted_rows
    FROM deletion_audit_log l
    LEFT JOIN deletion_rule r ON r.target_table = l.target_table
    GROUP BY l.batch_id, l.target_table, r.execution_order
) a ON d.batch_id = a.batch_id AND d.target_table = a.target_table
WHERE COALESCE(d.batch_id, a.batch_id) = :'target_batch'
ORDER BY COALESCE(d.execution_order, a.exec_order);


\echo ''
\echo '============================================================================'
\echo 'REPORT 3: Zero-Leakage Residual Sanity Check (Target Table Level)'
\echo 'วัตถุประสงค์: ยืนยันว่าคีย์ที่ COMPLETED แล้ว ถูกลบออกจากตารางหลักจริง (0 Rows Residual)'
\echo '============================================================================'

SELECT 
    t.batch_id,
    'orders' AS target_table,
    COUNT(t.key_no) AS completed_keys_checked,
    COUNT(o.order_no) AS leaked_residual_keys,
    CASE 
        WHEN COUNT(o.order_no) = 0 THEN 'CLEAN (0 RESIDUAL)'
        ELSE 'FAIL: RESIDUAL DATA DETECTED'
    END AS sanity_status
FROM staging_deletion_task t
LEFT JOIN orders o ON o.order_no = t.key_no
WHERE t.batch_id = :'target_batch' 
  AND t.status = 'COMPLETED'
GROUP BY t.batch_id;


\echo ''
\echo '============================================================================'
\echo 'REPORT 4: Deletion Throughput & Performance Summary (per Target Table)'
\echo 'วัตถุประสงค์: ตรวจสอบความเร็วการลบจริง, จำนวน Chunks ที่ประมวลผล, และเวลาที่ใช้รายตาราง'
\echo '============================================================================'

SELECT 
    target_table,
    COUNT(*) AS chunk_batches,
    SUM(deleted_row_count) AS total_rows_deleted,
    MIN(executed_at) AS first_chunk_at,
    MAX(executed_at) AS last_chunk_at,
    ROUND(
        EXTRACT(EPOCH FROM (MAX(executed_at) - MIN(executed_at)))::numeric, 2
    ) AS duration_seconds,
    ROUND(
        SUM(deleted_row_count) / NULLIF(EXTRACT(EPOCH FROM (MAX(executed_at) - MIN(executed_at))), 0)::numeric, 
        2
    ) AS rows_per_second
FROM deletion_audit_log
WHERE batch_id = :'target_batch'
GROUP BY target_table
ORDER BY MIN(executed_at);


\echo ''
\echo '============================================================================'
\echo 'REPORT 5: Compliance Certificate of Destruction / Audit Trail (Target Table Level)'
\echo 'วัตถุประสงค์: ใบรับรองหลักฐานการทำลายข้อมูลประจำปีรายตารางเป้าหมาย (Compliance / PDPA Audit)'
\echo '============================================================================'

SELECT 
    a.batch_id,
    a.target_table,
    r.execution_order,
    SUM(a.deleted_row_count) AS total_purged_rows,
    MIN(a.executed_at) AS purge_started_at,
    MAX(a.executed_at) AS purge_completed_at,
    (SELECT COUNT(*) FROM staging_deletion_task t WHERE t.batch_id = a.batch_id AND t.group_code = a.group_code AND t.status = 'COMPLETED') AS completed_keys_count,
    (SELECT COUNT(*) FROM staging_deletion_task t WHERE t.batch_id = a.batch_id AND t.group_code = a.group_code AND t.status = 'NOT_FOUND') AS missing_keys_count
FROM deletion_audit_log a
LEFT JOIN deletion_rule r ON r.group_code = a.group_code AND r.target_table = a.target_table
WHERE a.batch_id = :'target_batch'
GROUP BY a.batch_id, a.target_table, a.group_code, r.execution_order
ORDER BY r.execution_order;
