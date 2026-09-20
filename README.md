# 🛡️ Enterprise Data Lifecycle Management: Deletion & Masking System
### Secure Data Purging & PII Obfuscation Framework for PostgreSQL 16+

ระบบบริหารจัดการวงจรชีวิตข้อมูลระดับองค์กร (Data Lifecycle Management) บน PostgreSQL 16+ รองรับ 2 ภารกิจหลักตามกฎหมายคุ้มครองข้อมูลส่วนบุคคล (PDPA / GDPR):
1. **🗑️ Data Deletion Subsystem**: การลบทำลายข้อมูลประจำปีแบบ Bottom-Up ป้องกัน Foreign Key Violation พร้อม Micro-Transactions
2. **🎭 Data Masking Subsystem**: การแปลงข้อมูลส่วนบุคคล (PII Obfuscation) เฉพาะ Key ที่ระบุในไฟล์ Excel โดยกำหนดตรรกะการแปลงผ่านตารางคอนฟิก พร้อมระบบ Before/After Sample Preview

---

## 🧭 Subsystems Navigation (เข้าสู่ระบบย่อย)

```
data-lifecycle/ (root)
├── docs/
│   ├── deletion/                     # 📖 คู่มือและสเปกของระบบ Data Deletion
│   │   ├── README.md                 # Deletion Quickstart & Index
│   │   ├── TECHNICAL_SPEC.md         # Full Technical Specification (Deletion)
│   │   ├── OPERATIONAL_MANUAL.md     # SOP ขั้นตอนปฏิบัติงานรายปี (Deletion)
│   │   ├── CONFIG_USE_CASES_GUIDE.md # คู่มือคอนฟิก 6 Use Cases (Deletion)
│   │   └── PERFORMANCE_REPORT_1M_100K.md # Benchmark 1M Records / 100K Keys
│   └── masking/                      # 📖 คู่มือและสเปกของระบบ Data Masking
│       ├── README.md                 # Masking Quickstart & Index
│       ├── TECHNICAL_SPEC.md         # Full Technical Specification (Masking)
│       ├── OPERATIONAL_MANUAL.md     # SOP & DPO Review Runbook (Masking)
│       └── CONFIG_GUIDE.md           # คู่มือการเขียน mask_expression ในตารางคอนฟิก
│
├── sql/
│   ├── deletion/                     # 🐘 Production SQL Scripts สำหรับ Deletion
│   │   ├── 01_core_schema.sql        # Schema Framework (Groups, Rules, Staging, Audit)
│   │   ├── 02_dry_run.sql            # Procedure: run_data_deletion_dry_run
│   │   ├── 03_real_deletion.sql      # Procedure: run_data_deletion
│   │   ├── 04_preflight_checks.sql   # FK Index & Cascade Safety Checks
│   │   ├── 05_report_verify_dry_run.sql # Verification reports (Dry Run)
│   │   ├── 06_report_verify_real_deletion.sql # Audit reports (Real Deletion)
│   │   └── 07_example_configurations.sql # ตัวอย่าง Configuration 6 Use Cases
│   └── masking/                      # 🐘 Production SQL Scripts สำหรับ Masking
│       ├── 01_masking_schema.sql     # Schema Framework (Groups, Rules, Staging, Audit)
│       ├── 02_masking_functions.sql  # คลังฟังก์ชัน Masking (Email, Phone, ID, Hash)
│       ├── 03_masking_dry_run.sql    # Procedure: run_data_masking_dry_run (Sample Preview)
│       ├── 04_masking_real.sql       # Procedure: run_data_masking (Chunked UPDATE)
│       ├── 05_preflight_checks.sql   # Unique Index & Column Length Checks
│       ├── 06_report_verify_dry_run.sql # Verification reports (Sample Previews)
│       ├── 07_report_verify_real_masking.sql # Audit reports (Real Masking)
│       └── 08_example_configurations.sql # ตัวอย่างการตั้งค่า Masking Rules
│
└── scripts/
    ├── deletion/                     # 🐍 Python Tools สำหรับ Deletion
    │   ├── ingest.py                 # Ingest Excel/CSV เข้าสู่ staging_deletion_item
    │   ├── test_pipeline.py          # E2E Regression Test Pipeline (Deletion)
    │   ├── test_multi_group.py       # Multi-Group Task Expansion Test
    │   └── perf_test_1m_100k.py      # Benchmark Suite 1M แถว
    └── masking/                      # 🐍 Python Tools สำหรับ Masking
        ├── ingest.py                 # Ingest Excel/CSV เข้าสู่ staging_masking_item
        └── test_masking_pipeline.py  # E2E Automated Test Pipeline (Masking)
```

---

## ⚖️ Architectural Comparison: Deletion vs. Masking

| มิติการเปรียบเทียบ | 🗑️ Data Deletion System | 🎭 Data Masking System |
|---|---|---|
| **คำสั่ง SQL หลัก** | `DELETE FROM table WHERE ...` (Row-level removal) | `UPDATE table SET col = expr WHERE ...` (Column-level transformation) |
| **ผลลัพธ์ต่อข้อมูล** | แถวข้อมูลถูกลบถาวร (Hard Delete) | แถวข้อมูลยังคงอยู่ แต่ค่า PII ถูกบดบังถาวร (Zero Deletions) |
| **การควบคุมขอบเขต** | ตาม Master Keys ในไฟล์ Excel/CSV | **เฉพาะระเบียนที่ตรงกับ Key ใน Excel/CSV เท่านั้น** (Key-Driven) |
| **ตรรกะการแปลงข้อมูล** | ไม่มีการแปลง (ลบทั้งแถว) | **กำหนดผ่านตารางคอนฟิก (`masking_rule.mask_expression`)** |
| **ลำดับการประมวลผล** | **Bottom-Up** (ตารางลูกสุด $\rightarrow$ แม่) ป้องกัน FK Violation | **Composite Multi-Column** (รวมทุกคอลัมน์ของตารางใน 1 UPDATE) |
| **จุดเด่นของ Dry Run** | คำนวณยอดแถวที่คาดว่าจะถูกลบ | **สร้าง Before / After Sample Preview (JSONB) ให้ DPO ตรวจสอบ** |
| **การทำ Micro-Transaction** | `FOR UPDATE SKIP LOCKED LIMIT chunk_size` + COMMIT | `FOR UPDATE SKIP LOCKED LIMIT chunk_size` + COMMIT |
| **Audit Trail** | `deletion_audit_log` | `masking_audit_log` |

---

## ⚡ Quick Operational Cheat Sheet

### 1. 🗑️ Data Deletion Workflow
```bash
# 1. Ingest Master Keys จากไฟล์ Excel/CSV
python scripts/deletion/ingest.py --file mock_data/sample_keys.csv --batch DEL-2025 --key-type ORDER_NO
```
```sql
-- 2. Analytical Dry Run (จำลองการลบ)
CALL run_data_deletion_dry_run('DEL-2025');
SELECT * FROM deletion_dry_run_summary WHERE batch_id = 'DEL-2025';

-- 3. Real Deletion (ลบจริงแบบ Chunked)
CALL run_data_deletion('DEL-2025');
SELECT target_table, SUM(deleted_row_count) FROM deletion_audit_log WHERE batch_id = 'DEL-2025' GROUP BY target_table;
```

---

### 2. 🎭 Data Masking Workflow
```bash
# 1. Ingest Masking Keys จากไฟล์ Excel/CSV (เฉพาะ Key ที่ต้องการแปลงข้อมูล)
python scripts/masking/ingest.py --file mock_data/pdpa_keys.xlsx --batch MASK-2026 --key-type CUSTOMER_ID
```
```sql
-- 2. Analytical Dry Run (จำลองพร้อมสร้าง Before/After Preview)
CALL run_data_masking_dry_run('MASK-2026');

-- 3. DPO ตรวจสอบตัวอย่างก่อน/หลังการแปลงข้อมูล
SELECT target_table, column_name, mask_expression, sample_preview 
FROM masking_dry_run_summary WHERE batch_id = 'MASK-2026';

-- 4. Real Masking (แปลงข้อมูลจริงทีละ Chunk ตามตรรกะในตารางคอนฟิก)
CALL run_data_masking('MASK-2026');
SELECT target_table, columns_masked, SUM(masked_row_count) FROM masking_audit_log WHERE batch_id = 'MASK-2026' GROUP BY target_table, columns_masked;
```

---

## 🧪 Automated Testing & Verification

รันชุดทดสอบอัตโนมัติ End-to-End ครบวงจรสำหรับทั้งสองระบบ:

```bash
# ทดสอบระบบ Data Deletion
python scripts/deletion/test_pipeline.py

# ทดสอบระบบ Data Masking
python scripts/masking/test_masking_pipeline.py

# ทดสอบ Backward-Compatibility Shims ที่ Root
python scripts/test_pipeline.py
```

---

## 📖 Detailed Documentation

- **Data Deletion Subsystem**: [docs/deletion/README.md](docs/deletion/README.md)
- **Data Masking Subsystem**: [docs/masking/README.md](docs/masking/README.md)
