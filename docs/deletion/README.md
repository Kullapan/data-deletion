# 🗑️ Yearly Data Deletion System (Subsystem Documentation)

เอกสารและการใช้งานระบบ **Yearly Data Deletion** สำหรับ PostgreSQL 16+ 

---

## 📚 Document Index (สารบัญเอกสารการลบข้อมูล)

| Document | Description |
|---|---|
| **[TECHNICAL_SPEC.md](TECHNICAL_SPEC.md)** | **Full Technical Specification** — สถาปัตยกรรมระบบ 2-Tier Item & Task, ER Diagrams, State Machine, Bottom-up FK Rules, และ Stored Procedure Design |
| **[OPERATIONAL_MANUAL.md](OPERATIONAL_MANUAL.md)** | **Operational Manual (SOP)** — ขั้นตอนปฏิบัติงานรายปีของ Ops & DBA, Pre-flight Checklist, Monitoring Queries และ Disaster Recovery |
| **[CONFIG_USE_CASES_GUIDE.md](CONFIG_USE_CASES_GUIDE.md)** | **Configuration Guide** — แนวทางการคอนฟิกตาราง `deletion_group` และ `deletion_rule` สำหรับ 6 Enterprise Use Cases |
| **[PERFORMANCE_REPORT_1M_100K.md](PERFORMANCE_REPORT_1M_100K.md)** | **Performance Benchmark Report** — รายงานผลทดสอบสเกล 1,000,000 แถว กับ 100,000 Excel Keys พร้อมตัวเลข Throughput |

---

## 📁 File Structure (Data Deletion)

```
data-deletion/
├── docs/deletion/                      # เอกสารระบบ Deletion
│   ├── README.md                       # หน้านี้
│   ├── TECHNICAL_SPEC.md               # สเปกเทคนิคระบบ Deletion
│   ├── OPERATIONAL_MANUAL.md           # SOP คู่มือปฏิบัติงาน
│   ├── CONFIG_USE_CASES_GUIDE.md       # คู่มือการคอนฟิก Use Cases
│   └── PERFORMANCE_REPORT_1M_100K.md   # รายงานผล Performance
│
├── sql/deletion/                       # SQL Scripts ประจำระบบ Deletion
│   ├── 01_core_schema.sql              # Schema Framework (Groups, Rules, Staging, Audit)
│   ├── 02_dry_run.sql                  # Stored Procedure: run_data_deletion_dry_run
│   ├── 03_real_deletion.sql            # Stored Procedure: run_data_deletion
│   ├── 04_preflight_checks.sql         # Safety queries (Missing FK index, CASCADE)
│   ├── 05_report_verify_dry_run.sql    # Analytical verification reports (Dry Run)
│   ├── 06_report_verify_real_deletion.sql # Verification reports (Real Deletion)
│   └── 07_example_configurations.sql   # ข้อมูลตัวอย่าง Config 6 Use cases
│
└── scripts/deletion/                   # เครื่องมือ Python ประจำระบบ Deletion
    ├── ingest.py                       # CLI นำเข้า Excel/CSV เข้าสู่ staging_deletion_item
    ├── test_pipeline.py                # Automated Regression Test Pipeline
    ├── test_multi_group.py             # ทดสอบ 1:N Multi-Group Task Expansion
    └── perf_test_1m_100k.py            # สคริปต์รัน Benchmark 1M แถว / 100K Keys
```

---

## ⚡ Quick Operational Commands

### 1. Ingest Master Keys (จากไฟล์ Excel/CSV)
```bash
python scripts/deletion/ingest.py --file mock_data/sample_keys.csv --batch BATCH-2025 --key-type ORDER_NO
```

### 2. Analytical Dry Run (จำลองการลบ)
```sql
CALL run_data_deletion_dry_run('BATCH-2025');

-- ตรวจสอบยอดประเมิน
SELECT * FROM deletion_dry_run_summary WHERE batch_id = 'BATCH-2025' ORDER BY group_code, execution_order;
```

### 3. Real Deletion (ลบจริงแบบ Micro-Transaction)
```sql
CALL run_data_deletion('BATCH-2025');

-- ตรวจสอบ Audit Log
SELECT target_table, SUM(deleted_row_count) FROM deletion_audit_log WHERE batch_id = 'BATCH-2025' GROUP BY target_table;
```

### 4. Regression Test
```bash
python scripts/deletion/test_pipeline.py
```
