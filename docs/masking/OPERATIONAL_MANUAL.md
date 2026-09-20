# Operational Manual: Key-Driven Data Masking System
### Standard Operating Procedure (SOP), Pre-flight Checklist, DPO Sign-off Runbook & Sample Reports
### Version 1.0 (PostgreSQL 16+) | Key-Driven 2-Tier Architecture

---

## 1. บทบาทและความรับผิดชอบ (Roles & Responsibilities)

| บทบาท | ความรับผิดชอบหลัก |
|---|---|
| **Data Steward / Business Ops** | • รวบรวมและจัดเตรียมไฟล์ Excel/CSV ที่มีคอลัมน์ `key_type` และ `key_no` ของกลุ่มเป้าหมายที่ต้องการ Masking<br/>• รันคำสั่ง Ingestion ผ่าน `scripts/masking/ingest.py` |
| **Data Protection Officer (DPO)** | • ตรวจสอบผลลัพธ์จากรายงาน Analytical Dry Run<br/>• ตรวจสอบตัวอย่าง **Before / After Preview** ว่าผ่านเกณฑ์ PDPA หรือไม่<br/>• ลงนามอนุมัติ (Sign-off) ก่อนเริ่มกระบวนการแปลงข้อมูลจริง |
| **Database Administrator (DBA)** | • รันคำสั่ง Pre-flight Check (ตรวจ Unique index, Column length, Active triggers)<br/>• เรียกใช้งาน Stored Procedure `run_data_masking`<br/>• ตรวจสอบ Performance, Throughput, Replication Lag และจัดเก็บ Audit Trail |

---

## 2. Pre-flight Safety Checklist (ตรวจสอบก่อนเริ่มรันงาน)

ก่อนสั่งรันงาน ให้ DBA ตรวจสอบความพร้อมและความปลอดภัยของระบบตามรายการต่อไปนี้:

- [ ] **1. Unique Index Collision Check:**
  ตรวจสอบว่าไม่มีคอลัมน์ใดที่อยู่ใน `masking_rule` ผูกกับ UNIQUE Constraint หรือ UNIQUE Index แล้วถูกแปลงด้วยค่าคงที่ (Static value)
  ```sql
  -- รันคำสั่งจาก sql/masking/05_preflight_checks.sql
  SELECT r.target_table, r.column_name, r.mask_expression, i.relname AS index_name
  FROM masking_rule r
  JOIN pg_class t ON t.relname = r.target_table
  JOIN pg_index ix ON ix.indrelid = t.oid
  JOIN pg_class i ON i.oid = ix.indexrelid
  JOIN pg_attribute a ON a.attrelid = t.oid AND a.attname = r.column_name
  WHERE r.is_active = TRUE AND ix.indisunique = TRUE AND a.attnum = ANY(ix.indkey);
  ```
  *(หากพบคอลัมน์ที่เป็น UNIQUE ต้องใช้สูตร Masking ที่ให้ค่าไม่ซ้ำ เช่น `fn_mask_salted_hash` หรือ Dynamic Sequence)*

- [ ] **2. Column Data Length Check:**
  ตรวจสอบว่าความยาวของคอลัมน์ (`VARCHAR(n)`) เพียงพอที่จะรองรับผลลัพธ์จากการแปลงข้อมูลหรือไม่
  ```sql
  SELECT r.target_table, r.column_name, c.character_maximum_length, r.mask_expression
  FROM masking_rule r
  JOIN information_schema.columns c 
    ON c.table_name = r.target_table AND c.column_name = r.column_name
  WHERE r.is_active = TRUE;
  ```

- [ ] **3. Active UPDATE Trigger Check:**
  ตรวจสอบว่ามี Trigger บนตารางเป้าหมายที่อาจขัดขวางหรือทำให้การ UPDATE ช้าลงหรือไม่
  ```sql
  SELECT event_object_table, trigger_name, action_timing
  FROM information_schema.triggers
  WHERE event_manipulation = 'UPDATE'
    AND event_object_table IN (SELECT target_table FROM masking_rule WHERE is_active = TRUE);
  ```

---

## 3. ขั้นตอนการปฏิบัติงานทีละขั้นตอน (Step-by-Step SOP)

### Step 1: นำเข้า Key เข้าระบบ (Ingestion)

รันคำสั่ง Ingest เพื่อนำรายชื่อ Key จากไฟล์ Excel เข้าสู่ตาราง `staging_masking_item`:

```bash
# ตัวอย่าง: นำเข้าไฟล์ Excel รายการลูกค้าที่ต้องการลบสิทธิ์ PII
python scripts/masking/ingest.py \
  --file mock_data/pdpa_request_customers.xlsx \
  --batch MASK-2026-Q1 \
  --key-type CUSTOMER_ID
```

#### ตัวอย่างผลลัพธ์หน้าจอ CLI (Console Output):
```text
Reading masking keys file: mock_data/pdpa_request_customers.xlsx (format: .xlsx)
Using column 'customer_id' with key_type='CUSTOMER_ID'
WARNING: Found 4 duplicate keys in file. Deduplicated.
Unique keys to ingest: 1002
Connecting to database: localhost:5432/deletion_db...
SUCCESS: Ingested 1002 keys into staging_masking_item
  batch_id: MASK-2026-Q1
  Key types breakdown: {'CUSTOMER_ID': 1002}
```

---

### Step 2: ประมวลผลจำลอง (Analytical Dry Run)

เรียก Stored Procedure เพื่อตรวจสอบความมีอยู่ของข้อมูล และสร้าง Before/After Sample Preview:

```sql
CALL run_data_masking_dry_run('MASK-2026-Q1');
```

#### ตัวอย่างผลลัพธ์ข้อความแจ้งเตือน (PL/pgSQL RAISE NOTICE Log):
```text
NOTICE:  ================================================================================
NOTICE:  🚀 Starting Data Masking Analytical Dry Run for Batch: MASK-2026-Q1
NOTICE:  ================================================================================
NOTICE:  📦 Total Master Keys in staging_masking_item: 1002
NOTICE:  --------------------------------------------------------------------------------
NOTICE:  👉 Processing Masking Group: CUST_PII (Key Type: CUSTOMER_ID)
NOTICE:     Key Validation: VALIDATED = 1000, NOT_FOUND = 2
NOTICE:     ✅ Rule [customers.email] (Order 1): ~1000 rows | Logic: fn_mask_email(email)
NOTICE:     ✅ Rule [customers.phone_number] (Order 1): ~1000 rows | Logic: fn_mask_phone(phone_number)
NOTICE:     ✅ Rule [customers.citizen_id] (Order 1): ~1000 rows | Logic: fn_mask_citizen_id(citizen_id)
NOTICE:     ✅ Rule [customers.customer_name] (Order 1): ~1000 rows | Logic: fn_mask_name(customer_name)
NOTICE:     ✅ Rule [customers.address] (Order 1): ~1000 rows | Logic: 'REDACTED_ADDR_' || LPAD(id::text, 6, '0')
NOTICE:  ================================================================================
NOTICE:  🎉 Data Masking Dry Run Completed Successfully for Batch: MASK-2026-Q1
NOTICE:  ================================================================================
```

---

### Step 3: DPO Sign-Off & Review (การอนุมัติโดยเจ้าหน้าที่คุ้มครองข้อมูล)

เจ้าหน้าที่คุ้มครองข้อมูลส่วนบุคคล (DPO) เรียกดูรายงานตัวอย่างข้อมูลก่อนและหลังการ Masking (ดูรายงานละเอียดในข้อ 4.3):

```sql
SELECT 
    s.target_table,
    s.column_name,
    s.mask_expression,
    p.preview->>'before' AS sample_original_value,
    p.preview->>'after'  AS sample_masked_value
FROM masking_dry_run_summary s,
     jsonb_array_elements(s.sample_preview) AS p(preview)
WHERE s.batch_id = 'MASK-2026-Q1'
ORDER BY s.target_table, s.column_name;
```

**เกณฑ์การตรวจสอบของ DPO:**
- อีเมล เบอร์โทรศัพท์ และเลขบัตรประชาชน ถูกบดบังตามมาตรฐาน ไม่มีค่าชี้ตัวบุคคลหลงเหลือ
- DPO ลงนามอนุมัติ (Sign-off) เพื่อให้ DBA ดำเนินการต่อใน Step 4

---

### Step 4: แปลงข้อมูลจริง (Real Masking Execution)

เมื่อได้รับอนุมัติแล้ว DBA รันคำสั่งแปลงข้อมูลจริง:

```sql
-- รันแปลงข้อมูลทุกกลุ่มใน Batch
CALL run_data_masking('MASK-2026-Q1');

-- หรือระบุเฉพาะกลุ่มเจาะจง
CALL run_data_masking('MASK-2026-Q1', 'CUST_PII');
```

#### ตัวอย่างผลลัพธ์ข้อความแจ้งเตือน Real Masking (Chunked Commit Log):
```text
NOTICE:  ================================================================================
NOTICE:  🚀 Starting Real Data Masking Engine for Batch: MASK-2026-Q1
NOTICE:  ================================================================================
NOTICE:  👉 Masking Group: CUST_PII | Chunk Size: 500 | Throttle: 0.05s
NOTICE:     [Chunk #1] Table customers: masked 500 rows on columns [email, phone_number, citizen_id, customer_name, address] (0.142 s)
NOTICE:     [Chunk #2] Table customers: masked 500 rows on columns [email, phone_number, citizen_id, customer_name, address] (0.138 s)
NOTICE:  🏁 Group CUST_PII processing finished. Total chunks: 2
NOTICE:  ================================================================================
NOTICE:  🎉 Data Masking Engine Completed Successfully for Batch: MASK-2026-Q1
NOTICE:  📊 Total Records Masked: 1000
NOTICE:  ================================================================================
```

---

### Step 5: ตรวจสอบผลลัพธ์และจัดเก็บหลักฐาน (Audit & Verification)

ตรวจสอบประวัติการแปลงข้อมูลจาก Audit Trail:

```sql
SELECT 
    target_table, 
    columns_masked, 
    SUM(masked_row_count) AS total_rows, 
    COUNT(*) AS total_chunks,
    ROUND(SUM(duration_sec), 2) AS total_seconds
FROM masking_audit_log 
WHERE batch_id = 'MASK-2026-Q1'
GROUP BY target_table, columns_masked;
```

---

## 4. ตัวอย่างผลลัพธ์รายงานจากการปฏิบัติงานจริง (Sample Operational Reports)

สามารถสั่งรันชุดคำสั่งตรวจสอบผลลัพธ์ได้จากสคริปต์ SQL:
- [`sql/masking/06_report_verify_dry_run.sql`](file:///c:/KK/Workspace/AntigravityProject/data-deletion/sql/masking/06_report_verify_dry_run.sql) สำหรับรายงาน Phase 1 (Dry Run)
- [`sql/masking/07_report_verify_real_masking.sql`](file:///c:/KK/Workspace/AntigravityProject/data-deletion/sql/masking/07_report_verify_real_masking.sql) สำหรับรายงาน Phase 2 (Real Masking)

---

### 4.1 รายงานสรุปสถานะการ Validate รายการ Key (Task Status Breakdown)
แสดงภาพรวมของ Key ที่นำเข้าว่าพบข้อมูลในระบบเพื่อนำไปประมวลผลต่อกี่รายการ และไม่พบกี่รายการ:

```sql
SELECT 
    group_code,
    status,
    COUNT(*) AS task_count,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (PARTITION BY group_code), 2) AS pct
FROM staging_masking_task
WHERE batch_id = 'MASK-2026-Q1'
GROUP BY group_code, status
ORDER BY group_code, status;
```

#### 📋 ตัวอย่างผลลัพธ์:
```text
 group_code |   status   | task_count |  pct   
------------+------------+------------+--------
 CUST_PII   | NOT_FOUND  |          2 |   0.20
 CUST_PII   | VALIDATED  |       1000 |  99.80
(2 rows)
```

---

### 4.2 รายงานประเมินจำนวนแถวที่จะถูก Masking (Estimated Rows per Rule)
แสดงรายการตาราง คอลัมน์ และจำนวนแถวโดยประมาณที่ต้องทำการ UPDATE:

```sql
SELECT 
    group_code,
    target_table,
    column_name,
    execution_order,
    mask_expression,
    estimated_rows_to_mask
FROM masking_dry_run_summary
WHERE batch_id = 'MASK-2026-Q1'
ORDER BY group_code, execution_order, target_table, column_name;
```

#### 📋 ตัวอย่างผลลัพธ์:
```text
 group_code | target_table |  column_name  | execution_order |             mask_expression             | estimated_rows_to_mask 
------------+--------------+---------------+-----------------+-----------------------------------------+------------------------
 CUST_PII   | customers    | address       |               1 | 'REDACTED_ADDR_' || LPAD(id::text,6,'0')|                   1000
 CUST_PII   | customers    | citizen_id    |               1 | fn_mask_citizen_id(citizen_id)          |                   1000
 CUST_PII   | customers    | customer_name |               1 | fn_mask_name(customer_name)             |                   1000
 CUST_PII   | customers    | email         |               1 | fn_mask_email(email)                    |                   1000
 CUST_PII   | customers    | phone_number  |               1 | fn_mask_phone(phone_number)             |                   1000
(5 rows)
```

---

### 4.3 รายงานตัวอย่าง Before vs After Value Preview สำหรับ DPO Sign-Off ⭐
*(รายงานหัวใจสำคัญที่สุด: นำข้อมูล JSONB ออกมาแสดงค่าตัวอย่างจริงเปรียบเทียบก่อนและหลังการแปลง เพื่อให้ DPO มั่นใจว่าข้อมูลถูกบดบังตามเกณฑ์ PDPA)*

```sql
SELECT 
    s.target_table,
    s.column_name,
    p.sample_index,
    p.preview->>'before' AS sample_original_value,
    p.preview->>'after'  AS sample_masked_value
FROM masking_dry_run_summary s,
     jsonb_array_elements(s.sample_preview) WITH ORDINALITY AS p(preview, sample_index)
WHERE s.batch_id = 'MASK-2026-Q1'
ORDER BY s.target_table, s.column_name, p.sample_index;
```

#### 📋 ตัวอย่างผลลัพธ์รายงานตรวจสอบตัวอย่างข้อมูล:
```text
 target_table |  column_name  | sample_index |       sample_original_value       |        sample_masked_value        
--------------+---------------+--------------+-----------------------------------+-----------------------------------
 customers    | address       |            1 | 123 Sukhumvit Rd, Bangkok 10110   | REDACTED_ADDR_000001
 customers    | address       |            2 | 45/2 Silom Rd, Bangrak 10500      | REDACTED_ADDR_000002
 customers    | citizen_id    |            1 | 1100500123456                     | 1-1005-XXXXX-56
 customers    | citizen_id    |            2 | 3100200889911                     | 3-1002-XXXXX-11
 customers    | customer_name |            1 | Somchai Prasert                   | S****** P******
 customers    | customer_name |            2 | Jennifer Aniston                  | J******* A******
 customers    | email         |            1 | somchai.prasert@enterprise.co.th  | s***t@e******.th
 customers    | email         |            2 | jennifer.a@gmail.com              | j***a@g******.com
 customers    | phone_number  |            1 | 0812345678                        | 081-XXX-5678
 customers    | phone_number  |            2 | 025891234                         | 02-XXX-1234
(10 rows)
```

---

### 4.4 แบบฟอร์มขออนุมัติอย่างเป็นทางการ (DPO Sign-Off Template Form)
เมื่อ DPO ตรวจสอบตัวอย่าง Before/After Preview ในข้อ 4.3 เรียบร้อยแล้ว ให้จัดทำใบปะหน้าอนุมัติตามแบบฟอร์มนี้:

```text
================================================================================
          DATA MASKING & ANONYMIZATION COMPLIANCE SIGN-OFF REQUEST
================================================================================
Batch Identifier:      MASK-2026-Q1
Key Type:              CUSTOMER_ID
Masking Groups:        CUST_PII
Execution Scope:       Strictly Target Keys from Excel (Zero Untargeted Impact)
Simulation Timestamp:  2026-09-20 14:00:00 ICT

SUMMARY OF ESTIMATED RECORDS TO BE MASKED:
Target Table: customers
  - Column: email         -> 1,000 records (Pattern: fn_mask_email)
  - Column: phone_number  -> 1,000 records (Pattern: fn_mask_phone)
  - Column: citizen_id    -> 1,000 records (Pattern: fn_mask_citizen_id)
  - Column: customer_name -> 1,000 records (Pattern: fn_mask_name)
  - Column: address       -> 1,000 records (Pattern: REDACTED_ADDR_XXXXXX)

Total Keys Matched (VALIDATED): 1,000 keys (99.80%)
Total Missing Keys (NOT_FOUND):      2 keys (0.20% - Skipped safely)

DATA PRIVACY OFFICER (DPO) VERIFICATION:
[x] Sample Preview values inspected and approved.
[x] Direct PII obfuscated according to PDPA / GDPR guidelines.
[x] Referential joins & row preservation confirmed (0 deletions).

Approved By (DPO): ______________________________  Date: ____/____/________
Lead DBA Sign-off: ______________________________  Date: ____/____/________
================================================================================
```

---

### 4.5 รายงานตรวจสอบผลการรันจริง (Real Masking Execution Progress)
หลังรันคำสั่ง `CALL run_data_masking(...)` ยืนยันว่างานทุกชิ้นเสร็จสิ้น 100% ไม่มีค้าง:

```sql
SELECT 
    group_code,
    status,
    COUNT(*) AS total_tasks,
    MIN(processed_at) AS first_processed,
    MAX(processed_at) AS last_processed
FROM staging_masking_task
WHERE batch_id = 'MASK-2026-Q1'
GROUP BY group_code, status
ORDER BY group_code, status;
```

#### 📋 ตัวอย่างผลลัพธ์:
```text
 group_code |   status   | total_tasks |       first_processed         |        last_processed         
------------+------------+-------------+-------------------------------+-------------------------------
 CUST_PII   | COMPLETED  |        1000 | 2026-09-20 14:10:02.14521+07  | 2026-09-20 14:10:02.43588+07
 CUST_PII   | NOT_FOUND  |           2 |                               | 
(2 rows)
```

---

### 4.6 รายงานประวัติ Audit Trail และ Throughput การแปลงข้อมูล
สรุปจำนวน Chunk, ยอดแถวที่ถูกแปลง, เวลาที่ใช้ และอัตรา Throughput (Rows/Second):

```sql
SELECT 
    group_code,
    target_table,
    columns_masked,
    COUNT(*) AS total_chunks,
    SUM(masked_row_count) AS total_rows_masked,
    ROUND(AVG(masked_row_count), 1) AS avg_rows_per_chunk,
    ROUND(SUM(duration_sec), 2) AS total_duration_seconds,
    CASE 
        WHEN SUM(duration_sec) > 0 THEN ROUND(SUM(masked_row_count) / SUM(duration_sec), 0)
        ELSE 0 
    END AS rows_per_second
FROM masking_audit_log
WHERE batch_id = 'MASK-2026-Q1'
GROUP BY group_code, target_table, columns_masked
ORDER BY group_code, target_table;
```

#### 📋 ตัวอย่างผลลัพธ์:
```text
 group_code | target_table |                 columns_masked                  | total_chunks | total_rows_masked | avg_rows_per_chunk | total_duration_seconds | rows_per_second 
------------+--------------+-------------------------------------------------+--------------+-------------------+--------------------+------------------------+-----------------
 CUST_PII   | customers    | address, citizen_id, customer_name, email, phone|            2 |              1000 |              500.0 |                   0.28 |            3571
(1 row)
```

---

### 4.7 รายงานประวัติการ Commit ราย Chunk (Chunk Execution Timeline)
แสดงข้อมูลความเร็วและระยะเวลาในการรันแต่ละ Micro-Transaction อย่างโปร่งใส:

```sql
SELECT 
    chunk_number,
    target_table,
    masked_row_count,
    duration_sec,
    processed_at
FROM masking_audit_log
WHERE batch_id = 'MASK-2026-Q1'
ORDER BY chunk_number ASC;
```

#### 📋 ตัวอย่างผลลัพธ์:
```text
 chunk_number | target_table | masked_row_count | duration_sec |         processed_at          
--------------+--------------+------------------+--------------+-------------------------------
            1 | customers    |              500 |        0.142 | 2026-09-20 14:10:02.28721+07
            2 | customers    |              500 |        0.138 | 2026-09-20 14:10:02.43588+07
(2 rows)
```

---

### 4.8 รายงานตรวจสอบความถูกต้องของข้อมูลจริงในตารางเป้าหมาย (Post-Verification)

#### 1. ตรวจสอบว่าคีย์เป้าหมายถูก Masking จริงเรียบร้อยแล้ว:
```sql
SELECT customer_id, customer_name, email, phone_number, citizen_id, address
FROM customers
WHERE customer_id IN ('CUST-0001', 'CUST-0002');
```
*ผลลัพธ์ที่ได้:*
```text
 customer_id |  customer_name  |       email       | phone_number |   citizen_id    |       address        
-------------+-----------------+-------------------+--------------+-----------------+----------------------
 CUST-0001   | S****** P****** | s***t@e******.th  | 081-XXX-5678 | 1-1005-XXXXX-56 | REDACTED_ADDR_000001
 CUST-0002   | J******* A***** | j***a@g******.com | 02-XXX-1234  | 3-1002-XXXXX-11 | REDACTED_ADDR_000002
(2 rows)
```
*(ยืนยันว่า: ค่า PII ถูกบดบังตามคำสั่งเรียบร้อย)*

---

#### 2. ตรวจสอบว่าคีย์ที่ไม่ได้ระบุในไฟล์ Excel ยังคงค่าเดิมไว้ 100% (Zero Untargeted Impact):
```sql
SELECT customer_id, customer_name, email, phone_number, citizen_id, address
FROM customers
WHERE customer_id NOT IN (
    SELECT key_no FROM staging_masking_item WHERE batch_id = 'MASK-2026-Q1'
)
LIMIT 2;
```
*ผลลัพธ์ที่ได้:*
```text
 customer_id |  customer_name   |             email            | phone_number |  citizen_id   |             address             
-------------+------------------+------------------------------+--------------+---------------+---------------------------------
 CUST-5001   | Wichai Thongchai | wichai.thongchai@mycorp.com  | 0899988776   | 1103700445566 | 99 Rama 9 Rd, Huai Khwang 10310
 CUST-5002   | Anong Srisawat   | anong.s@outlook.co.th        | 0811122334   | 3100500998877 | 12 Phaholyothin Rd, Chatuchak   
(2 rows)
```
*(ยืนยันว่า: ระเบียนที่ไม่เกี่ยวข้อง ไม่ถูกแก้ไขแม้แต่อักขระเดียว)*

---

#### 3. ตรวจสอบว่าจำนวนแถวทั้งหมดในตารางยังเท่าเดิม (Zero Deletions):
```sql
SELECT COUNT(*) AS total_rows_after_masking FROM customers;
```
*ผลลัพธ์ที่ได้:*
```text
 total_rows_after_masking 
--------------------------
                    20000
(1 row)
```
*(ยืนยันว่า: ยอดแถวคงเดิมครบถ้วน 20,000 แถว ไม่มีการลบข้อมูลทิ้ง)*
