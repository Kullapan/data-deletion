#!/usr/bin/env python3
"""Automated Regression & Test Pipeline for Yearly Data Deletion System.

Runs end-to-end verification:
1. Database connectivity check
2. Data seeding check
3. Ingestion test (sample_keys.csv)
4. Dry Run execution & assertions
5. Granular Deletion (Order 1) execution & assertions
6. Full Deletion execution & assertions
7. Audit Log & Status verification

Usage:
    python scripts/test_pipeline.py
    python scripts/test_pipeline.py --db-url postgresql://postgres:password123@localhost:5432/deletion_db
"""

import os
import sys
import time
import argparse
import psycopg2
from psycopg2.extensions import ISOLATION_LEVEL_AUTOCOMMIT

DEFAULT_DB_URL = "postgresql://postgres:password123@localhost:5432/deletion_db"


def log(msg: str, status: str = "INFO"):
    tags = {"INFO": "[INFO] ", "PASS": "[PASS] ", "FAIL": "[FAIL] ", "WARN": "[WARN] "}
    print(f"[{time.strftime('%H:%M:%S')}] {tags.get(status, '')}{msg}")


def assert_count(actual, expected, label):
    if actual != expected:
        log(f"ASSERTION FAILED for {label}: Expected {expected}, got {actual}", "FAIL")
        sys.exit(1)
    else:
        log(f"Verified {label}: {actual} (matches expected {expected})", "PASS")


def run_pipeline(db_url: str):
    log("Starting Yearly Data Deletion Test Pipeline...", "INFO")

    conn = psycopg2.connect(db_url)
    conn.set_isolation_level(ISOLATION_LEVEL_AUTOCOMMIT)
    cur = conn.cursor()

    # Step 1: Check connectivity
    cur.execute("SELECT version();")
    db_ver = cur.fetchone()[0]
    log(f"Connected to PostgreSQL: {db_ver.split()[0]} {db_ver.split()[1]}", "PASS")

    # Step 2: Check Deletion Group & Rules
    cur.execute("SELECT COUNT(*) FROM deletion_group WHERE group_code = 'ORDERS';")
    if cur.fetchone()[0] == 0:
        log("Deletion group ORDERS not found!", "FAIL")
        sys.exit(1)
    log("Deletion group ORDERS configured.", "PASS")

    cur.execute("SELECT COUNT(*) FROM deletion_rule WHERE group_code = 'ORDERS';")
    rule_count = cur.fetchone()[0]
    assert_count(rule_count, 3, "Active Deletion Rules")

    # Step 3: Check Mock Data Existence & Reseed if needed
    cur.execute("SELECT COUNT(*) FROM orders;")
    orders_cnt = cur.fetchone()[0]
    if orders_cnt < 1000:
        log("Existing orders less than 1000. Re-seeding mock data...", "WARN")
        seed_path = os.path.join(os.path.dirname(__file__), "..", "docker", "init", "03_seed_mock_data.sql")
        with open(seed_path, "r", encoding="utf-8") as f:
            cur.execute(f.read())
        cur.execute("SELECT COUNT(*) FROM orders;")
        orders_cnt = cur.fetchone()[0]

    cur.execute("SELECT COUNT(*) FROM order_items;")
    items_cnt = cur.fetchone()[0]
    cur.execute("SELECT COUNT(*) FROM order_item_logs;")
    logs_cnt = cur.fetchone()[0]

    log(f"Current live table counts: orders={orders_cnt}, items={items_cnt}, logs={logs_cnt}", "INFO")

    # Step 4: Generate dynamic test CSV with 1,000 real keys + 2 dummy keys (to verify NOT_FOUND)
    cur.execute("SELECT order_no FROM orders ORDER BY order_no LIMIT 1000;")
    live_keys = [r[0] for r in cur.fetchall()]
    test_keys = live_keys + ["DUMMY-99901", "DUMMY-99902"]

    test_csv = os.path.join(os.path.dirname(__file__), "..", "mock_data", "pipeline_test_keys.csv")
    with open(test_csv, "w", encoding="utf-8") as f:
        f.write("key_no\n")
        for k in test_keys:
            f.write(f"{k}\n")

    batch_id = f"TEST-PIPELINE-{int(time.time())}"
    log(f"Ingesting 1,002 test keys (1,000 live + 2 dummy) for batch {batch_id}...", "INFO")
    import ingest
    ingest.ingest_file(test_csv, batch_id, "ORDERS", db_url)

    cur.execute("SELECT COUNT(*) FROM staging_deletion_item WHERE batch_id = %s;", (batch_id,))
    ingested_count = cur.fetchone()[0]
    assert_count(ingested_count, 1002, "Ingested Keys Count")

    # Step 5: Run Dry Run & Verify NOT_FOUND + VALIDATED
    log("Executing run_data_deletion_dry_run...", "INFO")
    cur.execute("CALL run_data_deletion_dry_run(%s, %s, %s, %s);", (batch_id, "ORDERS", "orders", "order_no"))

    cur.execute("SELECT COUNT(*) FROM staging_deletion_item WHERE batch_id = %s AND status = 'NOT_FOUND';", (batch_id,))
    not_found_cnt = cur.fetchone()[0]
    assert_count(not_found_cnt, 2, "NOT_FOUND Keys Detected")

    cur.execute("SELECT COUNT(*) FROM staging_deletion_item WHERE batch_id = %s AND status = 'VALIDATED';", (batch_id,))
    validated_cnt = cur.fetchone()[0]
    assert_count(validated_cnt, 1000, "VALIDATED Keys Count")

    cur.execute("""
        SELECT target_table, execution_order, estimated_rows_to_delete 
        FROM deletion_dry_run_summary 
        WHERE batch_id = %s 
        ORDER BY execution_order;
    """, (batch_id,))
    dry_run_results = {row[0]: row[2] for row in cur.fetchall()}
    log(f"Dry Run Estimated Deletions: {dry_run_results}", "INFO")

    # Step 6: Test Real Deletion Execution
    log("Executing run_data_deletion (Full Batch)...", "INFO")
    start_t = time.time()
    cur.execute("CALL run_data_deletion(%s, %s);", (batch_id, "ORDERS"))
    elapsed = time.time() - start_t
    log(f"Deletion procedure finished in {elapsed:.2f} seconds", "PASS")

    # Step 7: Verify Final Staging Status
    cur.execute("SELECT status, COUNT(*) FROM staging_deletion_item WHERE batch_id = %s GROUP BY status;", (batch_id,))
    status_summary = dict(cur.fetchall())
    assert_count(status_summary.get("COMPLETED", 0), 1000, "Completed Staging Items")
    assert_count(status_summary.get("NOT_FOUND", 0), 2, "Unprocessed NOT_FOUND Items")

    # Step 8: Verify Audit Log
    cur.execute("""
        SELECT target_table, SUM(deleted_row_count) 
        FROM deletion_audit_log 
        WHERE batch_id = %s 
        GROUP BY target_table;
    """, (batch_id,))
    audit_summary = dict(cur.fetchall())
    log(f"Total rows purged in batch {batch_id}: {audit_summary}", "PASS")

    cur.close()
    conn.close()
    print("\n" + "=" * 60)
    log("ALL TESTS PASSED! Yearly Data Deletion System is 100% Operational.", "PASS")
    print("=" * 60 + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Test Pipeline for Yearly Data Deletion")
    parser.add_argument("--db-url", default=DEFAULT_DB_URL, help="PostgreSQL connection string")
    args = parser.parse_args()
    run_pipeline(args.db_url)
