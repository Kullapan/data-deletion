# Operational Manual: Yearly Data Deletion System
### Standard Operating Procedure (SOP), Monitoring & Troubleshooting Guide
### Version 2.0 (2-Tier Item & Task Architecture)

---

## 1. บทบาทและความรับผิดชอบ (Roles & Responsibilities)

| บทบาท | หน้าที่ |
|---|---|
| **Data Owner / Ops Team** | จัดเตรียมไฟล์ Excel/CSV ที่มีคอลัมน์ `key_type` และ `key_no` ซึ่งผ่านการคัดกรอง Key ที่ครบกำหนดลบประจำปี |
| **Database Administrator (DBA)** | รัน Pre-flight Check, ตรวจสอบ Replication & Disk, Monitor ขณะ Execution และรัน Post-Maintenance |
| **Approver / Business Manager** | ตรวจสอบตัวเลขจาก `deletion_dry_run_summary` และลงนามอนุมัติ (Sign-off) ก่อนสั่งลบจริง |

---

## 2. Pre-flight Checklist (ตรวจสอบก่อนเริ่มงาน)

ก่อนสั่งรันงาน ให้ DBA ตรวจสอบข้อกำหนดความปลอดภัยดังนี้:

- [ ] **1. Disk Space:** พื้นที่ว่างบน Disk ของ PostgreSQL (ทั้ง Primary และ Replica) ต้องมีอย่างน้อย 20% เพื่อรองรับ WAL logs
- [ ] **2. Missing FK Index Check:** รันคำสั่งตรวจ Index บน Foreign Key ทุกตารางเป้าหมาย
```sql
SELECT
    c.conrelid::regclass AS table_name,
    c.conname AS fk_name,
    pg_get_constraintdef(c.oid) AS fk_definition
FROM pg_constraint c
WHERE c.contype = 'f'
  AND c.conrelid::regclass::text IN (
      SELECT target_table FROM deletion_rule
  )
  AND NOT EXISTS (
      SELECT 1 FROM pg_index i
      WHERE i.indrelid = c.conrelid
        AND i.indkey[0:array_length(c.conkey, 1) - 1] = c.conkey
  );
```
*(หากพบรายการ ต้องสร้าง B-Tree Index ให้เรียบร้อยก่อน)*

- [ ] **3. Cascade Constraint Check:** ตรวจสอบว่าไม่มีตารางเป้าหมายตัวใดผูก `ON DELETE CASCADE` กับตารางอื่นนอกระบบ
```sql
SELECT
    tc.table_name, kcu.column_name, rc.delete_rule, ccu.table_name AS referenced_table
FROM information_schema.table_constraints tc
JOIN information_schema.referential_constraints rc ON tc.constraint_name = rc.constraint_name
JOIN information_schema.key_column_usage kcu ON tc.constraint_name = kcu.constraint_name
JOIN information_schema.constraint_column_usage ccu ON rc.unique_constraint_name = ccu.constraint_name
WHERE rc.delete_rule = 'CASCADE'
  AND ccu.table_name IN (SELECT target_table FROM deletion_rule);
```

- [ ] **4. Autovacuum Setting (สำหรับงานระดับแสน-ล้านแถว):**
```sql
-- เร่ง Autovacuum บนตารางเป้าหมายชั่วคราว
ALTER TABLE orders SET (autovacuum_vacuum_scale_factor = 0.05);
ALTER TABLE order_items SET (autovacuum_vacuum_scale_factor = 0.05);
ALTER TABLE order_item_logs SET (autovacuum_vacuum_scale_factor = 0.05);
```

---

## 3. ขั้นตอนการปฏิบัติงานทีละขั้นตอน (Step-by-Step SOP)

### Step 1: นำเข้า Key เข้าระบบ (Ingestion)

รันสคริปต์ `ingest.py` โดยระบุไฟล์และชื่อ Batch:

```bash
# แบบที่ 1: ไฟล์ Excel/CSV ที่มีคอลัมน์ key_type และ key_no อยู่แล้ว (แนะนำ - Auto-detect):
python scripts/ingest.py \
  --file /path/to/yearly_deletion_2025.xlsx \
  --batch BATCH-2025

# แบบที่ 2: ไฟล์ที่มีคอลัมน์เดียว (ระบุ key_type ผ่าน CLI):
python scripts/ingest.py \
  --file /path/to/orders_2024.csv \
  --batch BATCH-2025 \
  --key-type ORDER_NO
```

**ตรวจสอบความเรียบร้อย:**
```sql
-- ตรวจสอบ Master Keys ใน staging_deletion_item
SELECT batch_id, key_type, COUNT(*) 
FROM staging_deletion_item 
WHERE batch_id = 'BATCH-2025' 
GROUP BY batch_id, key_type;
```
*(ผลลัพธ์ควรแสดงจำนวนแถวตรงกับไฟล์ตามแต่ละ `key_type`)*

---

### Step 2: ประมวลผลจำลอง (Analytical Dry Run)

รัน Procedure สำหรับ Dry Run — **ระบบจะทำการ Task Expansion (1:N) แตกงานลง `staging_deletion_task` และตรวจสอบความมีอยู่ของข้อมูลกับ Target Table ของกลุ่มนั้นโดยตรง (Root Rule) อัตโนมัติ**:
```sql
-- [แนะนำ] รันจำลองทุก Key Type และทุกกลุ่มตารางใน Batch นี้ในคำสั่งเดียว:
CALL run_data_deletion_dry_run('BATCH-2025');

-- หรือรันเฉพาะ Key Type เจาะจง:
CALL run_data_deletion_dry_run('BATCH-2025', 'ORDER_NO');

-- หรือรันเฉพาะกลุ่มตารางเจาะจง:
CALL run_data_deletion_dry_run('BATCH-2025', NULL, 'ORDERS');
```

**คำสั่งตรวจสอบผลลัพธ์อัตโนมัติ (Verification Reports for Dry Run):**
สามารถสั่งรันสคริปต์รายงาน [`sql/05_report_verify_dry_run.sql`](file:///c:/KK/Workspace/AntigravityProject/data-deletion/sql/05_report_verify_dry_run.sql) เพื่อดูผลลัพธ์ครบทั้ง 5 หัวข้อในคราวเดียว:
```bash
psql -h localhost -U postgres -d deletion_db -v target_batch='BATCH-2025' -f sql/05_report_verify_dry_run.sql
```

#### ตัวอย่างผลลัพธ์รายงาน Dry Run (Target Table Level):

**Report 1: Ingestion & Target Table Mapping Verification**
```text
  target_table   | execution_order | key_type | master_keys_count | mapped_tasks_count |          ingested_at          
-----------------+-----------------+----------+-------------------+--------------------+-------------------------------
 order_item_logs |               1 | ORDER_NO |              1002 |               1002 | 2026-09-20 06:11:59.848219+00
 order_items     |               2 | ORDER_NO |              1002 |               1002 | 2026-09-20 06:11:59.848219+00
 orders          |               3 | ORDER_NO |              1002 |               1002 | 2026-09-20 06:11:59.848219+00
```

**Report 2: Task Validation Summary & Match Rate (per Target Table)**
```text
  target_table   | execution_order | total_tasks | valid_matched_keys | not_found_keys | pending_tasks | match_rate_pct 
-----------------+-----------------+-------------+--------------------+----------------+---------------+----------------
 order_item_logs |               1 |        1002 |               1000 |              2 |             0 |          99.80
 order_items     |               2 |        1002 |               1000 |              2 |             0 |          99.80
 orders          |               3 |        1002 |               1000 |              2 |             0 |          99.80
```

**Report 3: Exception List: Missing Keys (`NOT_FOUND` List per Root Target Table)**
*(ส่งรายการนี้กลับให้ Data Owner ตรวจสอบว่าคีย์พิมพ์ผิดหรือถูกลบไปแล้ว)*
```text
 root_target_table | key_type |   key_no    |  status   |          created_at           
-------------------+----------+-------------+-----------+-------------------------------
 orders            | ORDER_NO | DUMMY-99901 | NOT_FOUND | 2026-09-20 06:11:59.899821+00
 orders            | ORDER_NO | DUMMY-99902 | NOT_FOUND | 2026-09-20 06:11:59.899821+00
```

**Report 4: Bottom-Up Estimated Rows to Delete (per Target Table)**
```text
  target_table   | execution_order | estimated_rows_to_delete |         estimated_at          
-----------------+-----------------+--------------------------+-------------------------------
 order_item_logs |               1 |                     1000 | 2026-09-20 06:11:59.899821+00
 order_items     |               2 |                     1000 | 2026-09-20 06:11:59.899821+00
 orders          |               3 |                     1000 | 2026-09-20 06:11:59.899821+00
```

**Report 5: Formal Executive Sign-off Summary (Target Table Level)**
```text
         batch_id         |  target_table   | execution_order | key_types | total_master_keys | valid_matched_keys | not_found_keys | match_rate_pct | estimated_rows_to_purge 
--------------------------+-----------------+-----------------+-----------+-------------------+--------------------+----------------+----------------+-------------------------
 TEST-PIPELINE-1789884718 | order_item_logs |               1 | ORDER_NO  |              1002 |               1000 |              2 |          99.80 |                    1000
 TEST-PIPELINE-1789884718 | order_items     |               2 | ORDER_NO  |              1002 |               1000 |              2 |          99.80 |                    1000
 TEST-PIPELINE-1789884718 | orders          |               3 | ORDER_NO  |              1002 |               1000 |              2 |          99.80 |                    1000
```

---

### Step 3: ส่งรายงานและขออนุมัติ (Sign-off)

Export ข้อมูลจากตาราง `deletion_dry_run_summary` ส่งให้ Approver:

**แบบฟอร์มการอนุมัติ (Sign-off Template):**
```
=====================================================
YEARLY DATA DELETION SIGN-OFF REQUEST
=====================================================
Batch ID:         BATCH-2025
Key Types:        CUSTOMER_ID, ORDER_NO
Groups Target:    ORDERS, INVOICES
Simulation Date:  2026-09-20 10:00:00

ESTIMATED ROWS TO BE PURGED:
[ORDERS Group]
1. order_item_logs (Grandchild):  12,000 rows
2. order_items     (Child):        6,000 rows
3. orders          (Parent):       2,000 rows

[INVOICES Group]
1. invoice_items   (Child):        2,000 rows
2. invoices        (Parent):       1,000 rows

TOTAL ROWS PURGED ACROSS ALL GROUPS: 23,000 rows
NOT FOUND KEYS (DETECTED & SKIPPED):     10 keys

Approved by: ________________________
Date:        ________________________
=====================================================
```

---

### Step 4: สั่งลบจริง (Execution Phase)

เมื่อได้รับอนุมัติแล้ว ให้รันคำสั่งลบจริง — **สามารถสั่งลบทุกกลุ่มงานในคำสั่งเดียวได้ทันที**:

```sql
-- [แนะนำ] สั่งลบทุกกลุ่มตารางใน Batch นี้ในคำสั่งเดียว:
CALL run_data_deletion('BATCH-2025');

-- หรือสั่งลบเฉพาะกลุ่มตารางที่ต้องการ:
CALL run_data_deletion('BATCH-2025', 'ORDERS');

-- หรือสั่งลบเฉพาะตารางลูกชั้นล่างก่อน (Granular Mode):
CALL run_data_deletion('BATCH-2025', 'ORDERS', 1); -- ลบเฉพาะ Grandchild
```

---

### Step 5: ตรวจสอบผลลัพธ์หลังการลบ (Post-Audit & Reconciliation)

**คำสั่งตรวจสอบผลลัพธ์อัตโนมัติ (Verification Reports for Real Deletion):**
สามารถสั่งรันสคริปต์รายงาน [`sql/06_report_verify_real_deletion.sql`](file:///c:/KK/Workspace/AntigravityProject/data-deletion/sql/06_report_verify_real_deletion.sql) เพื่อตรวจสอบความถูกต้องครบทั้ง 5 หัวข้อ:
```bash
psql -h localhost -U postgres -d deletion_db -v target_batch='BATCH-2025' -f sql/06_report_verify_real_deletion.sql
```

#### ตัวอย่างผลลัพธ์รายงาน Real Deletion Verification (Target Table Level):

**Report 1: Task Execution Progress & Completion Audit (per Target Table)**
*(ยืนยันว่างานเสร็จสิ้น 100% ไม่มีงานค้างและไม่มี error รายตาราง)*
```text
  target_table   | execution_order | total_tasks | completed_tasks | remaining_tasks | skipped_not_found | failed_errors | progress_pct |    execution_status    
-----------------+-----------------+-------------+-----------------+-----------------+-------------------+---------------+--------------+------------------------
 order_item_logs |               1 |        1002 |            1000 |               0 |                 2 |             0 |       100.00 | PASSED: 100% COMPLETED
 order_items     |               2 |        1002 |            1000 |               0 |                 2 |             0 |       100.00 | PASSED: 100% COMPLETED
 orders          |               3 |        1002 |            1000 |               0 |                 2 |             0 |       100.00 | PASSED: 100% COMPLETED
```

**Report 2: 100% Reconciliation & Variance Report (Dry Run vs Actual Deleted)**
*(เกณฑ์ผ่าน: ค่า variance ต้องเป็น 0 เสมอ และได้สถานะ MATCH 100%)*
```text
         batch_id         |  target_table   | exec_order | dry_run_estimated | actual_deleted | variance | reconciliation_status 
--------------------------+-----------------+------------+-------------------+----------------+----------+-----------------------
 TEST-PIPELINE-1789884718 | order_item_logs |          1 |              1000 |           1000 |        0 | MATCH (100%)
 TEST-PIPELINE-1789884718 | order_items     |          2 |              1000 |           1000 |        0 | MATCH (100%)
 TEST-PIPELINE-1789884718 | orders          |          3 |              1000 |           1000 |        0 | MATCH (100%)
```

**Report 3: Zero-Leakage Residual Sanity Check (Target Table Level)**
*(ยืนยันว่าไม่มีแถวข้อมูลของคีย์ที่สั่งลบหลงเหลืออยู่ในตารางหลัก)*
```text
         batch_id         | target_table | completed_keys_checked | leaked_residual_keys |   sanity_status    
--------------------------+--------------+------------------------+----------------------+--------------------
 TEST-PIPELINE-1789884718 | orders       |                   1000 |                    0 | CLEAN (0 RESIDUAL)
```

**Report 4: Deletion Throughput & Performance Summary (per Target Table)**
```text
  target_table   | chunk_batches | total_rows_deleted |        first_chunk_at         |         last_chunk_at         | duration_seconds | rows_per_second 
-----------------+---------------+--------------------+-------------------------------+-------------------------------+------------------+-----------------
 order_item_logs |             2 |               1000 | 2026-09-20 06:12:00.073984+00 | 2026-09-20 06:12:00.199333+00 |             0.13 |         7977.73
 order_items     |             2 |               1000 | 2026-09-20 06:12:00.073984+00 | 2026-09-20 06:12:00.199333+00 |             0.13 |         7977.73
 orders          |             2 |               1000 | 2026-09-20 06:12:00.073984+00 | 2026-09-20 06:12:00.199333+00 |             0.13 |         7977.73
```

**Report 5: Compliance Certificate of Destruction / Audit Trail (Target Table Level)**
```text
         batch_id         |  target_table   | execution_order | total_purged_rows |       purge_started_at        |      purge_completed_at       | completed_keys_count | missing_keys_count 
--------------------------+-----------------+-----------------+-------------------+-------------------------------+-------------------------------+----------------------+--------------------
 TEST-PIPELINE-1789884718 | order_item_logs |               1 |              1000 | 2026-09-20 06:12:00.073984+00 | 2026-09-20 06:12:00.199333+00 |                 1000 |                  2
 TEST-PIPELINE-1789884718 | order_items     |               2 |              1000 | 2026-09-20 06:12:00.073984+00 | 2026-09-20 06:12:00.199333+00 |                 1000 |                  2
 TEST-PIPELINE-1789884718 | orders          |               3 |              1000 | 2026-09-20 06:12:00.073984+00 | 2026-09-20 06:12:00.199333+00 |                 1000 |                  2
```

---

### Step 6: บำรุงรักษาฐานข้อมูล (Post-Maintenance)

รันคำสั่งคืนพื้นที่และอัปเดตสถิติ Optimizer:
```sql
VACUUM ANALYZE order_item_logs;
VACUUM ANALYZE order_items;
VACUUM ANALYZE orders;
VACUUM ANALYZE staging_deletion_item;
VACUUM ANALYZE staging_deletion_task;

-- Reset Autovacuum กลับสู่ค่าเดิม
ALTER TABLE orders RESET (autovacuum_vacuum_scale_factor);
ALTER TABLE order_items RESET (autovacuum_vacuum_scale_factor);
ALTER TABLE order_item_logs RESET (autovacuum_vacuum_scale_factor);
```

---

## 4. Monitoring ระหว่างการลบ (Observability Queries)

### 4.1 ตรวจสอบความคืบหน้าราย Chunk จากตาราง Task
```sql
-- ดูจำนวน tasks ที่ทำเสร็จแล้วเทียบกับที่เหลือ
SELECT 
    group_code,
    status,
    COUNT(*) AS count,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (PARTITION BY group_code), 2) AS percentage
FROM staging_deletion_task 
WHERE batch_id = 'BATCH-2025' 
GROUP BY group_code, status
ORDER BY group_code, status;
```

### 4.2 ตรวจสอบ Throughput การลบใน Audit Log
```sql
SELECT 
    target_table,
    COUNT(*) AS chunk_count,
    SUM(deleted_row_count) AS total_deleted,
    MIN(executed_at) AS started_at,
    MAX(executed_at) AS last_chunk_at,
    ROUND(SUM(deleted_row_count) / NULLIF(EXTRACT(EPOCH FROM (MAX(executed_at) - MIN(executed_at))), 0), 2) AS rows_per_sec
FROM deletion_audit_log 
WHERE batch_id = 'BATCH-2025' 
GROUP BY target_table;
```

### 4.3 ตรวจสอบ Replication Lag
```sql
SELECT 
    application_name,
    client_addr,
    state,
    sync_state,
    pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes,
    ROUND(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) / 1024.0 / 1024.0, 2) AS lag_mb
FROM pg_stat_replication;
```

---

## 5. การกู้คืนเมื่อเกิดปัญหา (Troubleshooting & Disaster Recovery)

### สถานการณ์ 1: สคริปต์หรือเน็ตหลุดระหว่างรัน (Interrupted Execution)
- **สถานการณ์:** Connection หลุดขณะกำลังรันที่ Chunk 120 จาก 400 Chunks
- **สถานะระบบ:** 
  - Chunk ที่ 1 ถึง 119 ถูก `COMMIT;` ไปแล้ว และบันทึกลง Audit Log ครบถ้วน
  - Chunk ที่ 120 ที่ยังไม่เสร็จถูก PostgreSQL `ROLLBACK;` อัตโนมัติ Tasks ของ Chunk นั้นใน `staging_deletion_task` ยังคงสถานะ `VALIDATED`
- **แนวทางแก้ไข:**
  - รันคำสั่งเดิมซ้ำทันที:
    ```sql
    CALL run_data_deletion('BATCH-2025', 'ORDERS');
    ```
  - ระบบจะดึงเฉพาะรายการที่ยังคงเป็น `VALIDATED` ใน `staging_deletion_task` มาทำต่อจนจบโดยอัตโนมัติ (Zero Duplicate Deletion)

---

### สถานการณ์ 2: ติด Error Foreign Key หรือ Trigger (Stop the World)
- **สถานการณ์:** เกิด Error เช่น `foreign key constraint violation` หรือ `disk full`
- **อาการ:** Procedure หยุดทำงานทันที และพ่น Error Message
- **แนวทางตรวจสอบ:**
  1. ดู Chunk ล่าสุดที่ทำสำเร็จใน `deletion_audit_log`
  2. ตรวจสอบ Tasks ที่ค้างใน `staging_deletion_task WHERE status = 'VALIDATED'`
  3. เมื่อแก้ปัญหาที่ Schema/Rule เรียบร้อยแล้ว สั่งรัน `CALL run_data_deletion(...)` อีกครั้งเพื่อทำงานต่อ

---

### สถานการณ์ 3: ต้องการยกเลิกหรือ Pause งานชั่วคราว
- **การ Pause:** สามารถ Cancel Query ได้ทันทีผ่าน pgAdmin หรือคำสั่ง:
  ```sql
  SELECT pg_cancel_backend(pid) 
  FROM pg_stat_activity 
  WHERE query LIKE '%run_data_deletion%';
  ```
  *(Chunk ล่าสุดจะ Rollback ส่วน Chunk ก่อนหน้ายังคงสมบูรณ์)*
- **การปรับ Throttle กลางคัน:**
  หากระบบเริ่มหน่วง สามารถปรับ `throttle_sec` ในตารางคอนฟิกได้ทันที:
  ```sql
  UPDATE deletion_group SET throttle_sec = 0.20 WHERE group_code = 'ORDERS';
  ```
  *(Chunk ถัดไปจะใช้ค่าหน่วงเวลาใหม่ทันทีโดยไม่ต้อง Restart งาน)*
