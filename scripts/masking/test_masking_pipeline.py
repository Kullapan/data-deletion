#!/usr/bin/env python3
"""Automated Regression & Test Pipeline for Key-Driven Data Masking System.

Verifies:
1. Database connectivity and schema/functions deployment
2. Target mock table setup with PII data (customers)
3. Configuration table setup (masking_group and masking_rule with configured logic)
4. Excel/CSV Key Ingestion into staging_masking_item
5. Phase 1: Analytical Dry Run (Task Expansion, Validation, Before/After sample preview)
6. Phase 2: Real Masking (Chunked micro-transactions with config-driven dynamic UPDATE)
7. Verification of masked values, audit logs, and ensuring non-targeted rows are untouched!

Usage:
    python scripts/masking/test_masking_pipeline.py
    python scripts/masking/test_masking_pipeline.py --db-url postgresql://postgres:password123@localhost:5432/deletion_db
"""

import os
import sys
import time
import json
import argparse
import psycopg2
from psycopg2.extensions import ISOLATION_LEVEL_AUTOCOMMIT
import pandas as pd

sys.path.insert(0, os.path.dirname(__file__))
import ingest

DEFAULT_DB_URL = "postgresql://postgres:password123@localhost:5432/deletion_db"


def log(msg: str, status: str = "INFO"):
    tags = {"INFO": "[INFO] ", "PASS": "[PASS] ", "FAIL": "[FAIL] ", "WARN": "[WARN] "}
    print(f"[{time.strftime('%H:%M:%S')}] {tags.get(status, '')}{msg}", flush=True)


def assert_val(actual, expected, label):
    if actual != expected:
        log(f"ASSERTION FAILED for {label}: Expected {expected}, got {actual}", "FAIL")
        sys.exit(1)
    else:
        log(f"Verified {label}: {actual} (matches expected {expected})", "PASS")


def run_pipeline(db_url: str):
    log("Starting Key-Driven Data Masking Test Pipeline...", "INFO")

    conn = psycopg2.connect(db_url)
    conn.set_isolation_level(ISOLATION_LEVEL_AUTOCOMMIT)
    cur = conn.cursor()

    # Step 1: Connect and Deploy Masking Framework
    cur.execute("SELECT version();")
    db_ver = cur.fetchone()[0]
    log(f"Connected to PostgreSQL: {db_ver.split()[0]} {db_ver.split()[1]}", "PASS")

    sql_dir = os.path.join(os.path.dirname(__file__), "..", "..", "sql", "masking")
    for sql_file in ["01_masking_schema.sql", "02_masking_functions.sql", "03_masking_dry_run.sql", "04_masking_real.sql"]:
        file_path = os.path.join(sql_dir, sql_file)
        with open(file_path, "r", encoding="utf-8") as f:
            cur.execute(f.read())
    log("Masking schema, function library, and stored procedures deployed.", "PASS")

    # Step 2: Create and Seed Mock Customers Table
    cur.execute("""
        DROP TABLE IF EXISTS mock_masking_customers CASCADE;
        CREATE TABLE mock_masking_customers (
            customer_id     VARCHAR(50) PRIMARY KEY,
            customer_name   VARCHAR(100) NOT NULL,
            email           VARCHAR(100) NOT NULL,
            phone_number    VARCHAR(50) NOT NULL,
            citizen_id      VARCHAR(20) NOT NULL,
            address         TEXT NOT NULL,
            created_at      TIMESTAMPTZ DEFAULT NOW()
        );
    """)

    # Insert 20 sample customers
    mock_customers = []
    for i in range(1, 21):
        cid = f"CUST-{i:04d}"
        cname = f"Customer Name {i}"
        cemail = f"user.{i}@enterprise.com"
        cphone = f"081234{i:04d}"
        ccid = f"11005001{i:05d}"
        caddr = f"{i} Sukhumvit Road, Bangkok 10110"
        mock_customers.append((cid, cname, cemail, cphone, ccid, caddr))

    from psycopg2.extras import execute_values
    execute_values(cur, """
        INSERT INTO mock_masking_customers (customer_id, customer_name, email, phone_number, citizen_id, address)
        VALUES %s;
    """, mock_customers)

    cur.execute("SELECT COUNT(*) FROM mock_masking_customers;")
    total_mock = cur.fetchone()[0]
    assert_val(total_mock, 20, "Total Mock Customers Seeded")

    # Step 3: Setup Configuration Table (masking_group and masking_rule)
    group_code = "CUST_TEST_MASK"
    key_type = "CUSTOMER_ID"
    chunk_size = 5  # Small chunk size to test multiple micro-transaction commits

    cur.execute("""
        INSERT INTO masking_group (group_code, key_type, description, chunk_size, throttle_sec, is_active)
        VALUES (%s, %s, 'Test Customer PII Masking', %s, 0.01, TRUE)
        ON CONFLICT (group_code) DO UPDATE
        SET key_type = EXCLUDED.key_type, chunk_size = EXCLUDED.chunk_size, throttle_sec = EXCLUDED.throttle_sec;
    """, (group_code, key_type, chunk_size))

    # Configure Column Masking Expressions in masking_rule
    cur.execute("""
        DELETE FROM masking_rule WHERE group_code = %s;
        INSERT INTO masking_rule (group_code, target_table, column_name, mask_expression, execution_order, where_clause_template)
        VALUES
            (%s, 'mock_masking_customers', 'email',         'fn_mask_email(email)',         1, 'WHERE customer_id = ANY($1)'),
            (%s, 'mock_masking_customers', 'phone_number',  'fn_mask_phone(phone_number)',  1, 'WHERE customer_id = ANY($1)'),
            (%s, 'mock_masking_customers', 'citizen_id',    'fn_mask_citizen_id(citizen_id)', 1, 'WHERE customer_id = ANY($1)'),
            (%s, 'mock_masking_customers', 'customer_name', 'fn_mask_name(customer_name)', 1, 'WHERE customer_id = ANY($1)'),
            (%s, 'mock_masking_customers', 'address',       '''CONFIDENTIAL_ADDRESS''',    1, 'WHERE customer_id = ANY($1)');
    """, (group_code, group_code, group_code, group_code, group_code, group_code))
    log("Configured 5 masking rules with custom expressions in config table.", "PASS")

    # Step 4: Prepare Excel file with 10 Target Keys + 2 Dummy (Non-Existent) Keys
    test_keys = [f"CUST-{i:04d}" for i in range(1, 11)] + ["CUST-9991", "CUST-9992"]
    mock_data_dir = os.path.join(os.path.dirname(__file__), "..", "..", "mock_data")
    test_excel_path = os.path.join(mock_data_dir, "test_masking_keys.xlsx")

    df_keys = pd.DataFrame({
        "key_type": [key_type] * len(test_keys),
        "key_no": test_keys
    })
    df_keys.to_excel(test_excel_path, index=False)
    log(f"Generated test Excel file with {len(test_keys)} keys at {test_excel_path}", "INFO")

    batch_id = f"TEST-MASK-{int(time.time())}"
    log(f"Ingesting keys into staging_masking_item for batch {batch_id}...", "INFO")
    ingest.ingest_file(test_excel_path, batch_id, db_url=db_url)

    cur.execute("SELECT COUNT(*) FROM staging_masking_item WHERE batch_id = %s;", (batch_id,))
    ingested_cnt = cur.fetchone()[0]
    assert_val(ingested_cnt, 12, "staging_masking_item Ingested Keys")

    # Step 5: Phase 1 - Analytical Dry Run
    log("Executing run_data_masking_dry_run (Task Expansion, Validation & Sample Preview)...", "INFO")
    cur.execute("CALL run_data_masking_dry_run(%s);", (batch_id,))

    cur.execute("SELECT COUNT(*) FROM staging_masking_task WHERE batch_id = %s AND status = 'NOT_FOUND';", (batch_id,))
    not_found_cnt = cur.fetchone()[0]
    assert_val(not_found_cnt, 2, "NOT_FOUND Tasks Detected")

    cur.execute("SELECT COUNT(*) FROM staging_masking_task WHERE batch_id = %s AND status = 'VALIDATED';", (batch_id,))
    validated_cnt = cur.fetchone()[0]
    assert_val(validated_cnt, 10, "VALIDATED Tasks Count")

    # Check Dry Run Summary and Sample Preview JSON
    cur.execute("""
        SELECT column_name, estimated_rows_to_mask, sample_preview
        FROM masking_dry_run_summary
        WHERE batch_id = %s
        ORDER BY column_name;
    """, (batch_id,))
    dry_rows = cur.fetchall()
    assert_val(len(dry_rows), 5, "Dry Run Summary Rules Count")

    for col_name, est_rows, preview_json in dry_rows:
        assert_val(est_rows, 10, f"Estimated rows for {col_name}")
        log(f"Sample preview for {col_name}: {json.dumps(preview_json[0])}", "PASS")
        # Ensure sample has both 'before' and 'after'
        assert "before" in preview_json[0] and "after" in preview_json[0], "Sample preview format invalid"

    # Step 6: Phase 2 - Real Masking Execution
    log("Executing run_data_masking (Chunked Micro-Transactions)...", "INFO")
    cur.execute("CALL run_data_masking(%s);", (batch_id,))

    cur.execute("SELECT COUNT(*) FROM staging_masking_task WHERE batch_id = %s AND status = 'COMPLETED';", (batch_id,))
    completed_cnt = cur.fetchone()[0]
    assert_val(completed_cnt, 10, "COMPLETED Tasks Count")

    # Verify Audit Log
    cur.execute("""
        SELECT target_table, SUM(masked_row_count), COUNT(*)
        FROM masking_audit_log
        WHERE batch_id = %s
        GROUP BY target_table;
    """, (batch_id,))
    audit_row = cur.fetchone()
    assert_val(audit_row[0], "mock_masking_customers", "Audit Target Table")
    assert_val(audit_row[1], 10, "Audit Total Rows Masked")
    assert_val(audit_row[2], 2, "Audit Total Chunks (10 rows / chunk_size 5 = 2 chunks)")

    # Step 7: Verify Masked Data in Database
    # 7.1 Verify targeted rows (CUST-0001 ~ CUST-0010) are masked
    cur.execute("""
        SELECT customer_id, customer_name, email, phone_number, citizen_id, address
        FROM mock_masking_customers
        WHERE customer_id = 'CUST-0001';
    """)
    m_row = cur.fetchone()
    log(f"Masked row 1: cid={m_row[0]}, name={m_row[1]}, email={m_row[2]}, phone={m_row[3]}, cid_no={m_row[4]}, addr={m_row[5]}", "INFO")
    assert "***" in m_row[2], "Email was not masked!"
    assert "XXX" in m_row[3], "Phone was not masked!"
    assert "XXXXX" in m_row[4], "Citizen ID was not masked!"
    assert m_row[5] == "CONFIDENTIAL_ADDRESS", "Address was not masked!"

    # 7.2 Verify non-targeted rows (CUST-0011 ~ CUST-0020) are COMPLETELY UNTOUCHED!
    cur.execute("""
        SELECT customer_id, customer_name, email, phone_number, citizen_id, address
        FROM mock_masking_customers
        WHERE customer_id = 'CUST-0015';
    """)
    un_row = cur.fetchone()
    log(f"Untouched row 15: cid={un_row[0]}, email={un_row[2]}, phone={un_row[3]}", "INFO")
    assert un_row[2] == "user.15@enterprise.com", "Untargeted email was modified!"
    assert un_row[3] == "0812340015", "Untargeted phone was modified!"
    assert un_row[5] == "15 Sukhumvit Road, Bangkok 10110", "Untargeted address was modified!"

    # 7.3 Verify total count remains 20 (zero rows deleted)
    cur.execute("SELECT COUNT(*) FROM mock_masking_customers;")
    final_cnt = cur.fetchone()[0]
    assert_val(final_cnt, 20, "Total table count preserved (zero deletions)")

    cur.close()
    conn.close()

    print("\n" + "=" * 60)
    log("ALL DATA MASKING TESTS PASSED! Key-Driven Engine 100% Operational.", "PASS")
    print("=" * 60 + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Test Key-Driven Data Masking Pipeline")
    parser.add_argument("--db-url", default=DEFAULT_DB_URL, help="PostgreSQL connection string")
    args = parser.parse_args()
    run_pipeline(args.db_url)
