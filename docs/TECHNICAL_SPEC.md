# Technical Specification: Yearly Data Deletion System
### Version 2.0 | 2-Tier Item & Task Architecture | PostgreSQL 16 | 2026-09-20

---

## 1. System Overview

ระบบ **Yearly Data Deletion** ออกแบบมาเพื่อลบข้อมูลที่ปิดรอบบัญชีประจำปีจากฐานข้อมูล PostgreSQL อย่างปลอดภัยตามมาตรฐาน Enterprise และข้อกำหนดการกำกับดูแลข้อมูล (PDPA / Right to be Forgotten) โดยรองรับ:
- **สถาปัตยกรรม 2-Tier (Master Items & Group Tasks)**: แยกตัวตนของ Key จากภายนอก (`key_type`) ออกจากชุดตารางที่ต้องลบภายใน (`group_code`)
- **ความสัมพันธ์แบบ 1 : N (Multi-Group Deletion)**: 1 Identifier (เช่น `CUSTOMER_ID`) สามารถกระจายงานไปลบหลายกลุ่มตารางได้พร้อมกัน (เช่น Orders, Invoices, Profiles)
- **Bottom-Up FK-Safe**: ลบจากตารางลูกสุดไปหาตารางหลัก ป้องกัน Foreign Key Violation
- **Micro-Transactions & High Throughput**: แบ่งการลบเป็น Chunk ย่อย (เช่น 500–1,000 keys) พร้อม COMMIT ราย Chunk
- **2-Phase Safety**: ตรวจสอบความถูกต้องและจำลองตัวเลข (Analytical Dry Run) ให้ผู้อนุมัติลงนามก่อนลบจริง
- **Observability & Audit Trail**: บันทึกประวัติการลบราย Chunk ลงใน `deletion_audit_log` พร้อมสถานะแบบเรียลไทม์

---

## 2. System Architecture

```mermaid
flowchart TB
    subgraph INPUT["📥 Data Input Layer"]
        EXCEL["Excel (.xlsx)<br/>(Columns: key_type, key_no)"]
        CSV["CSV (.csv)<br/>(Columns: key_type, key_no)"]
    end

    subgraph PYTHON["🐍 Python Ingestion Layer"]
        INGEST["ingest.py<br/>• Auto-detect key_type & key_no<br/>• String sanitization & Trim<br/>• In-file Deduplication<br/>• Bulk INSERT into Master Items"]
    end

    subgraph DB["🐘 PostgreSQL Engine"]
        STG_ITEM["📥 staging_deletion_item<br/>(Master Keys: batch_id, key_type, key_no)"]

        subgraph PHASE1["Phase 1: Analytical Dry Run"]
            EXPAND["1. Task Expansion (1:N)<br/>Match s.key_type = g.key_type"]
            STG_TASK["📋 staging_deletion_task<br/>(Task Queue per Table Group)"]
            VALIDATE["2. Validate against Target Table<br/>• NOT_FOUND (Missing)<br/>• VALIDATED (Found)"]
            COUNT["3. Bottom-Up Estimated COUNT<br/>(Unified WHERE Clause)"]
            SUMMARY["📊 deletion_dry_run_summary<br/>(สรุปยอดประเมินรออนุมัติ)"]
        end

        subgraph PHASE2["Phase 2: Chunked Real Deletion"]
            FETCH["1. Fetch Chunk<br/>(FOR UPDATE SKIP LOCKED LIMIT 500)"]
            DELETE["2. Delete Bottom-Up<br/>Order 1 → 2 → 3<br/>(Grandchild → Child → Root Target)"]
            AUDIT["3. deletion_audit_log<br/>บันทึกยอดลบจริงราย Chunk"]
            COMMIT["4. Update task -> COMPLETED<br/>COMMIT + pg_sleep (Throttle)"]
        end
    end

    subgraph OUTPUT["📊 Operations & Compliance"]
        REPORT["Dry Run Sign-off Report<br/>(ส่ง Business/Ops อนุมัติ)"]
        AUDITREPORT["Compliance Audit Trail<br/>(หลักฐานการทำลายข้อมูล)"]
    end

    EXCEL --> INGEST
    CSV --> INGEST
    INGEST --> STG_ITEM

    STG_ITEM --> EXPAND
    EXPAND --> STG_TASK
    STG_TASK --> VALIDATE
    VALIDATE --> COUNT
    COUNT --> SUMMARY
    SUMMARY --> REPORT

    STG_TASK --> FETCH
    FETCH --> DELETE
    DELETE --> AUDIT
    AUDIT --> COMMIT
    COMMIT -->|"ยังมี VALIDATED เหลือ"| FETCH
    COMMIT -->|"ประมวลผลครบถ้วน"| AUDITREPORT
```

---

## 2.1 🔄 End-to-End Sequence Diagram

ไดอะแกรมแสดงลำดับขั้นตอนการโต้ตอบระหว่าง Actor, Script, Stored Procedures และ Tables ตลอดทั้งกระบวนการ:

```mermaid
sequenceDiagram
    autonumber
    actor Ops as Operations / DBA
    actor Approver as Business Approver
    participant File as Excel / CSV File
    participant CLI as Python ingest.py
    participant DBItem as staging_deletion_item
    participant DBTask as staging_deletion_task
    participant DBTarget as Target Tables (deletion_rule)
    participant DBSummary as deletion_dry_run_summary
    participant DBAudit as deletion_audit_log

    Note over Ops,File: 1. Ingestion Phase
    Ops->>File: เตรียมไฟล์ระบุ key_type และ key_no
    Ops->>CLI: python ingest.py --file keys.xlsx --batch BATCH-2025
    CLI->>File: อ่านและกรองข้อมูล (Deduplicate)
    CLI->>DBItem: Bulk INSERT INTO staging_deletion_item (batch_id, key_type, key_no)
    DBItem-->>CLI: สำเร็จ (บันทึก Master Keys)
    CLI-->>Ops: พิมพ์สรุปจำนวน Key ที่ Ingest สำเร็จ

    Note over Ops,DBSummary: 2. Phase 1: Analytical Dry Run
    Ops->>DBTask: CALL run_data_deletion_dry_run('BATCH-2025')
    Note right of DBTask: Step 2.1: Task Expansion (1:N)<br/>จับคู่ s.key_type = g.key_type
    DBTask->>DBTask: INSERT INTO staging_deletion_task (status='PENDING')
    
    Note right of DBTask: Step 2.2: Target Table Direct Validation<br/>(ตรวจสอบกับ Root Target Table สูงสุดของกลุ่ม)
    DBTask->>DBTarget: ตรวจสอบ NOT EXISTS (SELECT 1 FROM target_table WHERE ...)
    DBTask->>DBTask: ปรับ status เป็น 'NOT_FOUND' (หากไม่พบแถวในตาราง)
    DBTask->>DBTask: ปรับ status เป็น 'VALIDATED' (หากพบข้อมูล)

    Note right of DBTask: Step 2.3: Bottom-Up Count Estimation
    loop วนตาม deletion_rule ของแต่ละกลุ่ม
        DBTask->>DBTarget: SELECT COUNT(*) FROM target WHERE ... = ANY($1)
        DBTarget-->>DBSummary: INSERT INTO deletion_dry_run_summary
    end
    DBTask-->>Ops: พิมพ์สรุปผลผ่าน RAISE NOTICE

    Note over Ops,Approver: 3. Business Sign-off
    Ops->>DBSummary: Query สรุปยอดประเมินจาก deletion_dry_run_summary
    Ops->>Approver: ส่งรายงานขอยืนยันการลบ
    Approver-->>Ops: ตรวจสอบและลงนามอนุมัติ (Sign-off)

    Note over Ops,DBAudit: 4. Phase 2: Chunked Real Deletion
    Ops->>DBTask: CALL run_data_deletion('BATCH-2025')
    loop ประมวลผลทีละ Chunk (FOR UPDATE SKIP LOCKED LIMIT chunk_size)
        DBTask->>DBTask: ดึง Keys ที่ status = 'VALIDATED'
        loop ลบตามลำดับ Bottom-Up (Order 1 -> N)
            DBTask->>DBTarget: DELETE FROM target_table WHERE ... = ANY($chunk)
            DBTarget-->>DBAudit: INSERT INTO deletion_audit_log (deleted_row_count)
        end
        DBTask->>DBTask: UPDATE status = 'COMPLETED', processed_at = NOW()
        DBTask->>DBTask: COMMIT Micro-Transaction
        DBTask->>DBTask: PERFORM pg_sleep(throttle_sec)
    end
    DBTask-->>Ops: Deletion Completed for all groups!

    Note over Ops,DBTarget: 5. Post-Maintenance Phase
    Ops->>DBTarget: VACUUM ANALYZE target_tables;
    Ops->>DBAudit: Export หลักฐาน Audit Trail เพื่อ Compliance
```

---

## 3. Entity-Relationship Diagram

### 3.1 Framework Tables (ตารางระบบ Deletion)

```mermaid
erDiagram
    deletion_group ||--o{ deletion_rule : "has rules"
    deletion_group ||--o{ staging_deletion_task : "governs execution"
    staging_deletion_item ||--|{ staging_deletion_task : "expands to (1:N)"
    staging_deletion_task ||--o{ deletion_audit_log : "logs audit"

    deletion_group {
        varchar group_code PK "รหัสกลุ่มตาราง เช่น ORDERS, INVOICES"
        varchar key_type "ประเภท Key ที่รองรับ เช่น ORDER_NO, CUSTOMER_ID"
        text description "คำอธิบายกลุ่มงาน"
        int chunk_size "จำนวน key ต่อ chunk (default 500)"
        numeric throttle_sec "เวลาหน่วงระหว่าง chunk (default 0.05)"
        boolean is_active "เปิด/ปิดกลุ่มงาน"
        timestamptz created_at "วันที่สร้าง"
    }

    deletion_rule {
        serial id PK "Auto-increment ID"
        varchar group_code FK "อ้างอิง deletion_group"
        varchar target_table "ชื่อตารางเป้าหมายที่ต้องลบ"
        int execution_order "ลำดับการลบ (1=ลูกสุด N=Parent)"
        text where_clause_template "WHERE clause ใช้ร่วมกันทั้ง COUNT และ DELETE"
    }

    staging_deletion_item {
        bigserial id PK "Auto-increment ID"
        varchar batch_id "รหัส Batch เช่น BATCH-2025"
        varchar key_type "ประเภท Key จากไฟล์ เช่น ORDER_NO, CUSTOMER_ID"
        varchar key_no "ค่าของ Key"
        timestamptz created_at "เวลานำเข้า"
    }

    staging_deletion_task {
        bigserial id PK "Auto-increment ID"
        varchar batch_id "รหัส Batch"
        bigint item_id FK "อ้างอิง staging_deletion_item.id (CASCADE)"
        varchar group_code FK "อ้างอิง deletion_group.group_code (CASCADE)"
        varchar key_no "ค่าของ Key (Denormalized เพื่อ Index และ Chunking เร็ว)"
        varchar status "สถานะ: PENDING, NOT_FOUND, VALIDATED, COMPLETED, FAILED"
        text error_message "ข้อผิดพลาด (ถ้ามี)"
        timestamptz processed_at "เวลาประมวลผลเสร็จ"
        timestamptz created_at "เวลาสร้าง Task"
    }

    deletion_dry_run_summary {
        bigserial id PK "Auto-increment ID"
        varchar batch_id "รหัส Batch"
        varchar group_code "รหัสกลุ่ม"
        varchar target_table "ตารางเป้าหมาย"
        int execution_order "ลำดับ"
        bigint estimated_rows_to_delete "จำนวนแถวที่คาดว่าจะลบ"
        timestamptz executed_at "เวลาที่จำลอง"
    }

    deletion_audit_log {
        bigserial id PK "Auto-increment ID"
        varchar batch_id "รหัส Batch"
        varchar group_code "รหัสกลุ่ม"
        varchar target_table "ตารางเป้าหมาย"
        bigint deleted_row_count "จำนวนแถวที่ลบจริง"
        timestamptz executed_at "เวลาที่ลบ"
    }
```

---

## 4. Task State Machine (`staging_deletion_task`)

การติดตามสถานะถูกบริหารจัดการในระดับ `staging_deletion_task` เพื่อให้แยกความคืบหน้ารายกลุ่มตารางได้อย่างอิสระ:

```mermaid
stateDiagram-v2
    [*] --> PENDING: Task Expansion จาก staging_deletion_item

    PENDING --> NOT_FOUND: ตรวจไม่พบ Key ใน Target Table ของกลุ่ม
    PENDING --> VALIDATED: ตรวจพบ Key ใน Target Table ของกลุ่ม

    VALIDATED --> COMPLETED: ลบครบทุกระดับ (Order 1 -> N)
    VALIDATED --> PARTIAL_COMPLETED: ลบเฉพาะบางระดับ (Granular Mode)
    VALIDATED --> FAILED: เกิด Error ขณะประมวลผล Chunk

    NOT_FOUND --> [*]: ข้ามการลบจริง
    COMPLETED --> [*]: ลบสำเร็จสมบูรณ์
    PARTIAL_COMPLETED --> [*]: ลบสำเร็จระดับล่าง
    FAILED --> [*]: หยุดรอ DBA เข้าตรวจสอบ

    note right of PENDING
        สร้างขึ้นเมื่อรัน Dry Run
        ตามคู่ key_type = group_code
    end note

    note right of VALIDATED
        พร้อมส่งต่อไปรันใน Phase 2
        (Real Deletion)
    end note

    note right of COMPLETED
        บันทึก Audit Log ราย Chunk ครบ
        และประทับเวลา processed_at
    end note
```

---

## 5. Database Schema Reference

### 5.1 `deletion_group` — กลุ่มงานลบชุดตาราง

| Column | Type | Nullable | Default | Description |
|---|---|---|---|---|
| `group_code` | `VARCHAR(50)` | NOT NULL | — | **PK.** รหัสกลุ่มตาราง เช่น `ORDERS`, `INVOICES` |
| `key_type` | `VARCHAR(50)` | NOT NULL | — | **ประเภท Key ที่กลุ่มนี้รับ** เช่น `ORDER_NO`, `CUSTOMER_ID` |
| `description` | `TEXT` | NULL | — | คำอธิบายกลุ่มงาน |
| `chunk_size` | `INT` | NOT NULL | `500` | จำนวน key ต่อ 1 chunk (1 transaction) |
| `throttle_sec` | `NUMERIC(4,2)` | NOT NULL | `0.05` | เวลาหน่วง (วินาที) ระหว่าง chunk |
| `is_active` | `BOOLEAN` | NOT NULL | `TRUE` | เปิด/ปิดการใช้งานกลุ่มนี้ |
| `created_at` | `TIMESTAMPTZ` | NOT NULL | `CURRENT_TIMESTAMP` | เวลาสร้าง |

**Index:** `idx_deletion_group_key_type ON (key_type, is_active)` — สำหรับ Task Expansion

---

### 5.2 `deletion_rule` — กฎการลบ Bottom-Up (Unified WHERE Clause)

| Column | Type | Nullable | Default | Description |
|---|---|---|---|---|
| `id` | `SERIAL` | NOT NULL | Auto | **PK.** Auto-increment |
| `group_code` | `VARCHAR(50)` | NOT NULL | — | **FK** → `deletion_group.group_code` |
| `target_table` | `VARCHAR(100)` | NOT NULL | — | ชื่อตารางเป้าหมายที่จะลบ |
| `execution_order` | `INT` | NOT NULL | — | ลำดับ Bottom-Up: **1 = ลูกสุด, N = Parent** |
| `where_clause_template` | `TEXT` | NOT NULL | — | WHERE clause ที่ `$1` = Array ของ Parent Key |

> **Unique Constraint:** `(group_code, execution_order)`  
> **หลักการ Unified WHERE:** ใช้ WHERE clause เดียวกันทั้ง COUNT (Dry Run) และ DELETE (Real Delete) เพื่อรับประกันความถูกต้อง 100%

---

### 5.3 `staging_deletion_item` — รายการ Master Key จากไฟล์

| Column | Type | Nullable | Default | Description |
|---|---|---|---|---|
| `id` | `BIGSERIAL` | NOT NULL | Auto | **PK** |
| `batch_id` | `VARCHAR(50)` | NOT NULL | — | รหัส Batch เช่น `BATCH-2025` |
| `key_type` | `VARCHAR(50)` | NOT NULL | — | ประเภท Key เช่น `ORDER_NO`, `CUSTOMER_ID` |
| `key_no` | `VARCHAR(100)` | NOT NULL | — | ค่าของ Key จากไฟล์ |
| `created_at` | `TIMESTAMPTZ` | NOT NULL | `CURRENT_TIMESTAMP` | เวลานำเข้า |

**Constraint:** `UNIQUE (batch_id, key_type, key_no)` — ป้องกันการนำเข้า Key ซ้ำใน Batch เดียวกัน  
**Index:** `idx_staging_item_lookup ON (batch_id, key_type)`

---

### 5.4 `staging_deletion_task` — คิวงานย่อยรายกลุ่มตาราง (Execution Tasks)

| Column | Type | Nullable | Default | Description |
|---|---|---|---|---|
| `id` | `BIGSERIAL` | NOT NULL | Auto | **PK** |
| `batch_id` | `VARCHAR(50)` | NOT NULL | — | รหัส Batch |
| `item_id` | `BIGINT` | NOT NULL | — | **FK** → `staging_deletion_item.id` (`ON DELETE CASCADE`) |
| `group_code` | `VARCHAR(50)` | NOT NULL | — | **FK** → `deletion_group.group_code` (`ON DELETE CASCADE`) |
| `key_no` | `VARCHAR(100)` | NOT NULL | — | ค่าของ Key (Denormalized สำหรับ Query เร็ว) |
| `status` | `VARCHAR(30)` | NOT NULL | `'PENDING'` | สถานะ: `PENDING`, `NOT_FOUND`, `VALIDATED`, `COMPLETED`, `FAILED` |
| `error_message` | `TEXT` | NULL | — | ข้อผิดพลาดกรณี `FAILED` |
| `processed_at` | `TIMESTAMPTZ` | NULL | — | เวลาที่ประมวลผลเสร็จ |
| `created_at` | `TIMESTAMPTZ` | NOT NULL | `CURRENT_TIMESTAMP` | เวลาสร้าง Task |

**Constraint:** `UNIQUE (batch_id, group_code, key_no)`  
**Indexes:**
- `idx_staging_task_fetch ON (group_code, batch_id, status, id)` — ดึง Chunk ด้วย `FOR UPDATE SKIP LOCKED`
- `idx_staging_task_lookup ON (batch_id, group_code, key_no)` — อัปเดตสถานะราย Chunk ทันที

---

### 5.5 `deletion_dry_run_summary` — สรุปผล Dry Run

| Column | Type | Description |
|---|---|---|
| `id` | `BIGSERIAL` | **PK** |
| `batch_id` | `VARCHAR(50)` | รหัส Batch |
| `group_code` | `VARCHAR(50)` | รหัสกลุ่มตาราง |
| `target_table` | `VARCHAR(100)` | ตารางเป้าหมาย |
| `execution_order` | `INT` | ลำดับการลบ |
| `estimated_rows_to_delete` | `BIGINT` | จำนวนแถวที่คาดว่าจะถูกลบ |
| `executed_at` | `TIMESTAMPTZ` | เวลาที่จำลอง |

---

### 5.6 `deletion_audit_log` — บันทึกผลการลบจริง

| Column | Type | Description |
|---|---|---|
| `id` | `BIGSERIAL` | **PK** |
| `batch_id` | `VARCHAR(50)` | รหัส Batch |
| `group_code` | `VARCHAR(50)` | รหัสกลุ่มตาราง |
| `target_table` | `VARCHAR(100)` | ตารางที่ถูกลบจริง |
| `deleted_row_count` | `BIGINT` | จำนวนแถวที่ลบจริงใน Chunk นี้ |
| `executed_at` | `TIMESTAMPTZ` | เวลาที่ลบสำเร็จ |

---

## 6. Stored Procedures Reference

### 6.1 `run_data_deletion_dry_run` (Phase 1)

**วัตถุประสงค์:** ทำ Task Expansion (1:N), ตรวจสอบความถูกต้องกับตารางเป้าหมายของกลุ่มโดยตรง (Root Target Table สูงสุดจาก `deletion_rule`) และนับจำนวนแถวที่จะถูกลบจริงตามกฎ Bottom-Up

```sql
CALL run_data_deletion_dry_run(
    p_batch_id       VARCHAR,              -- รหัส Batch (เช่น 'BATCH-2025')
    p_key_type       VARCHAR DEFAULT NULL,  -- NULL = รันทุก Key Type ใน Batch
    p_group_code     VARCHAR DEFAULT NULL   -- NULL = รันทุกกลุ่มตารางที่เกี่ยวข้อง
);
```

**ตัวอย่างการเรียกใช้งาน:**
```sql
-- รันจำลองทุก Key Type และทุกกลุ่มตารางในคำสั่งเดียว (แนะนำ):
CALL run_data_deletion_dry_run('BATCH-2025');

-- รันเฉพาะ Key Type ที่ต้องการ:
CALL run_data_deletion_dry_run('BATCH-2025', 'ORDER_NO');

-- รันเฉพาะกลุ่มตารางเจาะจง:
CALL run_data_deletion_dry_run('BATCH-2025', NULL, 'ORDERS');
```

---

### 6.2 `run_data_deletion` (Phase 2)

**วัตถุประสงค์:** ลบข้อมูลจริงแบบ Micro-Transaction ทีละ Chunk ตามลำดับ Bottom-Up จากตาราง `staging_deletion_task`

```sql
CALL run_data_deletion(
    p_batch_id     VARCHAR,              -- รหัส Batch
    p_group_code   VARCHAR DEFAULT NULL,  -- NULL = ลบทุกกลุ่มตารางใน Batch นี้อัตโนมัติ
    p_up_to_order  INT     DEFAULT NULL   -- ลบถึงระดับใด (NULL = ทุกระดับ)
);
```

**ตัวอย่างการเรียกใช้งาน:**
```sql
-- สั่งลบทุกกลุ่มตารางในคำสั่งเดียว (แนะนำ):
CALL run_data_deletion('BATCH-2025');

-- สั่งลบเฉพาะกลุ่มตาราง ORDERS:
CALL run_data_deletion('BATCH-2025', 'ORDERS');

-- สั่งลบเฉพาะระดับล่าง (Granular Mode):
CALL run_data_deletion('BATCH-2025', 'ORDERS', 1); -- ลบเฉพาะ Grandchild (order_item_logs)
CALL run_data_deletion('BATCH-2025', 'ORDERS', 2); -- ลบถึง Child (order_items)
```

---

## 7. Python Ingestion CLI (`ingest.py`)

รองรับทั้งไฟล์ Excel (`.xlsx`) และ CSV (`.csv`) พร้อมระบบตรวจจับคอลัมน์อัจฉริยะ:

```bash
# 1. ไฟล์ที่มีคอลัมน์ key_type และ key_no อยู่แล้ว (Auto-detect):
python scripts/ingest.py --file bulk_keys.xlsx --batch BATCH-2025

# 2. ไฟล์ที่มีคอลัมน์เดียว (ระบุ key_type ผ่าน CLI):
python scripts/ingest.py --file orders_2024.csv --batch BATCH-2025 --key-type ORDER_NO

# 3. ระบุ Custom Database Connection URL:
python scripts/ingest.py --file bulk_keys.xlsx --batch BATCH-2025 --db-url postgresql://user:pass@host:5432/db
```

---

## 8. Verification & Reporting Architecture (Target Table Level)

ระบบได้แยกชุดคำสั่ง SQL สำหรับ Generate Report และ Verify ผลลัพธ์ออกเป็น 2 สคริปต์หลัก โดยแสดงผลลัพธ์ในระดับ **Target Table Level** โดยตรง เพื่อให้สอดคล้องกับโครงสร้างฐานข้อมูลจริงและการตรวจสอบของ Auditor:

### 8.1 Phase 1 Verification: `sql/05_report_verify_dry_run.sql`
ใช้ตรวจสอบความถูกต้องหลังรัน Analytical Dry Run เพื่อนำเสนอ Business Approver:
1. **Report 1: Ingestion & Target Table Mapping Verification** — ตรวจสอบจำนวน Master Keys และการกระจาย Tasks รายตารางเป้าหมาย
2. **Report 2: Task Validation Summary & Match Rate** — สรุปอัตรา Match Rate (%) และสัดส่วน VALIDATED vs NOT_FOUND รายตาราง
3. **Report 3: Exception List: Missing Keys (`NOT_FOUND`)** — ดึงรายชื่อคีย์ที่ไม่พบบนตารางหลัก (`root_target_table`) เพื่อส่งคืนฝ่ายธุรกิจ
4. **Report 4: Bottom-Up Estimated Rows to Delete** — ยอดแถวจำลองที่จะถูกลบรายตารางตามลำดับ Bottom-Up
5. **Report 5: Formal Executive Sign-off Summary** — รายงานสรุปภาพรวมรายตารางเป้าหมายสำหรับแนบเอกสารขออนุมัติ

### 8.2 Phase 2 Verification: `sql/06_report_verify_real_deletion.sql`
ใช้ตรวจสอบความสมบูรณ์หลังรัน Real Deletion เพื่อยืนยัน Zero-Defect และส่งต่อ Compliance Audit:
1. **Report 1: Task Execution Progress & Completion Audit** — ตรวจสอบว่า Tasks รายตารางเป็น COMPLETED หรือ NOT_FOUND ครบ 100%
2. **Report 2: 100% Reconciliation & Variance Report** — เปรียบเทียบ Dry Run Estimated vs Actual Deleted รายตาราง (`Variance = 0`)
3. **Report 3: Zero-Leakage Residual Sanity Check** — ยืนยันว่าไม่มีคีย์ที่สั่งลบหลงเหลืออยู่ในตารางหลักแม้แต่เรคคอร์ดเดียว
4. **Report 4: Deletion Throughput & Performance Summary** — สถิติ Chunks, เวลาที่ใช้ และอัตราความเร็ว (Rows/Sec) รายตาราง
5. **Report 5: Compliance Certificate of Destruction / Audit Trail** — ใบรับรองหลักฐานการทำลายข้อมูลรายตารางเป้าหมายตามข้อกำหนด PDPA

