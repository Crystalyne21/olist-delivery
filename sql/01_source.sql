-- Из CSV загружаются только поля, нужные для анализа доставки.
CREATE TABLE raw_orders (
    order_id TEXT PRIMARY KEY NOT NULL,
    customer_id TEXT NOT NULL,
    order_status TEXT NOT NULL,
    purchase_ts TEXT,
    delivered_ts TEXT,
    promised_ts TEXT
);

CREATE TABLE raw_customers (
    customer_id TEXT PRIMARY KEY NOT NULL,
    customer_state TEXT
);

CREATE TABLE raw_items (
    order_id TEXT NOT NULL,
    order_item_id INTEGER NOT NULL,
    product_id TEXT,
    seller_id TEXT,
    PRIMARY KEY (order_id, order_item_id)
);

CREATE TABLE raw_products (
    product_id TEXT PRIMARY KEY NOT NULL,
    category_code TEXT
);

CREATE TABLE raw_categories (
    category_code TEXT PRIMARY KEY NOT NULL,
    category_name TEXT NOT NULL
);

CREATE TABLE raw_sellers (
    seller_id TEXT PRIMARY KEY NOT NULL,
    seller_state TEXT
);

CREATE TABLE raw_reviews (
    review_id TEXT NOT NULL,
    order_id TEXT NOT NULL,
    score INTEGER NOT NULL CHECK (score BETWEEN 1 AND 5),
    created_ts TEXT,
    answered_ts TEXT
);

CREATE INDEX idx_raw_reviews_order ON raw_reviews (order_id);
