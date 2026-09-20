-- =============================================
-- Seed Mock Data & Deletion Rules
-- =============================================

-- 1. Seed 10,000 Orders
INSERT INTO orders (order_no, order_date, customer_name)
SELECT 
    'ORD-' || LPAD(g::TEXT, 5, '0'),
    DATE '2020-01-01' + (g % 365),
    'Customer ' || g
FROM generate_series(1, 10000) AS g;

-- 2. Seed 30,000 Order Items (3 items per order)
INSERT INTO order_items (order_no, item_name, qty, amount)
SELECT 
    'ORD-' || LPAD(((g - 1) / 3 + 1)::TEXT, 5, '0'),
    'Item-' || (((g - 1) % 3) + 1),
    ((g % 10) + 1),
    ROUND((RANDOM() * 1000)::NUMERIC, 2)
FROM generate_series(1, 30000) AS g;

-- 3. Seed 60,000 Order Item Logs (2 logs per item)
INSERT INTO order_item_logs (item_id, log_text)
SELECT 
    ((g - 1) / 2 + 1),
    CASE WHEN g % 2 = 1 THEN 'Created' ELSE 'Updated' END
FROM generate_series(1, 60000) AS g;

-- 4. Configure Deletion Group
INSERT INTO deletion_group (group_code, description, chunk_size, throttle_sec, parent_table, parent_key_col)
VALUES ('ORDERS', 'Yearly order data deletion', 500, 0.05, 'orders', 'order_no');

-- 5. Configure Deletion Rules (Bottom-Up: Grandchild → Child → Parent)
INSERT INTO deletion_rule (group_code, target_table, execution_order, where_clause_template)
VALUES 
    ('ORDERS', 'order_item_logs', 1, 'WHERE item_id IN (SELECT id FROM order_items WHERE order_no = ANY($1))'),
    ('ORDERS', 'order_items',     2, 'WHERE order_no = ANY($1)'),
    ('ORDERS', 'orders',          3, 'WHERE order_no = ANY($1)');
