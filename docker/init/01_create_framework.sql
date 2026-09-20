-- =============================================
-- Yearly Data Deletion Framework - Core Schema
-- Docker Initialization Script (2-Tier Item & Task Model)
-- =============================================

-- 1. Deletion Group (Table Group Configuration)
CREATE TABLE deletion_group (
    group_code VARCHAR(50) PRIMARY KEY,
    key_type VARCHAR(50) NOT NULL,  -- Key Type accepted by this table group (e.g. ORDER_NO, CUSTOMER_ID)
    description TEXT,
    chunk_size INT NOT NULL DEFAULT 500,
    throttle_sec NUMERIC(4,2) NOT NULL DEFAULT 0.05,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_deletion_group_key_type 
ON deletion_group (key_type, is_active);

-- 2. Deletion Rule (Unified WHERE Clause for both COUNT and DELETE)
CREATE TABLE deletion_rule (
    id SERIAL PRIMARY KEY,
    group_code VARCHAR(50) NOT NULL REFERENCES deletion_group(group_code),
    target_table VARCHAR(100) NOT NULL,
    execution_order INT NOT NULL,
    where_clause_template TEXT NOT NULL,
    UNIQUE(group_code, execution_order)
);

-- 3. Staging Item Table (Master Keys from Excel/CSV)
CREATE TABLE staging_deletion_item (
    id BIGSERIAL PRIMARY KEY,
    batch_id VARCHAR(50) NOT NULL,
    key_type VARCHAR(50) NOT NULL,
    key_no VARCHAR(100) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(batch_id, key_type, key_no)
);

CREATE INDEX idx_staging_item_lookup 
ON staging_deletion_item (batch_id, key_type);

-- 4. Staging Task Table (Execution Tasks per Table Group)
CREATE TABLE staging_deletion_task (
    id BIGSERIAL PRIMARY KEY,
    batch_id VARCHAR(50) NOT NULL,
    item_id BIGINT NOT NULL REFERENCES staging_deletion_item(id) ON DELETE CASCADE,
    group_code VARCHAR(50) NOT NULL REFERENCES deletion_group(group_code) ON DELETE CASCADE,
    key_no VARCHAR(100) NOT NULL,
    status VARCHAR(30) NOT NULL DEFAULT 'PENDING',
    error_message TEXT,
    processed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(batch_id, group_code, key_no)
);

CREATE INDEX idx_staging_task_fetch 
ON staging_deletion_task (group_code, batch_id, status, id);

CREATE INDEX idx_staging_task_lookup 
ON staging_deletion_task (batch_id, group_code, key_no);

-- 5. Dry Run Summary
CREATE TABLE deletion_dry_run_summary (
    id BIGSERIAL PRIMARY KEY,
    batch_id VARCHAR(50) NOT NULL,
    group_code VARCHAR(50) NOT NULL,
    target_table VARCHAR(100) NOT NULL,
    execution_order INT NOT NULL,
    estimated_rows_to_delete BIGINT NOT NULL,
    executed_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- 6. Audit Log
CREATE TABLE deletion_audit_log (
    id BIGSERIAL PRIMARY KEY,
    batch_id VARCHAR(50) NOT NULL,
    group_code VARCHAR(50) NOT NULL,
    target_table VARCHAR(100) NOT NULL,
    deleted_row_count BIGINT NOT NULL,
    executed_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
