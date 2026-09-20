# Operational Manual: Yearly Data Deletion System
### Standard Operating Procedure (SOP), Monitoring & Troubleshooting Guide

---

## 1. บทบาทและความรับผิดชอบ (Roles & Responsibilities)

| บทบาท | หน้าที่ |
|---|---|
| **Data Owner / Ops Team** | จัดเตรียมไฟล์ Excel/CSV ที่ผ่านการคัดกรอง Key ที่ครบกำหนดลบประจำปี |
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
      SELECT target_table FROM deletion_rule WHERE group_code = 'ORDERS'
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
  AND ccu.table_name IN (SELECT target_table FROM deletion_rule WHERE group_code = 'ORDERS');
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
python scripts/ingest.py \
  --file /path/to/yearly_deletion_2025.xlsx \
  --batch BATCH-2025 \
  --group ORDERS \
  --db-url postgresql://postgres:password123@localhost:5432/deletion_db
```

**ตรวจสอบความเรียบร้อย:**
```sql
SELECT batch_id, group_code, status, COUNT(*) 
FROM staging_deletion_item 
WHERE batch_id = 'BATCH-2025' 
GROUP BY batch_id, group_code, status;
```
*(ผลลัพธ์ควรแสดงจำนวนแถวตรงกับไฟล์ และมี status = `'PENDING'`)*

---

### Step 2: ประมวลผลจำลอง (Analytical Dry Run)

รัน Procedure สำหรับ Dry Run — **สามารถรันทุกกลุ่มงานในคำสั่งเดียวได้ทันที**:
```sql
-- [แนะนำ] รันจำลองทุกกลุ่มงานใน Batch นี้ในคำสั่งเดียว:
CALL run_data_deletion_dry_run('BATCH-2025');

-- หรือรันเฉพาะกลุ่มเจาะจง:
CALL run_data_deletion_dry_run('BATCH-2025', 'ORDERS');
```

**ตรวจสอบผลลัพธ์:**
```sql
-- 1. ดูผลสรุปจำนวนแถวที่จะถูกลบแยกตามกลุ่มงาน
SELECT group_code, target_table, execution_order, estimated_rows_to_delete 
FROM deletion_dry_run_summary 
WHERE batch_id = 'BATCH-2025' 
ORDER BY group_code, execution_order;

-- 2. ดูสถานะของ Keys แยกตามกลุ่มงาน
SELECT group_code, status, COUNT(*) 
FROM staging_deletion_item 
WHERE batch_id = 'BATCH-2025' 
GROUP BY group_code, status;
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
Groups Processed: ORDERS, INVOICES
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
NOT FOUND KEYS:                           0 keys

Approved by: ________________________
Date:        ________________________
=====================================================
```

---

### Step 4: สั่งลบจริง (Execution Phase)

เมื่อได้รับอนุมัติแล้ว ให้รันคำสั่งลบจริง — **สามารถสั่งลบทุกกลุ่มงานในคำสั่งเดียวได้ทันที**:

```sql
-- [แนะนำ] สั่งลบทุกกลุ่มงานใน Batch นี้ในคำสั่งเดียว:
CALL run_data_deletion('BATCH-2025');

-- หรือสั่งลบเฉพาะกลุ่มที่ต้องการ:
CALL run_data_deletion('BATCH-2025', 'ORDERS');

-- หรือสั่งลบเฉพาะตารางลูกชั้นล่างก่อน (Granular Mode):
CALL run_data_deletion('BATCH-2025', 'ORDERS', 1); -- ลบเฉพาะ Grandchild
```

---

### Step 5: ตรวจสอบผลลัพธ์หลังการลบ (Post-Audit)

```sql
-- 1. ตรวจสอบสถานะ Staging
SELECT status, COUNT(*) 
FROM staging_deletion_item 
WHERE batch_id = 'BATCH-2025' 
GROUP BY status;
-- ควรได้ COMPLETED ครบทั้งหมด

-- 2. ตรวจสอบจำนวนแถวที่ลบจริงใน Audit Log
SELECT target_table, SUM(deleted_row_count) AS total_deleted 
FROM deletion_audit_log 
WHERE batch_id = 'BATCH-2025' 
GROUP BY target_table;
-- ตัวเลขควรตรงกับ estimated_rows_to_delete ใน Dry Run Summary
```

---

### Step 6: บำรุงรักษาฐานข้อมูล (Post-Maintenance)

รันคำสั่งคืนพื้นที่และอัปเดตสถิติ Optimizer:
```sql
VACUUM ANALYZE order_item_logs;
VACUUM ANALYZE order_items;
VACUUM ANALYZE orders;

-- Reset Autovacuum กลับสู่ค่าเดิม
ALTER TABLE orders RESET (autovacuum_vacuum_scale_factor);
ALTER TABLE order_items RESET (autovacuum_vacuum_scale_factor);
ALTER TABLE order_item_logs RESET (autovacuum_vacuum_scale_factor);
```

---

## 4. Monitoring ระหว่างการลบ (Observability Queries)

### 4.1 ตรวจสอบความคืบหน้าราย Chunk
```sql
-- ดูจำนวน keys ที่ทำเสร็จแล้วเทียบกับที่เหลือ
SELECT 
    status,
    COUNT(*) AS count,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2) AS percentage
FROM staging_deletion_item 
WHERE batch_id = 'BATCH-2025' 
GROUP BY status;
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
  - Chunk ที่ 120 ที่ยังไม่เสร็จถูก PostgreSQL `ROLLBACK;` อัตโนมัติ Keys ของ Chunk นั้นยังคงสถานะ `VALIDATED`
- **แนวทางแก้ไข:**
  - รันคำสั่งเดิมซ้ำทันที:
    ```sql
    CALL run_data_deletion('BATCH-2025', 'ORDERS');
    ```
  - ระบบจะดึงเฉพาะรายการที่ยังคงเป็น `VALIDATED` มาทำต่อจนจบโดยอัตโนมัติ (Zero Duplicate Deletion)

---

### สถานการณ์ 2: ติด Error Foreign Key หรือ Trigger (Stop the World)
- **สถานการณ์:** เกิด Error เช่น `foreign key constraint violation` หรือ `disk full`
- **อาการ:** Procedure หยุดทำงานทันที และพ่น Error Message
- **แนวทางตรวจสอบ:**
  1. ดู Chunk ล่าสุดที่ทำสำเร็จใน `deletion_audit_log`
  2. ตรวจสอบว่ามี Table หรือ Key ใดที่ตกหล่นจาก Rule หรือไม่
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
