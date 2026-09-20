-- =============================================
-- Mock Tables: 3-Level Parent-Child Hierarchy
-- orders -> order_items -> order_item_logs
-- =============================================

CREATE TABLE orders (
    order_no VARCHAR(20) PRIMARY KEY,
    order_date DATE NOT NULL,
    customer_name VARCHAR(100) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE order_items (
    id BIGSERIAL PRIMARY KEY,
    order_no VARCHAR(20) NOT NULL REFERENCES orders(order_no),
    item_name VARCHAR(100) NOT NULL,
    qty INT NOT NULL DEFAULT 1,
    amount NUMERIC(12,2) NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_order_items_order_no ON order_items(order_no);

CREATE TABLE order_item_logs (
    id BIGSERIAL PRIMARY KEY,
    item_id BIGINT NOT NULL REFERENCES order_items(id),
    log_text TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_order_item_logs_item_id ON order_item_logs(item_id);
