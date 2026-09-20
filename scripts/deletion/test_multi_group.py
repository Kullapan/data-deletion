#!/usr/bin/env python3
"""Test 1:N Multi-Group Expansion for Yearly Data Deletion System.

Demonstrates that 1 Key Type (e.g. CUSTOMER_ID) automatically expands
into N Table Groups (e.g. CUST_ORDERS and CUST_LOGS).
"""

import os
import sys
import time
import psycopg2
from psycopg2.extensions import ISOLATION_LEVEL_AUTOCOMMIT
import pandas as pd

sys.path.insert(0, os.path.dirname(__file__))

DEFAULT_DB_URL = "postgresql://postgres:password123@localhost:5432/deletion_db"


def test_multi_group_expansion(db_url: str):
    print("Testing 1:N Multi-Group Task Expansion...", flush=True)

    conn = psycopg2.connect(db_url)
    conn.set_isolation_level(ISOLATION_LEVEL_AUTOCOMMIT)
    cur = conn.cursor()

    batch_id = f"TEST-1TO-N-{int(time.time())}"

    # 1. Configure 2 groups that accept the same key_type ('CUSTOMER_ID')
    cur.execute("""
        INSERT INTO deletion_group (group_code, key_type, description, chunk_size, throttle_sec)
        VALUES 
            ('CUST_ORDERS', 'CUSTOMER_ID', 'Customer orders group', 500, 0),
            ('CUST_LOGS',   'CUSTOMER_ID', 'Customer logs group',   500, 0)
        ON CONFLICT (group_code) DO UPDATE 
        SET key_type = EXCLUDED.key_type, is_active = TRUE;

        INSERT INTO deletion_rule (group_code, target_table, execution_order, where_clause_template)
        VALUES
            ('CUST_ORDERS', 'orders', 1, 'WHERE customer_name = ANY($1)'),
            ('CUST_LOGS',   'orders', 1, 'WHERE customer_name = ANY($1)')
        ON CONFLICT (group_code, execution_order) DO UPDATE
        SET where_clause_template = EXCLUDED.where_clause_template, target_table = EXCLUDED.target_table;
    """)

    # 2. Generate a test Excel with 5 CUSTOMER_ID keys
    test_excel = os.path.join(os.path.dirname(__file__), "..", "..", "mock_data", "test_multi_group.xlsx")
    df = pd.DataFrame({
        "key_type": ["CUSTOMER_ID"] * 5,
        "key_no": ["Customer 1", "Customer 2", "Customer 3", "Customer 4", "NON_EXISTENT_CUST"]
    })
    df.to_excel(test_excel, index=False)

    # 3. Ingest into staging_deletion_item
    import ingest
    ingest.ingest_file(test_excel, batch_id, db_url=db_url)

    cur.execute("SELECT count(*) FROM staging_deletion_item WHERE batch_id = %s;", (batch_id,))
    item_cnt = cur.fetchone()[0]
    assert item_cnt == 5, f"Expected 5 items, got {item_cnt}"
    print(f"[PASS] Ingested 5 raw keys into staging_deletion_item for batch {batch_id}")

    # 4. Run Dry Run to trigger Task Expansion
    cur.execute("CALL run_data_deletion_dry_run(%s);", (batch_id,))

    # 5. Check staging_deletion_task: 5 items * 2 groups = 10 tasks!
    cur.execute("""
        SELECT group_code, status, count(*) 
        FROM staging_deletion_task 
        WHERE batch_id = %s 
        GROUP BY group_code, status 
        ORDER BY group_code, status;
    """, (batch_id,))
    task_summary = cur.fetchall()
    print(f"[PASS] Expanded Tasks Summary: {task_summary}")

    cur.execute("SELECT count(*) FROM staging_deletion_task WHERE batch_id = %s;", (batch_id,))
    total_tasks = cur.fetchone()[0]
    assert total_tasks == 10, f"Expected 10 tasks (5 items x 2 groups), got {total_tasks}"
    print(f"[PASS] Verified 1:N Task Expansion: 5 raw keys successfully expanded into {total_tasks} group tasks!")

    # Clean up test records
    cur.execute("DELETE FROM staging_deletion_task WHERE batch_id = %s;", (batch_id,))
    cur.execute("DELETE FROM staging_deletion_item WHERE batch_id = %s;", (batch_id,))
    cur.execute("DELETE FROM deletion_rule WHERE group_code IN ('CUST_ORDERS', 'CUST_LOGS');")
    cur.execute("DELETE FROM deletion_group WHERE group_code IN ('CUST_ORDERS', 'CUST_LOGS');")
    if os.path.exists(test_excel):
        os.remove(test_excel)

    cur.close()
    conn.close()
    print("Multi-Group (1:N) Test PASSED 100%!")


if __name__ == "__main__":
    test_multi_group_expansion(DEFAULT_DB_URL)
