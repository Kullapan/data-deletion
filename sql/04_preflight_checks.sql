-- =============================================
-- Pre-flight Safety Checks
-- Run these queries BEFORE starting any deletion batch
-- =============================================

-- =============================================
-- 1. Find Foreign Keys WITHOUT supporting B-Tree Index
--    Missing indexes cause sequential scans and table locks
--    during DELETE operations
-- =============================================
-- Usage: Replace :group_code with your actual group code
--   e.g. WHERE group_code = 'ORDERS'

SELECT
    c.conrelid::regclass AS table_name,
    c.conname AS fk_name,
    pg_get_constraintdef(c.oid) AS fk_definition
FROM pg_constraint c
WHERE c.contype = 'f'
  AND c.conrelid::regclass::text IN (
      SELECT target_table FROM deletion_rule WHERE group_code = 'ORDERS'
  )
  AND NOT EXISTS (
      SELECT 1 FROM pg_index i
      WHERE i.indrelid = c.conrelid
        AND i.indkey[0:array_length(c.conkey, 1) - 1] = c.conkey
  );

-- =============================================
-- 2. Find ON DELETE CASCADE constraints
--    These may cause unintended deletions beyond
--    what is defined in deletion_rule
-- =============================================

SELECT
    tc.table_name,
    kcu.column_name,
    rc.delete_rule,
    ccu.table_name AS referenced_table
FROM information_schema.table_constraints tc
JOIN information_schema.referential_constraints rc 
  ON tc.constraint_name = rc.constraint_name
  AND tc.constraint_schema = rc.constraint_schema
JOIN information_schema.key_column_usage kcu 
  ON tc.constraint_name = kcu.constraint_name
  AND tc.constraint_schema = kcu.constraint_schema
JOIN information_schema.constraint_column_usage ccu 
  ON rc.unique_constraint_name = ccu.constraint_name
  AND rc.unique_constraint_schema = ccu.constraint_schema
WHERE rc.delete_rule = 'CASCADE'
  AND ccu.table_name IN (
      SELECT target_table FROM deletion_rule WHERE group_code = 'ORDERS'
  );

-- =============================================
-- 3. Check current staging status summary
-- =============================================

SELECT 
    batch_id,
    group_code,
    status, 
    COUNT(*) AS cnt
FROM staging_deletion_item
GROUP BY batch_id, group_code, status
ORDER BY batch_id, group_code, status;

-- =============================================
-- 4. Check Dry Run results
-- =============================================

SELECT 
    batch_id,
    group_code,
    target_table,
    execution_order,
    estimated_rows_to_delete,
    executed_at
FROM deletion_dry_run_summary
ORDER BY batch_id, group_code, execution_order;

-- =============================================
-- 5. Check Audit Log (post-deletion)
-- =============================================

SELECT 
    batch_id,
    group_code,
    target_table,
    deleted_row_count,
    executed_at
FROM deletion_audit_log
ORDER BY batch_id, group_code, executed_at;
