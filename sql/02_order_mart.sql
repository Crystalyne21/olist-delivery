-- Одна оценка на заказ. При нескольких ответах сохраняем последний.
CREATE VIEW v_latest_review AS
WITH ranked AS (
    SELECT
        order_id,
        score,
        answered_ts,
        ROW_NUMBER() OVER (
            PARTITION BY order_id
            ORDER BY datetime(answered_ts) DESC, datetime(created_ts) DESC,
                     review_id DESC, score DESC
        ) AS review_rank
    FROM raw_reviews
)
SELECT order_id, score, answered_ts
FROM ranked
WHERE review_rank = 1;

-- Категория присваивается, только если она известна и одинакова у всех позиций.
CREATE VIEW v_order_category AS
SELECT
    item.order_id,
    CASE
        WHEN COUNT(product.category_code) < COUNT(*) THEN 'unknown'
        WHEN COUNT(DISTINCT product.category_code) > 1 THEN 'multiple'
        ELSE 'single'
    END AS category_status,
    CASE
        WHEN COUNT(product.category_code) = COUNT(*)
         AND COUNT(DISTINCT product.category_code) = 1
        THEN MIN(product.category_code)
    END AS category_code
FROM raw_items AS item
LEFT JOIN raw_products AS product USING (product_id)
GROUP BY item.order_id;

CREATE TABLE order_mart AS
WITH delivered AS (
    SELECT
        order_id,
        customer_id,
        date(purchase_ts) AS purchase_date,
        strftime('%Y-%m', purchase_ts) AS purchase_month,
        delivered_ts,
        date(promised_ts) AS promised_date,
        date(delivered_ts) AS delivered_date,
        CAST(julianday(date(delivered_ts)) - julianday(date(promised_ts)) AS INTEGER)
            AS delay_days
    FROM raw_orders
    WHERE order_status = 'delivered'
      AND date(delivered_ts) >= date(purchase_ts)
      AND date(promised_ts) >= date(purchase_ts)
)
SELECT
    delivered.order_id,
    delivered.purchase_date,
    delivered.purchase_month,
    COALESCE(customer.customer_state, 'Не указан') AS state,
    COALESCE(category.category_status, 'no_items') AS category_status,
    category.category_code,
    COALESCE(translation.category_name, category.category_code) AS category,
    delivered.promised_date,
    delivered.delivered_date,
    delivered.delivered_ts,
    delivered.delay_days,
    CASE
        WHEN delivered.delay_days <= 0 THEN 'on_time'
        WHEN delivered.delay_days <= 2 THEN 'late_1_2'
        WHEN delivered.delay_days <= 7 THEN 'late_3_7'
        ELSE 'late_8_plus'
    END AS bucket,
    review.score,
    review.answered_ts
FROM delivered
LEFT JOIN raw_customers AS customer USING (customer_id)
LEFT JOIN v_latest_review AS review USING (order_id)
LEFT JOIN v_order_category AS category USING (order_id)
LEFT JOIN raw_categories AS translation ON translation.category_code = category.category_code;

CREATE UNIQUE INDEX idx_order_mart_id ON order_mart (order_id);

CREATE VIEW v_order_flags AS
SELECT
    order_mart.*,
    CASE bucket WHEN 'on_time' THEN 0 WHEN 'late_1_2' THEN 1 WHEN 'late_3_7' THEN 2 ELSE 3 END
        AS bucket_order,
    score IS NOT NULL AS is_rated,
    COALESCE(score <= 2, 0) AS is_low,
    delay_days > 0 AS is_late,
    COALESCE(datetime(answered_ts) >= datetime(delivered_ts), 0) AS is_rated_after_delivery
FROM order_mart;
