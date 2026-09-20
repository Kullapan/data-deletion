-- =============================================================================
-- Data Masking System: Core Schema Framework (2-Tier Architecture)
-- Engine: PostgreSQL 16+
-- Metadata-driven masking configured in masking_rule (mask_expression)
-- Strictly Key-Driven: Operates only on keys ingested from Excel/CSV
-- =============================================================================

CREATE TABLE IF NOT EXISTS masking_group (
    group_code      VARCHAR(50) PRIMARY KEY,
    key_type        VARCHAR(50) NOT NULL,
    description     TEXT,
    chunk_size      INT DEFAULT 500,
    throttle_sec    NUMERIC(4,2) DEFAULT 0.05,
    is_active       BOOLEAN DEFAULT TRUE,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

COMMENT ON TABLE masking_group IS 'Defines group of tables/columns to be masked together for a given key_type';
COMMENT ON COLUMN masking_group.group_code IS 'Unique code for the masking group (e.g. CUST_PII, EMP_CONFIDENTIAL)';
COMMENT ON COLUMN masking_group.key_type IS 'External identifier type from Excel/CSV (e.g. CUSTOMER_ID, CITIZEN_ID)';
COMMENT ON COLUMN masking_group.chunk_size IS 'Number of keys per micro-transaction (COMMIT)';
COMMENT ON COLUMN masking_group.throttle_sec IS 'Sleep time between chunks in seconds';

-- -----------------------------------------------------------------------------
-- 2. Configuration: Masking Rules per Target Table and Column
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS masking_rule (
    id                      SERIAL PRIMARY KEY,
    group_code              VARCHAR(50) NOT NULL REFERENCES masking_group(group_code) ON DELETE CASCADE,
    target_table            VARCHAR(100) NOT NULL,
    column_name             VARCHAR(100) NOT NULL,
    mask_expression         TEXT NOT NULL,
    execution_order         INT DEFAULT 1,
    where_clause_template   TEXT NOT NULL,
    is_active               BOOLEAN DEFAULT TRUE,
    description             TEXT,
    created_at              TIMESTAMPTZ DEFAULT NOW(),
    CONSTRAINT uq_masking_rule UNIQUE(group_code, target_table, column_name)
);

COMMENT ON TABLE masking_rule IS 'Configuration table specifying masking logic and expressions for each column';
COMMENT ON COLUMN masking_rule.mask_expression IS 'SQL expression/function configured directly in table (e.g. fn_mask_email(email), fn_mask_phone(phone), ''MASKED'')';
COMMENT ON COLUMN masking_rule.where_clause_template IS 'WHERE clause template where $1 represents array of keys from staging';

-- -----------------------------------------------------------------------------
-- 3. Staging Tier 1: Master Keys Ingested from Excel / CSV
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS staging_masking_item (
    id              BIGSERIAL PRIMARY KEY,
    batch_id        VARCHAR(100) NOT NULL,
    key_type        VARCHAR(50) NOT NULL,
    key_no          VARCHAR(100) NOT NULL,
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    CONSTRAINT uq_staging_masking_item UNIQUE(batch_id, key_type, key_no)
);

CREATE INDEX IF NOT EXISTS idx_staging_masking_item_lookup
    ON staging_masking_item (batch_id, key_type, key_no);

COMMENT ON TABLE staging_masking_item IS 'Raw master keys ingested from Excel/CSV files';

-- -----------------------------------------------------------------------------
-- 4. Staging Tier 2: Group Tasks Expanded 1:N
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS staging_masking_task (
    id              BIGSERIAL PRIMARY KEY,
    batch_id        VARCHAR(100) NOT NULL,
    group_code      VARCHAR(50) NOT NULL REFERENCES masking_group(group_code),
    key_no          VARCHAR(100) NOT NULL,
    status          VARCHAR(20) DEFAULT 'PENDING'
                    CHECK (status IN ('PENDING', 'NOT_FOUND', 'VALIDATED', 'COMPLETED', 'PARTIAL_COMPLETED', 'FAILED')),
    error_message   TEXT,
    processed_at    TIMESTAMPTZ,
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    CONSTRAINT uq_staging_masking_task UNIQUE(batch_id, group_code, key_no)
);

CREATE INDEX IF NOT EXISTS idx_staging_masking_task_status
    ON staging_masking_task (batch_id, group_code, status);

COMMENT ON TABLE staging_masking_task IS 'Task queue per group expanded from master items';

-- -----------------------------------------------------------------------------
-- 5. Analytical Dry Run Summary (Includes Before/After Sample Previews)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS masking_dry_run_summary (
    batch_id                VARCHAR(100) NOT NULL,
    group_code              VARCHAR(50) NOT NULL,
    target_table            VARCHAR(100) NOT NULL,
    column_name             VARCHAR(100) NOT NULL,
    execution_order         INT NOT NULL,
    mask_expression         TEXT NOT NULL,
    estimated_rows_to_mask  BIGINT NOT NULL,
    sample_preview          JSONB,
    created_at              TIMESTAMPTZ DEFAULT NOW(),
    PRIMARY KEY (batch_id, group_code, target_table, column_name)
);

COMMENT ON TABLE masking_dry_run_summary IS 'Analytical Dry Run results with estimated counts and sample Before/After preview for DPO approval';

-- -----------------------------------------------------------------------------
-- 6. Audit Trail: Real Masking Audit Log
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS masking_audit_log (
    id                  BIGSERIAL PRIMARY KEY,
    batch_id            VARCHAR(100) NOT NULL,
    group_code          VARCHAR(50) NOT NULL,
    target_table        VARCHAR(100) NOT NULL,
    columns_masked      TEXT NOT NULL,
    masked_row_count    INT NOT NULL,
    chunk_number        INT NOT NULL,
    duration_sec        NUMERIC(6,3),
    processed_at        TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_masking_audit_log_batch
    ON masking_audit_log (batch_id, group_code, target_table);

COMMENT ON TABLE masking_audit_log IS 'Immutable audit trail of all chunked masking micro-transactions';
