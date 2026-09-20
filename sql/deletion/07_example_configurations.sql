-- ============================================================================
-- Configuration Guide & Enterprise Use Case Examples
-- Script: sql/07_example_configurations.sql
-- Database: PostgreSQL 16
-- System: Yearly Data Deletion System (2-Tier Architecture)
-- ============================================================================
-- ไฟล์นี้รวบรวมตัวอย่างการตั้งค่าตารางคอนฟิก:
--   1. deletion_group: กำหนดกลุ่มตาราง, ประเภท Key (key_type), Chunk Size และ Throttle
--   2. deletion_rule:  กำหนดตารางเป้าหมาย, ลำดับ Bottom-Up และ WHERE Clause Template
-- ครอบคลุม 6 รูปแบบ Enterprise Database Architecture ที่พบบ่อย
-- ============================================================================


-- ============================================================================
-- USE CASE 1: Standard 3-Tier Hierarchy (E-Commerce Orders)
-- ============================================================================
-- บริบท: ลบประวัติคำสั่งซื้อที่ปิดรอบบัญชีเกิน 5 ปี (ลบจากหลาน -> ลูก -> แม่)
-- ความสัมพันธ์: orders (1) -> order_items (N) -> order_item_logs (N)
-- Key Type: ORDER_NO (เช่น ORD-2020-001)

-- 1.1 สร้าง Group
INSERT INTO deletion_group (group_code, key_type, description, chunk_size, throttle_sec, is_active)
VALUES (
    'ORDERS_STANDARD',
    'ORDER_NO',
    'Standard 3-tier order history deletion (5-year retention)',
    500,    -- 500 orders per chunk micro-transaction
    0.05,   -- 50ms pause between chunks
    TRUE
)
ON CONFLICT (group_code) DO UPDATE
SET key_type = EXCLUDED.key_type,
    description = EXCLUDED.description,
    chunk_size = EXCLUDED.chunk_size,
    throttle_sec = EXCLUDED.throttle_sec,
    is_active = EXCLUDED.is_active;

-- 1.2 กำหนด Deletion Rules (Bottom-Up: 1 = หลานสุด, 3 = แม่สุด)
INSERT INTO deletion_rule (group_code, target_table, execution_order, where_clause_template)
VALUES
    -- Level 1: หลานสุด (order_item_logs) เชื่อมโยงผ่าน item_id ของตารางลูก
    ('ORDERS_STANDARD', 'order_item_logs', 1, 
     'WHERE item_id IN (SELECT id FROM order_items WHERE order_no = ANY($1))'),

    -- Level 2: ลูก (order_items) มีคอลัมน์ order_no โดยตรง
    ('ORDERS_STANDARD', 'order_items', 2, 
     'WHERE order_no = ANY($1)'),

    -- Level 3: แม่/Root Target Table (orders)
    ('ORDERS_STANDARD', 'orders', 3, 
     'WHERE order_no = ANY($1)')
ON CONFLICT (group_code, execution_order) DO UPDATE
SET target_table = EXCLUDED.target_table,
    where_clause_template = EXCLUDED.where_clause_template;

-- 1.3 ดัชนีแนะนำ (Index Recommendations):
-- CREATE INDEX IF NOT EXISTS idx_orders_order_no ON orders(order_no);
-- CREATE INDEX IF NOT EXISTS idx_order_items_order_no ON order_items(order_no);
-- CREATE INDEX IF NOT EXISTS idx_order_item_logs_item_id ON order_item_logs(item_id);


-- ============================================================================
-- USE CASE 2: 1:N Multi-Group Deletion (PDPA Right to be Forgotten by CUSTOMER_ID)
-- ============================================================================
-- บริบท: ลูกค้าขอลบข้อมูลตามสิทธิ PDPA โดย 1 CUSTOMER_ID กระจายไปลบ 3 กลุ่มตารางอิสระ
-- กลุ่มที่ 1 (CUST_ORDERS): คำสั่งซื้อและรายการสินค้า
-- กลุ่มที่ 2 (CUST_BILLING): ใบแจ้งหนี้และสลิปชำระเงิน
-- กลุ่มที่ 3 (CUST_PROFILE): ข้อมูลส่วนตัว, ที่อยู่จัดส่ง, และประวัติ Consent

-- 2.1 สร้าง Groups ที่รับ key_type = 'CUSTOMER_ID' เดียวกัน
INSERT INTO deletion_group (group_code, key_type, description, chunk_size, throttle_sec, is_active)
VALUES 
    ('CUST_ORDERS',  'CUSTOMER_ID', 'PDPA Purge: Customer order history', 500, 0.05, TRUE),
    ('CUST_BILLING', 'CUSTOMER_ID', 'PDPA Purge: Customer billing & payments', 500, 0.05, TRUE),
    ('CUST_PROFILE', 'CUSTOMER_ID', 'PDPA Purge: Customer personal profile & consents', 200, 0.05, TRUE)
ON CONFLICT (group_code) DO UPDATE
SET key_type = EXCLUDED.key_type, description = EXCLUDED.description, is_active = EXCLUDED.is_active;

-- 2.2 กำหนด Deletion Rules สำหรับแต่ละกลุ่ม:

-- [Group 1: CUST_ORDERS]
INSERT INTO deletion_rule (group_code, target_table, execution_order, where_clause_template)
VALUES
    ('CUST_ORDERS', 'order_item_logs', 1, 
     'WHERE item_id IN (SELECT id FROM order_items WHERE order_no IN (SELECT order_no FROM orders WHERE customer_id = ANY($1)))'),
    ('CUST_ORDERS', 'order_items', 2, 
     'WHERE order_no IN (SELECT order_no FROM orders WHERE customer_id = ANY($1))'),
    ('CUST_ORDERS', 'orders', 3, 
     'WHERE customer_id = ANY($1)')
ON CONFLICT (group_code, execution_order) DO UPDATE
SET target_table = EXCLUDED.target_table, where_clause_template = EXCLUDED.where_clause_template;

-- [Group 2: CUST_BILLING]
INSERT INTO deletion_rule (group_code, target_table, execution_order, where_clause_template)
VALUES
    ('CUST_BILLING', 'payment_receipts', 1, 
     'WHERE invoice_id IN (SELECT id FROM invoices WHERE customer_id = ANY($1))'),
    ('CUST_BILLING', 'invoice_items', 2, 
     'WHERE invoice_id IN (SELECT id FROM invoices WHERE customer_id = ANY($1))'),
    ('CUST_BILLING', 'invoices', 3, 
     'WHERE customer_id = ANY($1)')
ON CONFLICT (group_code, execution_order) DO UPDATE
SET target_table = EXCLUDED.target_table, where_clause_template = EXCLUDED.where_clause_template;

-- [Group 3: CUST_PROFILE]
INSERT INTO deletion_rule (group_code, target_table, execution_order, where_clause_template)
VALUES
    ('CUST_PROFILE', 'user_consent_logs', 1, 
     'WHERE customer_id = ANY($1)'),
    ('CUST_PROFILE', 'user_delivery_addresses', 2, 
     'WHERE customer_id = ANY($1)'),
    ('CUST_PROFILE', 'customer_profiles', 3, 
     'WHERE customer_id = ANY($1)')
ON CONFLICT (group_code, execution_order) DO UPDATE
SET target_table = EXCLUDED.target_table, where_clause_template = EXCLUDED.where_clause_template;


-- ============================================================================
-- USE CASE 3: Deep Hierarchy with Multi-Branch FKs (Logistics & Supply Chain)
-- ============================================================================
-- บริบท: ระบบขนส่งสินค้า (Shipment Tracking) ตารางแม่ 1 ตารางมีหลายกิ่ง (Multi-Branch)
-- โครงสร้างต้นไม้:
--                   shipments (Root)
--                  /                \
--         customs_clearance       parcels
--                                 /      \
--                     parcel_events    parcel_photos
-- Key Type: SHIPMENT_NO

INSERT INTO deletion_group (group_code, key_type, description, chunk_size, throttle_sec, is_active)
VALUES (
    'LOGISTICS_SHIPMENTS',
    'SHIPMENT_NO',
    'Multi-branch shipment hierarchy deletion',
    250,    -- 250 shipments (เนื่องจากมีหลายตารางลูก)
    0.08,   -- หน่วงเวลา 80ms เพื่อลด Lock contention
    TRUE
)
ON CONFLICT (group_code) DO UPDATE
SET key_type = EXCLUDED.key_type, description = EXCLUDED.description;

INSERT INTO deletion_rule (group_code, target_table, execution_order, where_clause_template)
VALUES
    -- Branch A (Parcels) ชั้นล่างสุด: รูปถ่ายพัสดุ
    ('LOGISTICS_SHIPMENTS', 'parcel_photos', 1,
     'WHERE parcel_id IN (SELECT id FROM parcels WHERE shipment_no = ANY($1))'),

    -- Branch A ชั้นล่างสุด: เหตุการณ์สแกนพัสดุ
    ('LOGISTICS_SHIPMENTS', 'parcel_events', 2,
     'WHERE parcel_id IN (SELECT id FROM parcels WHERE shipment_no = ANY($1))'),

    -- Branch A ชั้นกลาง: รายการพัสดุ
    ('LOGISTICS_SHIPMENTS', 'parcels', 3,
     'WHERE shipment_no = ANY($1)'),

    -- Branch B (Customs): รายการสำแดงศุลกากร
    ('LOGISTICS_SHIPMENTS', 'customs_items', 4,
     'WHERE shipment_no = ANY($1)'),

    -- Branch B ชั้นบน: ใบผ่านพิธีการศุลกากร
    ('LOGISTICS_SHIPMENTS', 'customs_clearances', 5,
     'WHERE shipment_no = ANY($1)'),

    -- ตาราง Root หลัก: ใบส่งของ (Shipment)
    ('LOGISTICS_SHIPMENTS', 'shipments', 6,
     'WHERE shipment_no = ANY($1)')
ON CONFLICT (group_code, execution_order) DO UPDATE
SET target_table = EXCLUDED.target_table, where_clause_template = EXCLUDED.where_clause_template;


-- ============================================================================
-- USE CASE 4: UUID & Explicit Type-Casting Pattern (Financial Transactions)
-- ============================================================================
-- บริบท: คีย์เป็น UUID ใน PostgreSQL หากส่งเป็น VARCHAR[] และไม่มี Type Cast ชัดเจน
--        อาจทำให้ Planner ทำ Type Coercion จนไม่ยอมใช้ B-Tree Index!
-- Key Type: TX_UUID (เช่น a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11)

INSERT INTO deletion_group (group_code, key_type, description, chunk_size, throttle_sec, is_active)
VALUES (
    'FINANCIAL_LEDGER',
    'TX_UUID',
    'Financial ledger purge with UUID type casting',
    300,
    0.10,   -- 100ms throttle เพื่อถนอม Financial DB
    TRUE
)
ON CONFLICT (group_code) DO UPDATE
SET key_type = EXCLUDED.key_type, description = EXCLUDED.description;

INSERT INTO deletion_rule (group_code, target_table, execution_order, where_clause_template)
VALUES
    -- สังเกตการใช้ $1::uuid[] เพื่อบังคับ Type Cast ให้ตรงกับ B-Tree Index ของคอลัมน์ UUID
    ('FINANCIAL_LEDGER', 'ledger_entry_audit_logs', 1,
     'WHERE entry_id IN (SELECT id FROM ledger_entries WHERE tx_uuid = ANY($1::uuid[]))'),

    ('FINANCIAL_LEDGER', 'ledger_entries', 2,
     'WHERE tx_uuid = ANY($1::uuid[])'),

    ('FINANCIAL_LEDGER', 'transactions', 3,
     'WHERE tx_uuid = ANY($1::uuid[])')
ON CONFLICT (group_code, execution_order) DO UPDATE
SET target_table = EXCLUDED.target_table, where_clause_template = EXCLUDED.where_clause_template;


-- ============================================================================
-- USE CASE 5: Single High-Volume Standalone Table (API Gateway Telemetry Logs)
-- ============================================================================
-- บริบท: ตาราง Log ขนาดใหญ่มาก (หลายสิบล้านแถว) ไม่มีตารางลูก (Flat Table)
--        ต้องการ Throughput สูงสุด (Chunk Size ใหญ่, Throttle สั้น)
-- Key Type: SESSION_TOKEN หรือ CLIENT_ID

INSERT INTO deletion_group (group_code, key_type, description, chunk_size, throttle_sec, is_active)
VALUES (
    'API_GATEWAY_TELEMETRY',
    'SESSION_TOKEN',
    'High-throughput purge for flat telemetry & access logs',
    2000,   -- Chunk ใหญ่ระดับ 2,000 keys ต่องวด
    0.01,   -- Throttle สั้นเพียง 10ms (เน้นความเร็ว)
    TRUE
)
ON CONFLICT (group_code) DO UPDATE
SET key_type = EXCLUDED.key_type, description = EXCLUDED.description, chunk_size = 2000, throttle_sec = 0.01;

INSERT INTO deletion_rule (group_code, target_table, execution_order, where_clause_template)
VALUES
    -- มีเพียง Rule เดียว ลำดับที่ 1
    ('API_GATEWAY_TELEMETRY', 'api_access_logs', 1,
     'WHERE session_token = ANY($1)')
ON CONFLICT (group_code, execution_order) DO UPDATE
SET target_table = EXCLUDED.target_table, where_clause_template = EXCLUDED.where_clause_template;


-- ============================================================================
-- USE CASE 6: Composite Condition & Date Retention Filter Pattern
-- ============================================================================
-- บริบท: ลบเฉพาะข้อมูลที่เข้าเงื่อนไข Key และต้องเก่ากว่าวันที่กำหนดด้วย (Extra Safeguard)
-- Key Type: INVOICE_NO

INSERT INTO deletion_group (group_code, key_type, description, chunk_size, throttle_sec, is_active)
VALUES (
    'INVOICES_CLOSED_YEAR',
    'INVOICE_NO',
    'Invoice purge with date safety filter (older than 7 years)',
    500,
    0.05,
    TRUE
)
ON CONFLICT (group_code) DO UPDATE
SET key_type = EXCLUDED.key_type, description = EXCLUDED.description;

INSERT INTO deletion_rule (group_code, target_table, execution_order, where_clause_template)
VALUES
    ('INVOICES_CLOSED_YEAR', 'invoice_attachment_files', 1,
     'WHERE invoice_no = ANY($1)'),

    ('INVOICES_CLOSED_YEAR', 'invoice_line_items', 2,
     'WHERE invoice_no = ANY($1)'),

    -- สังเกต: เพิ่มเงื่อนไข created_at < NOW() - INTERVAL '7 years' เพื่อความปลอดภัยสองชั้น
    ('INVOICES_CLOSED_YEAR', 'invoices', 3,
     'WHERE invoice_no = ANY($1) AND created_at < (CURRENT_DATE - INTERVAL ''7 years'')')
ON CONFLICT (group_code, execution_order) DO UPDATE
SET target_table = EXCLUDED.target_table, where_clause_template = EXCLUDED.where_clause_template;


-- ============================================================================
-- คำสั่งสำหรับตรวจสอบและดูภาพรวมการตั้งค่าทั้งหมด (Configuration Inspection Queries)
-- ============================================================================

-- 1. ดูรายการ Group ทั้งหมดพร้อมจำนวน Rules
SELECT 
    g.group_code,
    g.key_type,
    g.chunk_size,
    g.throttle_sec,
    g.is_active,
    COUNT(r.id) AS total_rules,
    g.description
FROM deletion_group g
LEFT JOIN deletion_rule r ON r.group_code = g.group_code
GROUP BY g.group_code, g.key_type, g.chunk_size, g.throttle_sec, g.is_active, g.description
ORDER BY g.group_code;

-- 2. ดูลำดับการลบ Bottom-Up ของทุกตารางในระบบ
SELECT 
    r.group_code,
    g.key_type,
    r.execution_order,
    r.target_table,
    r.where_clause_template
FROM deletion_rule r
JOIN deletion_group g ON g.group_code = r.group_code
ORDER BY r.group_code, r.execution_order;
