CREATE SCHEMA IF NOT EXISTS olist_delivery;
SET search_path TO olist_delivery, pg_catalog;

-- При повторной загрузке заменяем таблицы и представления этой сборки.
DROP VIEW IF EXISTS
    olist_delivery.v_checks,
    olist_delivery.v_coverage,
    olist_delivery.v_top_segment_routes,
    olist_delivery.v_routes,
    olist_delivery.v_priority_queue,
    olist_delivery.v_segments,
    olist_delivery.v_monthly,
    olist_delivery.v_monthly_by_state,
    olist_delivery.v_summary,
    olist_delivery.v_severity,
    olist_delivery.v_severity_by_state,
    olist_delivery.v_order_flags,
    olist_delivery.v_order_category,
    olist_delivery.v_latest_review
    RESTRICT;

DROP TABLE IF EXISTS
    olist_delivery.order_mart,
    olist_delivery.raw_orders,
    olist_delivery.raw_customers,
    olist_delivery.raw_items,
    olist_delivery.raw_products,
    olist_delivery.raw_categories,
    olist_delivery.raw_sellers,
    olist_delivery.raw_reviews
    RESTRICT;

-- Из CSV загружаются только поля, нужные для анализа доставки.
CREATE TABLE raw_orders (
    order_id TEXT PRIMARY KEY NOT NULL,
    customer_id TEXT NOT NULL,
    order_status TEXT NOT NULL,
    purchase_ts TIMESTAMP WITHOUT TIME ZONE,
    delivered_ts TIMESTAMP WITHOUT TIME ZONE,
    promised_ts TIMESTAMP WITHOUT TIME ZONE
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
    created_ts TIMESTAMP WITHOUT TIME ZONE,
    answered_ts TIMESTAMP WITHOUT TIME ZONE
);

CREATE INDEX idx_raw_reviews_order ON raw_reviews (order_id);
