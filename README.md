# 🗑️ Yearly Data Deletion System

ระบบลบข้อมูลประจำปีบน PostgreSQL อย่างปลอดภัย รองรับ Parent-Child หลายระดับ พร้อม Dry Run, Chunked Transactions และ Audit Trail

---

## 📋 Quick Overview

| Feature | Description |
|---|---|
| **Engine** | Pure PL/pgSQL Stored Procedures (PostgreSQL 16+) |
| **Ingestion** | Python CLI รองรับทั้ง `.xlsx` และ `.csv` |
| **Safety** | 2-Phase (Dry Run → Real Delete), Bottom-Up FK-safe, Micro-Transactions |
| **Granular Control** | เลือกลบเฉพาะบางระดับของ Hierarchy ได้ (เช่น ลบเฉพาะ Grandchild) |
| **Observability** | SQL Logging (`RAISE NOTICE`), Audit Log ราย Chunk |
| **Scale** | หลักแสนรายการ, Chunk 500 keys/transaction, Throttle ระหว่าง Chunk |

---

## 🏗️ Architecture (2-Tier Item & Task Model)

```
[Excel/CSV File (key_type, key_no)]
       │
       ▼
[Python ingest.py] ──► [staging_deletion_item] (Master Keys)
                              │
               ┌──────────────┴──────────────┐
               ▼ Task Expansion (1:N)        ▼
      [staging_deletion_task] (Tasks per Table Group)
               │                             │
               ▼                             ▼
      Phase 1: Dry Run              Phase 2: Real Delete
      (NOT_FOUND / VALIDATED)       (Bottom-Up, chunked COMMIT)
               │                             │
               ▼                             ▼
      [dry_run_summary]             [deletion_audit_log]
      → ส่ง Ops อนุมัติ             → หลักฐาน Audit Trail
```

---

## 📁 Project Structure

```
data-deletion/
├── docker/                          # Docker Environment
│   ├── docker-compose.yml           # PostgreSQL 16 + pgAdmin 4
│   └── init/                        # Auto-run on first start
│       ├── 01_create_framework.sql  # Framework tables
│       ├── 02_create_mock_tables.sql# Mock: orders → items → logs
│       ├── 03_seed_mock_data.sql    # 10K/30K/60K rows + Rules
│       └── 04_create_procedures.sql # Dry Run & Real Delete procedures
│
├── sql/                             # Production SQL Scripts
│   ├── 01_core_schema.sql           # Framework schema (2-Tier architecture)
│   ├── 02_dry_run.sql               # Procedure: run_data_deletion_dry_run
│   ├── 03_real_deletion.sql         # Procedure: run_data_deletion
│   ├── 04_preflight_checks.sql      # Safety checks (FK Index, CASCADE)
│   ├── 05_report_verify_dry_run.sql # Verification reports for Dry Run (Target Table level)
│   ├── 06_report_verify_real_deletion.sql # Verification reports for Real Deletion (Target Table level)
│   └── 07_example_configurations.sql# Enterprise configuration examples for 6 use cases
│
├── docs/                            # Comprehensive Documentation
│   ├── CONFIG_USE_CASES_GUIDE.md    # Guide for configuring groups & rules across use cases
│   ├── OPERATIONAL_MANUAL.md        # SOP, checklists, disaster recovery & verification reports
│   ├── TECHNICAL_SPEC.md            # Technical specification, sequence diagram & architecture
│   └── PERFORMANCE_REPORT_1M_100K.md# Benchmark report (1M records, 100K Excel keys)
│
├── scripts/                         # Python Tools
│   ├── ingest.py                    # CSV/XLSX → staging_deletion_item
│   └── requirements.txt             # pandas, openpyxl, psycopg2-binary
│
├── mock_data/                       # Test Data
│   └── sample_keys.csv              # 2,000 sample keys (ORD-00001 ~ ORD-02000)
│
└── README.md                        # ← You are here
```

---

## 🚀 Quick Start

### 1. Start Docker Environment

```bash
cd docker
docker compose up -d
```

| Service | URL | Credentials |
|---|---|---|
| **PostgreSQL** | `localhost:5432` | `postgres` / `password123` / `deletion_db` |
| **pgAdmin** | http://localhost:5050 | `admin@admin.com` / `admin` |

> Mock data (10K orders, 30K items, 60K logs) และ Stored Procedures จะถูกสร้างให้อัตโนมัติ

### 2. Install Python Dependencies

```bash
pip install -r scripts/requirements.txt
```

### 3. Ingest Keys
 
```bash
# จาก CSV หรือ Excel ที่มีคอลัมน์ key_type และ key_no อยู่แล้ว (Auto-detect)
python scripts/ingest.py --file data.xlsx --batch BATCH-2025

# หรือระบุ --key-type สำหรับไฟล์ที่มีคอลัมน์เดียว
python scripts/ingest.py --file mock_data/sample_keys.csv --batch BATCH-2025 --key-type ORDER_NO
```

### 4. Dry Run (จำลอง ไม่ลบจริง)

```sql
-- [แนะนำ] รันจำลองทุกกลุ่มงานใน Batch นี้ในคำสั่งเดียว (All Groups in One Command):
CALL run_data_deletion_dry_run('BATCH-2025');

-- หรือระบุเฉพาะกลุ่มเจาะจง:
CALL run_data_deletion_dry_run('BATCH-2025', 'ORDERS');

-- ดูผลลัพธ์
SELECT group_code, target_table, execution_order, estimated_rows_to_delete 
FROM deletion_dry_run_summary 
WHERE batch_id = 'BATCH-2025' 
ORDER BY group_code, execution_order;
```

### 5. Real Delete

```sql
-- [แนะนำ] สั่งลบทุกกลุ่มงานใน Batch นี้ในคำสั่งเดียว (All Groups in One Command):
CALL run_data_deletion('BATCH-2025');

-- หรือสั่งลบเฉพาะกลุ่มเจาะจง:
CALL run_data_deletion('BATCH-2025', 'ORDERS');

-- หรือสั่งลบเฉพาะบางระดับ (Granular Mode):
CALL run_data_deletion('BATCH-2025', 'ORDERS', 1);  -- เฉพาะ Grandchild
CALL run_data_deletion('BATCH-2025', 'ORDERS', 2);  -- ถึง Child
```

### 6. Post-Maintenance

```sql
VACUUM ANALYZE orders;
VACUUM ANALYZE order_items;
VACUUM ANALYZE order_item_logs;
```

---

## 🔧 Configuration Guide

### Step 1: Create Deletion Group

```sql
INSERT INTO deletion_group (group_code, description, chunk_size, throttle_sec)
VALUES ('MY_GROUP', 'Description here', 500, 0.05);
```

| Parameter | Recommended | When |
|---|---|---|
| `chunk_size` = 200–500 | ข้อมูลหลักหมื่น | สมดุล Speed/Load |
| `chunk_size` = 500–1000 | ข้อมูลหลักแสน | เพิ่ม Throughput |
| `throttle_sec` = 0.05 | มี Read Replica | ให้ Replica ตามทัน |
| `throttle_sec` = 0 | ไม่มี Replica | ลบเร็วสุด |

### Step 2: Define Deletion Rules (Bottom-Up)

`$1` ใน template = Array ของ Parent Key จาก Staging

```sql
-- ตัวอย่าง: 3-level hierarchy
INSERT INTO deletion_rule (group_code, target_table, execution_order, where_clause_template)
VALUES
  ('ORDERS', 'order_item_logs', 1, 'WHERE item_id IN (SELECT id FROM order_items WHERE order_no = ANY($1))'),
  ('ORDERS', 'order_items',     2, 'WHERE order_no = ANY($1)'),
  ('ORDERS', 'orders',          3, 'WHERE order_no = ANY($1)');
```

> ⚠️ `execution_order` ต้องเรียงจาก **ลูกสุด (1) ไปหา Parent (N)** เสมอ

---

## 📊 Status Flow

```
PENDING ──► NOT_FOUND          (Key ไม่พบในตาราง Parent)
   │
   └──► VALIDATED ──► COMPLETED           (ลบสำเร็จครบทุกระดับ)
                  ──► PARTIAL_COMPLETED    (ลบสำเร็จบางระดับ / Granular)
                  ──► FAILED              (เกิด Error → Stop the World)
```

---

## 🛡️ Safety Features

| Feature | How |
|---|---|
| **Bottom-Up Delete** | ลบ Grandchild → Child → Parent ตามลำดับ ป้องกัน FK Violation |
| **Micro-Transaction** | 1 Chunk = 1 COMMIT ถ้า Chunk พัง Rollback เฉพาะ Chunk นั้น |
| **Stop the World** | เจอ Error → หยุดทันที → DBA/Ops เข้ามาดูก่อน |
| **Resumable** | สั่ง `CALL run_data_deletion(...)` ซ้ำ ระบบทำต่อจาก VALIDATED ที่เหลือ |
| **Unified Template** | COUNT และ DELETE ใช้ WHERE clause เดียวกัน → ไม่มีทางได้ผลต่างกัน |
| **SQL Logging** | พิมพ์ SQL จริงทุก Chunk ผ่าน `RAISE NOTICE` |
| **No Temp Table** | ใช้ PL/pgSQL Array ตัวแปร ไม่สร้าง Temp Table ป้องกัน Catalog Bloat |

---

## 📖 Documentation & Guides

| Document | Description |
|---|---|
| **[docs/TECHNICAL_SPEC.md](docs/TECHNICAL_SPEC.md)** | **Full Technical Specification** — สถาปัตยกรรมระบบ, ER Diagrams (Mermaid), State Machine, Schema Reference ละเอียดทุกตาราง |
| **[docs/OPERATIONAL_MANUAL.md](docs/OPERATIONAL_MANUAL.md)** | **Operational Manual (SOP)** — ขั้นตอนปฏิบัติงานรายปี, Pre-flight Checks, การ Monitor ผ่าน SQL, และ Disaster Recovery |
| **[scripts/test_pipeline.py](scripts/test_pipeline.py)** | **Automated Test Pipeline** — รันการทดสอบ Regression End-to-End ครบวงจรแบบคำสั่งเดียว |
| **[sql/01_core_schema.sql](sql/01_core_schema.sql)** | Production schema — `CREATE TABLE IF NOT EXISTS` สำหรับ deploy จริง |
| **[sql/02_dry_run.sql](sql/02_dry_run.sql)** | Source code: `run_data_deletion_dry_run` procedure |
| **[sql/03_real_deletion.sql](sql/03_real_deletion.sql)** | Source code: `run_data_deletion` procedure |
| **[sql/04_preflight_checks.sql](sql/04_preflight_checks.sql)** | Pre-flight queries: ตรวจ Missing FK Index, CASCADE constraints |
| **[scripts/ingest.py](scripts/ingest.py)** | Python CLI สำหรับ Ingest Excel/CSV |
| **[docker/docker-compose.yml](docker/docker-compose.yml)** | Docker environment สำหรับทดสอบ (PostgreSQL 16 + pgAdmin 4) |

---

## ⚡ Command Cheat Sheet

```bash
# Docker
cd docker && docker compose up -d          # Start
cd docker && docker compose down           # Stop
cd docker && docker compose down -v        # Stop + Delete data

# Ingest
python scripts/ingest.py --file <file> --batch <BATCH-ID> --group <GROUP>

# SQL (via Docker)
docker exec deletion_postgres psql -U postgres -d deletion_db -c "<SQL>"
```

```sql
-- Dry Run (All Groups in One Command)
CALL run_data_deletion_dry_run('BATCH-YYYY');
-- Dry Run (Specific Group)
CALL run_data_deletion_dry_run('BATCH-YYYY', 'GROUP_CODE');

-- Real Delete (All Groups in One Command)
CALL run_data_deletion('BATCH-YYYY');
-- Real Delete (Specific Group)
CALL run_data_deletion('BATCH-YYYY', 'GROUP_CODE');
-- Real Delete (Granular)
CALL run_data_deletion('BATCH-YYYY', 'GROUP_CODE', 1);   -- Grandchild only
CALL run_data_deletion('BATCH-YYYY', 'GROUP_CODE', 2);   -- up to Child

-- Check Results
SELECT * FROM deletion_dry_run_summary WHERE batch_id = 'BATCH-YYYY';
SELECT status, COUNT(*) FROM staging_deletion_item WHERE batch_id = 'BATCH-YYYY' GROUP BY status;
SELECT target_table, SUM(deleted_row_count) FROM deletion_audit_log WHERE batch_id = 'BATCH-YYYY' GROUP BY target_table;

-- Post-Maintenance
VACUUM ANALYZE <table_name>;
```
