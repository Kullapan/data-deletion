# Technical Specification: Key-Driven Data Masking System
### Version 1.0 | 2-Tier Item & Column Rule Architecture | PostgreSQL 16 | 2026-09-20

---

## 1. System Overview

ระบบ **Key-Driven Data Masking System** ได้รับการออกแบบขึ้นมาเพื่อทำหน้าที่แปลงข้อมูลอ่อนไหว (Personally Identifiable Information - PII / Sensitive Personal Data) ให้กลายเป็นข้อมูลที่ไม่สามารถระบุตัวบุคคลได้ตามข้อกำหนดทางกฎหมาย PDPA (พ.ร.บ. คุ้มครองข้อมูลส่วนบุคคล) และ GDPR (Right to Erasure / Pseudonymization) โดยยังคงรักษาโครงสร้างของแถวและ Foreign Key ไว้อย่างสมบูรณ์

### จุดเด่นเชิงสถาปัตยกรรม (Core Design Principles):
1. **Strictly Key-Driven Scope (จำกัดเฉพาะ Key ใน Excel/CSV)**:
   - ระบบจะไม่ทำการ Masking ข้อมูลแบบกวาดทั้งตาราง แต่จะประมวลผลเฉพาะระเบียนที่มีความเกี่ยวข้องกับ Key ที่นำเข้ามาจากไฟล์ภายนอกเท่านั้น (เช่น ลูกค้าเฉพาะรายที่ขอยกเลิกความยินยอม หรือลูกค้ารายที่หมดสัญญา)
   - ข้อมูลของลูกค้ารายอื่นๆ ที่ไม่อยู่ในไฟล์ Excel จะไม่ได้รับผลกระทบใดๆ ทั้งสิ้น
2. **Config-Table Driven Masking Logic (ตรรกะถูกควบคุมผ่านตารางคอนฟิก)**:
   - ตรรกะ สูตร หรือฟังก์ชันที่ใช้ในการแปลงข้อมูลแต่ละคอลัมน์ ถูกกำหนดอยู่ในคอลัมน์ `mask_expression` ของตาราง `masking_rule`
   - ผู้ดูแลระบบสามารถเปลี่ยนรูปแบบการ Masking ได้ทันทีผ่านการปรับค่าในตารางคอนฟิก โดยไม่ต้องแก้ไขโค้ด Stored Procedure
3. **2-Phase Safety Model with Before/After Sample Preview**:
   - **Phase 1 (Analytical Dry Run)**: ทำการตรวจสอบความมีอยู่ของ Key (VALIDATED vs NOT_FOUND), ประเมินจำนวนแถวที่จะได้รับผลกระทบ และดึงตัวอย่างข้อมูล **ก่อนแปลง (Before) เทียบกับ หลังแปลง (After)** บันทึกเป็น JSONB ลงใน `masking_dry_run_summary` เพื่อให้เจ้าหน้าที่คุ้มครองข้อมูลส่วนบุคคล (DPO) ตรวจสอบและลงนามอนุมัติ
   - **Phase 2 (Chunked Real Masking)**: ทำการ UPDATE ข้อมูลจริงแบบแบ่ง Chunk (เช่น 500 Keys ต่อ Micro-Transaction) พร้อม `COMMIT` และหน่วงเวลา `pg_sleep` เพื่อคืน I/O ให้กับฐานข้อมูล
4. **Zero-Deletion Referential Integrity**:
   - ไม่มีคำสั่ง `DELETE` ข้อมูลยังคงอยู่ในระบบครบถ้วนทุกตาราง ทำให้ระบบงานที่ต้องเชื่อมโยง Foreign Key หรือระบบรายงานทางสถิติยังคงสามารถทำงานต่อไปได้ตามปกติ

---

## 2. System Architecture

```mermaid
flowchart TB
    subgraph INPUT["📥 External Input"]
        FILE["Excel / CSV File<br/>(Columns: key_type, key_no)"]
    end

    subgraph PYTHON["🐍 Python Ingestion"]
        CLI["scripts/masking/ingest.py<br/>• Read & Validate File<br/>• In-file Deduplication<br/>• Bulk INSERT"]
    end

    subgraph DB["🐘 PostgreSQL 16 Engine"]
        STG_ITEM["📥 staging_masking_item<br/>(Raw Master Keys)"]

        subgraph PHASE1["Phase 1: Analytical Dry Run"]
            TASK_EXPAND["1. Task Expansion (1:N)<br/>Match s.key_type = g.key_type"]
            STG_TASK["📋 staging_masking_task<br/>(Queue: PENDING)"]
            VALIDATE["2. Direct Key Validation<br/>• NOT_FOUND<br/>• VALIDATED"]
            COUNT["3. Estimate Rows to Mask"]
            PREVIEW["4. Generate Sample Preview<br/>(Original vs Configured mask_expression)"]
            SUMMARY["📊 masking_dry_run_summary<br/>(Before/After JSONB Previews)"]
        end

        subgraph CONFIG["⚙️ Configuration Tables"]
            GRP["masking_group<br/>(group_code, key_type, chunk_size)"]
            RULE["masking_rule<br/>(target_table, column_name, mask_expression)"]
            FN["Masking Helper Functions<br/>(fn_mask_email, fn_mask_phone, etc.)"]
        end

        subgraph PHASE2["Phase 2: Chunked Real Masking"]
            FETCH["1. Fetch Chunk<br/>(FOR UPDATE SKIP LOCKED LIMIT chunk_size)"]
            UPDATE["2. Composite Multi-Column UPDATE<br/>SET col1 = expr1, col2 = expr2<br/>WHERE key = ANY(chunk)"]
            AUDIT["3. Record Audit Trail<br/>(masking_audit_log)"]
            COMMIT["4. Micro-Transaction COMMIT<br/>+ pg_sleep(throttle_sec)"]
        end
    end

    subgraph APPROVAL["⚖️ Compliance & DPO Review"]
        DPO["Data Privacy Officer (DPO)<br/>• Inspect Sample Preview<br/>• Sign-off Approval"]
    end

    FILE --> CLI
    CLI --> STG_ITEM
    STG_ITEM --> TASK_EXPAND
    GRP -.-> TASK_EXPAND
    TASK_EXPAND --> STG_TASK
    STG_TASK --> VALIDATE
    RULE -.-> COUNT
    FN -.-> PREVIEW
    RULE -.-> PREVIEW
    COUNT --> SUMMARY
    PREVIEW --> SUMMARY
    SUMMARY --> DPO
    DPO -->|"Approved"| FETCH
    STG_TASK --> FETCH
    FETCH --> UPDATE
    RULE -.-> UPDATE
    UPDATE --> AUDIT
    AUDIT --> COMMIT
    COMMIT -->|"Next Chunk"| FETCH
```

---

## 3. End-to-End Sequence Diagram

```mermaid
sequenceDiagram
    autonumber
    actor Ops as Operations / Data Steward
    actor DPO as Data Privacy Officer (DPO)
    participant File as Excel / CSV File
    participant CLI as Python scripts/masking/ingest.py
    participant Item as staging_masking_item
    participant Task as staging_masking_task
    participant Target as Target Tables (PII Data)
    participant Summary as masking_dry_run_summary
    participant Audit as masking_audit_log

    Note over Ops,File: 1. Ingestion Phase
    Ops->>File: เตรียมรายชื่อ Key ลูกค้าที่ต้องการ Masking
    Ops->>CLI: python scripts/masking/ingest.py --file keys.xlsx --batch MASK-2026
    CLI->>Item: Bulk INSERT master keys (key_type, key_no)
    CLI-->>Ops: พิมพ์สรุปจำนวน Key ที่ Ingest สำเร็จ

    Note over Ops,Summary: 2. Phase 1: Analytical Dry Run
    Ops->>Task: CALL run_data_masking_dry_run('MASK-2026')
    Task->>Task: Task Expansion (1:N) จับคู่ key_type กับ masking_group
    Task->>Target: ตรวจสอบความมีอยู่ของ Key ใน Target Table
    Task->>Task: ระบุสถานะ VALIDATED หรือ NOT_FOUND
    loop สำหรับแต่ละ Rule ใน masking_rule
        Task->>Target: นับจำนวนแถวที่เข้าเงื่อนไข (Estimated Rows)
        Task->>Target: ดึงตัวอย่าง 5 แถว พร้อมประเมินค่า mask_expression
        Target-->>Summary: บันทึกข้อมูลสรุปและ JSON Before/After Preview
    end
    Task-->>Ops: Dry Run สำเร็จ

    Note over Ops,DPO: 3. DPO Sign-off
    Ops->>DPO: ส่งรายงาน Before/After Preview ให้ DPO ตรวจสอบ
    DPO->>Summary: SELECT sample_preview FROM masking_dry_run_summary
    DPO-->>Ops: ตรวจสอบแล้วถูกต้องตามมาตรฐาน PDPA -> อนุมัติ (Sign-off)

    Note over Ops,Audit: 4. Phase 2: Chunked Real Masking
    Ops->>Target: CALL run_data_masking('MASK-2026')
    loop ประมวลผลทีละ Chunk (LIMIT chunk_size FOR UPDATE SKIP LOCKED)
        Task->>Task: ล็อครายการ Keys ที่มีสถานะ VALIDATED
        Target->>Target: รันคำสั่ง UPDATE รวมทุกคอลัมน์ในแต่ละตารางพร้อมกัน
        Target->>Audit: บันทึกประวัติการ Masking ราย Chunk ลงใน masking_audit_log
        Task->>Task: ปรับสถานะเป็น COMPLETED
        Task->>Task: COMMIT Micro-transaction + pg_sleep(throttle_sec)
    end
    Target-->>Ops: Real Masking Completed for all groups!
```

---

## 4. Entity-Relationship Diagram

```mermaid
erDiagram
    masking_group ||--o{ masking_rule : "contains rules"
    masking_group ||--o{ staging_masking_task : "has tasks"
    staging_masking_item ||--o{ staging_masking_task : "expands into"
    masking_group ||--o{ masking_dry_run_summary : "summarizes"
    masking_group ||--o{ masking_audit_log : "audits"

    masking_group {
        varchar group_code PK "Unique group identifier"
        varchar key_type "Identifier type from Excel (e.g. CUSTOMER_ID)"
        int chunk_size "Keys per transaction (default 500)"
        numeric throttle_sec "I/O pause in seconds (default 0.05)"
        boolean is_active "Active toggle"
        text description "Business scope"
        timestamptz created_at "Creation timestamp"
    }

    masking_rule {
        serial id PK "Rule ID"
        varchar group_code FK "References masking_group"
        varchar target_table "Table name to update"
        varchar column_name "Column name to mask"
        text mask_expression "Configured SQL logic (e.g. fn_mask_email(email))"
        int execution_order "Execution order"
        text where_clause_template "Template condition ($1 = key array)"
        boolean is_active "Active toggle"
        text description "Rule details"
    }

    staging_masking_item {
        bigserial id PK "Item ID"
        varchar batch_id "Batch identifier"
        varchar key_type "Type matching Excel"
        varchar key_no "Actual key from Excel"
        timestamptz created_at "Ingest timestamp"
    }

    staging_masking_task {
        bigserial id PK "Task ID"
        varchar batch_id "Batch identifier"
        varchar group_code FK "Group code"
        varchar key_no "Key value"
        varchar status "PENDING, NOT_FOUND, VALIDATED, COMPLETED, FAILED"
        text error_message "Failure reason if any"
        timestamptz processed_at "Timestamp of completion"
    }

    masking_dry_run_summary {
        varchar batch_id PK "Batch ID"
        varchar group_code PK "Group code"
        varchar target_table PK "Target table"
        varchar column_name PK "Target column"
        int execution_order "Execution order"
        text mask_expression "Evaluated logic"
        bigint estimated_rows_to_mask "Estimated count"
        jsonb sample_preview "Before/After array of 5 samples"
    }

    masking_audit_log {
        bigserial id PK "Audit ID"
        varchar batch_id "Batch identifier"
        varchar group_code "Group code"
        varchar target_table "Table updated"
        text columns_masked "List of columns updated"
        int masked_row_count "Number of rows updated in chunk"
        int chunk_number "Chunk sequence"
        numeric duration_sec "Execution duration"
        timestamptz processed_at "Commit timestamp"
    }
```

---

## 5. Task State Machine

```
              ┌───────────────┐
              │    PENDING    │
              └───────┬───────┘
                      │
           Task Validation Phase
                      │
         ┌────────────┴────────────┐
         ▼                         ▼
   ┌───────────┐             ┌───────────┐
   │ NOT_FOUND │             │ VALIDATED │
   └───────────┘             └─────┬─────┘
                                   │
                      Phase 2: Real Masking
                                   │
                     ┌─────────────┴─────────────┐
                     ▼                           ▼
              ┌─────────────┐             ┌─────────────┐
              │  COMPLETED  │             │   FAILED    │
              └─────────────┘             └─────────────┘
```

| สถานะ | ความหมาย | การดำเนินการต่อ |
|---|---|---|
| `PENDING` | งานเพิ่งถูกขยายจาก `staging_masking_item` | รอการตรวจสอบความมีอยู่ของข้อมูล |
| `NOT_FOUND` | Key ที่นำเข้าจาก Excel ไม่ปรากฏในตารางเป้าหมาย | รายงานให้ Ops ตรวจสอบ ไม่นำไปรันใน Phase 2 |
| `VALIDATED` | Key มีอยู่จริงในตารางเป้าหมาย และพร้อมรับการ Masking | นำไปประมวลผลต่อใน Phase 2 |
| `COMPLETED` | ข้อมูลถูกแปลงค่าและ `COMMIT` สำเร็จเรียบร้อย | จบกระบวนการ |
| `FAILED` | เกิดข้อผิดพลาดระหว่างรัน (เช่น Data Type Overflow) | หยุดระบบและบันทึกข้อความ Error |

---

## 6. Comparison: Data Deletion vs Data Masking

| มิติการเปรียบเทียบ | ระบบ Data Deletion | ระบบ Data Masking |
|---|---|---|
| **คำสั่ง SQL หลัก** | `DELETE FROM table WHERE ...` | `UPDATE table SET col = expr WHERE ...` |
| **ผลลัพธ์ต่อข้อมูล** | แถวข้อมูลถูกลบถาวร (Hard Delete) | แถวข้อมูลยังคงอยู่ แต่ค่า PII ถูกบดบังถาวร |
| **ลำดับการประมวลผล** | **Bottom-Up** (ลูกสุด $\rightarrow$ แม่) ป้องกัน FK Error | **Grouped by Table** (รวมหลายคอลัมน์ใน 1 UPDATE) |
| **ความเสี่ยงด้าน Constraints** | ติด Foreign Key Violation หากไม่เรียงลำดับ | เสี่ยงต่อ Unique Index Collision หากใช้ค่าคงที่ |
| **การทำงานของ Dry Run** | นับจำนวนแถวที่คาดว่าจะถูกลบ | นับจำนวนแถว + **แสดงตัวอย่าง Before/After Value** |
| **การจัดการขอบเขตข้อมูล** | อ้างอิงตาม Excel Master Keys | อ้างอิงตาม Excel Master Keys |
| **การยืนยันความถูกต้อง** | ตรวจสอบว่า `COUNT(*)` ลดลงตามคาด | ตรวจสอบว่า PII กลายเป็น Masked String แต่ `COUNT(*)` เท่าเดิม |
