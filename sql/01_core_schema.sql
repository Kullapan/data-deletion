-- =============================================
-- Yearly Data Deletion Framework - Core Schema
-- Production deployment script
-- =============================================

-- 1. Deletion Group (Configuration)
CREATE TABLE IF NOT EXISTS deletion_group (
    group_code VARCHAR(50) PRIMARY KEY,
    description TEXT,
    chunk_size INT NOT NULL DEFAULT 500,
    throttle_sec NUMERIC(4,2) NOT NULL DEFAULT 0.05,
    parent_table VARCHAR(100),
    parent_key_col VARCHAR(100),
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- 2. Deletion Rule (Unified WHERE Clause for both COUNT and DELETE)
CREATE TABLE IF NOT EXISTS deletion_rule (
    id SERIAL PRIMARY KEY,
    group_code VARCHAR(50) NOT NULL REFERENCES deletion_group(group_code),
    target_table VARCHAR(100) NOT NULL,
    execution_order INT NOT NULL,  -- Bottom-Up: 1 = lowest child, N = parent
    where_clause_template TEXT NOT NULL,
    -- Examples:
    -- Grandchild: WHERE item_id IN (SELECT id FROM order_items WHERE order_no = ANY($1))
    -- Child:      WHERE order_no = ANY($1)
    -- Parent:     WHERE order_no = ANY($1)
    UNIQUE(group_code, execution_order)
);

-- 3. Staging Table (Keys from Excel/CSV)
CREATE TABLE IF NOT EXISTS staging_deletion_item (
    id BIGSERIAL PRIMARY KEY,
    batch_id VARCHAR(50) NOT NULL,
    group_code VARCHAR(50) NOT NULL REFERENCES deletion_group(group_code),
    key_no VARCHAR(100) NOT NULL,
    status VARCHAR(30) NOT NULL DEFAULT 'PENDING',
    -- Status flow: PENDING -> VALIDATED -> COMPLETED / FAILED
    --             PENDING -> NOT_FOUND (if parent table check enabled)
    error_message TEXT,
    processed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_staging_fetch 
ON staging_deletion_item (group_code, batch_id, status, id);

CREATE INDEX IF NOT EXISTS idx_staging_lookup 
ON staging_deletion_item (batch_id, group_code, key_no);

-- 4. Dry Run Summary
CREATE TABLE IF NOT EXISTS deletion_dry_run_summary (
    id BIGSERIAL PRIMARY KEY,
    batch_id VARCHAR(50) NOT NULL,
    group_code VARCHAR(50) NOT NULL,
    target_table VARCHAR(100) NOT NULL,
    execution_order INT NOT NULL,
    estimated_rows_to_delete BIGINT NOT NULL,
    executed_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- 5. Audit Log
CREATE TABLE IF NOT EXISTS deletion_audit_log (
    id BIGSERIAL PRIMARY KEY,
    batch_id VARCHAR(50) NOT NULL,
    group_code VARCHAR(50) NOT NULL,
    target_table VARCHAR(100) NOT NULL,
    deleted_row_count BIGINT NOT NULL,
    executed_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
