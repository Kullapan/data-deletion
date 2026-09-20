# 🎭 Key-Driven Data Masking System (PostgreSQL 16+)

ระบบแปลงข้อมูลอ่อนไหว (PII Anonymization & Data Masking) ตามกฎหมายคุ้มครองข้อมูลส่วนบุคคล (PDPA / GDPR) บน PostgreSQL 16+ ขับเคลื่อนด้วยสถาปัตยกรรม **Key-Driven 2-Tier** และการตั้งค่าตรรกะการแปลงข้อมูลผ่านตารางคอนฟิก (**Config-Table Driven Logic**)

---

## 📋 ภาพรวมระบบ (System Overview)

| คุณสมบัติ | คำอธิบาย |
|---|---|
| **ขอบเขตการทำงาน** | **Key-Driven Strict Scope**: แปลงเฉพาะระเบียนที่มี Key ตรงกับไฟล์ Excel / CSV เท่านั้น ระเบียนอื่นจะไม่ถูกแตะต้อง |
| **ความยืดหยุ่นของตรรกะ** | **Config-Driven Logic**: กำหนด Expression / ฟังก์ชัน หรือสูตร SQL ประจำแต่ละคอลัมน์ได้อิสระในตาราง `masking_rule` |
| **ความปลอดภัย 2-Phase** | Phase 1 (Analytical Dry Run + Before/After Sample Preview) $\rightarrow$ Phase 2 (Chunked Real Masking) |
| **การประมวลผล** | Micro-Transactions (`FOR UPDATE SKIP LOCKED LIMIT chunk_size`) พร้อม `COMMIT` และหน่วงเวลา `throttle_sec` |
| **การคงอยู่ของแถว** | ไม่มีการลบแถว (Zero Deletions) คงรูปโครงสร้าง Referential Integrity และ Foreign Key ไว้อย่างสมบูรณ์ |
| **Audit Trail** | บันทึกประวัติการ Masking ราย Chunk ลงในตาราง `masking_audit_log` อย่างละเอียด |

---

## 📚 สารบัญเอกสาร (Documentation Index)

| เอกสาร | รายละเอียด |
|---|---|
| **[TECHNICAL_SPEC.md](TECHNICAL_SPEC.md)** | **Full Technical Specification** — สถาปัตยกรรมระบบ, Mermaid Sequence & ER Diagrams, State Machine, มาตรฐานความปลอดภัย |
| **[OPERATIONAL_MANUAL.md](OPERATIONAL_MANUAL.md)** | **Operational SOP** — ขั้นตอนปฏิบัติงานสำหรับ Data Steward, DPO (การตรวจ Before/After Preview), และ DBA Runbook |
| **[CONFIG_GUIDE.md](CONFIG_GUIDE.md)** | **Configuration Guide** — คู่มือการตั้งค่า `masking_group` และการเขียน `mask_expression` ในตาราง `masking_rule` หลากหลายรูปแบบ |

---

## 📁 โครงสร้างโฟลเดอร์ (Masking Subsystem)

```
data-deletion/
├── docs/masking/                       # เอกสารระบบ Masking
│   ├── README.md                       # หน้านี้
│   ├── TECHNICAL_SPEC.md               # สเปกเทคนิคระบบ Masking
│   ├── OPERATIONAL_MANUAL.md           # SOP คู่มือปฏิบัติงาน & ตรวจ Preview
│   └── CONFIG_GUIDE.md                 # คู่มือการคอนฟิกตาราง masking_rule
│
├── sql/masking/                        # SQL Framework ประจำระบบ Masking
│   ├── 01_masking_schema.sql           # Schema ตารางระบบ (Groups, Rules, Staging, Audit)
│   ├── 02_masking_functions.sql        # คลังฟังก์ชันแปลงข้อมูล (Email, Phone, Citizen ID, Name, Salted Hash)
│   ├── 03_masking_dry_run.sql          # Stored Procedure: run_data_masking_dry_run (พร้อม Before/After Sample Preview)
│   ├── 04_masking_real.sql             # Stored Procedure: run_data_masking (Micro-transaction Chunked UPDATE)
│   ├── 05_preflight_checks.sql         # Safety queries (Unique index collision, Column length check)
│   ├── 06_report_verify_dry_run.sql    # Analytical verification reports (ตรวจผล Dry Run & Sample Preview)
│   ├── 07_report_verify_real_masking.sql # Verification reports (ตรวจสอบผลการ Masking และ Audit Log)
│   └── 08_example_configurations.sql   # ตัวอย่างคอนฟิก 3 Use cases ทางธุรกิจ
│
└── scripts/masking/                    # เครื่องมือ Python ประจำระบบ Masking
    ├── ingest.py                       # CLI นำเข้า Excel/CSV เข้าสู่ staging_masking_item
    └── test_masking_pipeline.py        # Automated Regression Test Pipeline
```

---

## 🚀 ลำดับขั้นตอนการปฏิบัติงานด่วน (Quick Start)

### 1. นำเข้า Key ที่ต้องการแปลงข้อมูลจาก Excel / CSV
```bash
python scripts/masking/ingest.py \
  --file mock_data/sample_keys.xlsx \
  --batch MASK-2026-01 \
  --key-type CUSTOMER_ID
```

### 2. รัน Analytical Dry Run (จำลองและสร้าง Before/After Preview)
```sql
CALL run_data_masking_dry_run('MASK-2026-01');
```

**ตรวจสอบตัวอย่างก่อน/หลังการแปลงข้อมูล (สำหรับ DPO อนุมัติ):**
```sql
SELECT 
    target_table, 
    column_name, 
    estimated_rows_to_mask, 
    sample_preview 
FROM masking_dry_run_summary 
WHERE batch_id = 'MASK-2026-01';
```

### 3. รัน Real Masking (แปลงข้อมูลจริงทีละ Chunk)
```sql
CALL run_data_masking('MASK-2026-01');
```

**ตรวจสอบผลลัพธ์ใน Audit Log:**
```sql
SELECT target_table, columns_masked, SUM(masked_row_count), SUM(duration_sec)
FROM masking_audit_log 
WHERE batch_id = 'MASK-2026-01'
GROUP BY target_table, columns_masked;
```

### 4. รัน Automated Test Suite
```bash
python scripts/masking/test_masking_pipeline.py
```
