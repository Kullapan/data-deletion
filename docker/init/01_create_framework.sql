-- =============================================
-- Yearly Data Deletion Framework - Core Schema
-- =============================================

-- 1. Deletion Group (Configuration)
CREATE TABLE deletion_group (
    group_code VARCHAR(50) PRIMARY KEY,
    description TEXT,
    chunk_size INT NOT NULL DEFAULT 500,
    throttle_sec NUMERIC(4,2) NOT NULL DEFAULT 0.05,
    parent_table VARCHAR(100),
    parent_key_col VARCHAR(100),
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- 2. Deletion Rule (Unified WHERE Clause)
CREATE TABLE deletion_rule (
    id SERIAL PRIMARY KEY,
    group_code VARCHAR(50) NOT NULL REFERENCES deletion_group(group_code),
    target_table VARCHAR(100) NOT NULL,
    execution_order INT NOT NULL,
    where_clause_template TEXT NOT NULL,
    UNIQUE(group_code, execution_order)
);

-- 3. Staging Table (Keys from Excel/CSV)
CREATE TABLE staging_deletion_item (
    id BIGSERIAL PRIMARY KEY,
    batch_id VARCHAR(50) NOT NULL,
    group_code VARCHAR(50) NOT NULL REFERENCES deletion_group(group_code),
    key_no VARCHAR(100) NOT NULL,
    status VARCHAR(30) NOT NULL DEFAULT 'PENDING',
    error_message TEXT,
    processed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_staging_fetch 
ON staging_deletion_item (group_code, batch_id, status, id);

CREATE INDEX idx_staging_lookup 
ON staging_deletion_item (batch_id, group_code, key_no);

-- 4. Dry Run Summary
CREATE TABLE deletion_dry_run_summary (
    id BIGSERIAL PRIMARY KEY,
    batch_id VARCHAR(50) NOT NULL,
    group_code VARCHAR(50) NOT NULL,
    target_table VARCHAR(100) NOT NULL,
    execution_order INT NOT NULL,
    estimated_rows_to_delete BIGINT NOT NULL,
    executed_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- 5. Audit Log
CREATE TABLE deletion_audit_log (
    id BIGSERIAL PRIMARY KEY,
    batch_id VARCHAR(50) NOT NULL,
    group_code VARCHAR(50) NOT NULL,
    target_table VARCHAR(100) NOT NULL,
    deleted_row_count BIGINT NOT NULL,
    executed_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
