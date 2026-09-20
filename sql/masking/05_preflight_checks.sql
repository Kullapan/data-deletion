-- =============================================================================
-- Data Masking System: Pre-flight Safety Checks
-- Engine: PostgreSQL 16+
-- Run these checks before running run_data_masking to ensure safety.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Unique Index Collision Check
-- Checks if any column configured for masking has a UNIQUE constraint or index.
-- If a unique column is masked with static or non-unique text, it will collide!
-- -----------------------------------------------------------------------------
SELECT 
    r.group_code,
    r.target_table,
    r.column_name,
    r.mask_expression,
    i.relname AS index_name,
    '⚠️ WARNING: Target column has a UNIQUE constraint. Ensure mask_expression produces unique values (e.g. fn_mask_salted_hash or sequence)!' AS safety_advice
FROM masking_rule r
JOIN pg_class t ON t.relname = r.target_table
JOIN pg_index ix ON ix.indrelid = t.oid
JOIN pg_class i ON i.oid = ix.indexrelid
JOIN pg_attribute a ON a.attrelid = t.oid AND a.attname = r.column_name
WHERE r.is_active = TRUE
  AND ix.indisunique = TRUE
  AND a.attnum = ANY(ix.indkey);

-- -----------------------------------------------------------------------------
-- 2. Column Existence and Character Length Check
-- Verifies that configured columns exist and their data types can hold masked data.
-- -----------------------------------------------------------------------------
SELECT 
    r.group_code,
    r.target_table,
    r.column_name,
    c.data_type,
    c.character_maximum_length,
    r.mask_expression,
    CASE 
        WHEN c.column_name IS NULL THEN '❌ ERROR: Target column does not exist in database!'
        WHEN c.character_maximum_length IS NOT NULL AND c.character_maximum_length < 20 
             AND r.mask_expression LIKE '%fn_mask_%' 
             THEN '⚠️ WARNING: Column max length (' || c.character_maximum_length || ') may be too short for masked output!'
        ELSE '✅ OK'
    END AS status
FROM masking_rule r
LEFT JOIN information_schema.columns c 
       ON c.table_name = r.target_table 
      AND c.column_name = r.column_name
WHERE r.is_active = TRUE;

-- -----------------------------------------------------------------------------
-- 3. Trigger Interference Check
-- Identifies active UPDATE triggers on target tables that could slow down masking
-- or reject obfuscated values.
-- -----------------------------------------------------------------------------
SELECT 
    trigger_schema,
    event_object_table AS target_table,
    trigger_name,
    action_timing,
    event_manipulation,
    '💡 ADVICE: If this trigger performs heavy validation, consider disabling it during maintenance or checking session_replication_role.' AS operational_note
FROM information_schema.triggers
WHERE event_manipulation = 'UPDATE'
  AND event_object_table IN (SELECT target_table FROM masking_rule WHERE is_active = TRUE);

-- -----------------------------------------------------------------------------
-- 4. Foreign Key Referenced Primary Key Check
-- Warns if a masked column is referenced as a PK/FK by other tables.
-- -----------------------------------------------------------------------------
SELECT
    ccu.table_name AS primary_table,
    ccu.column_name AS primary_column,
    tc.table_name AS foreign_table,
    kcu.column_name AS foreign_column,
    '⚠️ NOTICE: Column is referenced by a Foreign Key. Masking this column requires deterministic hashing to preserve referential consistency!' AS advisory
FROM information_schema.table_constraints tc
JOIN information_schema.key_column_usage kcu 
  ON tc.constraint_name = kcu.constraint_name
JOIN information_schema.referential_constraints rc 
  ON tc.constraint_name = rc.constraint_name
JOIN information_schema.constraint_column_usage ccu 
  ON rc.unique_constraint_name = ccu.constraint_name
WHERE tc.constraint_type = 'FOREIGN KEY'
  AND ccu.table_name IN (SELECT target_table FROM masking_rule WHERE is_active = TRUE)
  AND ccu.column_name IN (SELECT column_name FROM masking_rule WHERE is_active = TRUE);
