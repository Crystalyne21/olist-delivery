-- Общие числители и знаменатели по группам опоздания и штатам.
CREATE VIEW v_severity_by_state AS
SELECT
    state, bucket, bucket_order,
    COUNT(*) AS delivered,
    SUM(is_rated) AS rated,
    SUM(is_low) AS low,
    SUM(is_late) AS late,
    SUM(is_late * is_rated) AS late_rated,
    SUM(is_late * is_low) AS late_low,
    SUM(is_rated_after_delivery) AS rated_after_delivery,
    SUM(is_rated_after_delivery * is_low) AS low_after_delivery
FROM v_order_flags
GROUP BY state, bucket, bucket_order;

CREATE VIEW v_severity AS
SELECT
    bucket, bucket_order,
    SUM(delivered) AS delivered,
    SUM(rated) AS rated,
    SUM(low) AS low,
    SUM(late) AS late,
    SUM(late_rated) AS late_rated,
    SUM(late_low) AS late_low,
    SUM(rated_after_delivery) AS rated_after_delivery,
    SUM(low_after_delivery) AS low_after_delivery,
    SUM(low)::numeric / NULLIF(SUM(rated), 0) AS low_rate,
    SUM(low_after_delivery)::numeric / NULLIF(SUM(rated_after_delivery), 0) AS low_after_delivery_rate
FROM v_severity_by_state
GROUP BY bucket, bucket_order;

CREATE VIEW v_summary AS
WITH totals AS (
    SELECT
        SUM(delivered) AS delivered,
        SUM(rated) AS rated,
        SUM(low) AS low,
        SUM(late) AS late,
        SUM(late_rated) AS late_rated,
        SUM(late_low) AS late_low,
        SUM(rated_after_delivery) AS rated_after_delivery,
        SUM(low_after_delivery) AS low_after_delivery
    FROM v_severity
),
scope AS (
    SELECT
        MIN(purchase_date) AS first_purchase_date,
        MAX(purchase_date) AS last_purchase_date,
        COUNT(category_code) AS category_orders
    FROM order_mart
),
rates AS (
    SELECT
        totals.*,
        rated - late_rated AS ontime_rated,
        low - late_low AS ontime_low,
        late::numeric / NULLIF(delivered, 0) AS delay_rate,
        late_low::numeric / NULLIF(late_rated, 0) AS late_low_rate,
        (low - late_low)::numeric / NULLIF(rated - late_rated, 0) AS ontime_low_rate
    FROM totals
)
SELECT
    rates.*,
    100 * (late_low_rate - ontime_low_rate) AS low_rate_gap_pp,
    (SELECT COUNT(*) FROM raw_orders) AS raw_orders,
    scope.*
FROM rates
CROSS JOIN scope;

CREATE VIEW v_monthly_by_state AS
SELECT
    purchase_month AS month, state,
    COUNT(*) AS delivered,
    SUM(is_rated) AS rated,
    SUM(is_low) AS low,
    SUM(is_late) AS late,
    SUM(is_late * is_rated) AS late_rated,
    SUM(is_late * is_low) AS late_low
FROM v_order_flags
GROUP BY purchase_month, state;

CREATE VIEW v_monthly AS
SELECT
    month,
    SUM(delivered) AS delivered,
    SUM(rated) AS rated,
    SUM(low) AS low,
    SUM(late) AS late,
    SUM(late_rated) AS late_rated,
    SUM(late_low) AS late_low,
    SUM(late)::numeric / NULLIF(SUM(delivered), 0) AS delay_rate,
    SUM(low)::numeric / NULLIF(SUM(rated), 0) AS low_rate
FROM v_monthly_by_state
GROUP BY month;

CREATE VIEW v_segments AS
WITH counts AS (
    SELECT
        CASE
            WHEN GROUPING(category) = 1 THEN 'state'
            WHEN GROUPING(state) = 1 THEN 'category'
            ELSE 'state_category'
        END AS segment_type,
        state,
        category,
        COUNT(*) AS delivered,
        SUM(is_rated) AS rated,
        SUM(is_low) AS low,
        SUM(is_late) AS late,
        SUM(is_late * is_rated) AS late_rated,
        SUM(is_late * is_low) AS late_low
    FROM v_order_flags
    GROUP BY GROUPING SETS ((state), (category), (state, category))
    -- Заказы без известной категории входят только в срез по штату.
    HAVING GROUPING(category) = 1 OR category IS NOT NULL
)
SELECT
    segment_type,
    CASE segment_type
        WHEN 'state' THEN state
        WHEN 'category' THEN category
        ELSE state || ' · ' || category
    END AS segment,
    state,
    category,
    counts.delivered,
    counts.rated,
    counts.low,
    counts.late,
    counts.late_rated,
    counts.late_low,
    late::numeric / NULLIF(delivered, 0) AS delay_rate,
    late_low::numeric / NULLIF(late_rated, 0) AS late_low_rate,
    (low - late_low)::numeric / NULLIF(rated - late_rated, 0) AS ontime_low_rate
FROM counts;

-- Порог применяется внутри каждого типа среза. Один заказ может входить в разные типы.
CREATE VIEW v_priority_queue AS
SELECT
    ROW_NUMBER() OVER (
        PARTITION BY segment_type
        ORDER BY late_low DESC, delivered DESC, segment
    ) AS priority,
    v_segments.*
FROM v_segments
WHERE delivered >= 100 AND late_rated >= 20;

-- Штат продавца можно назначить заказу, если он известен и совпадает у всех позиций.
CREATE VIEW v_routes AS
WITH seller_origin AS (
    SELECT item.order_id, MIN(seller.seller_state) AS seller_state
    FROM raw_items AS item
    LEFT JOIN raw_sellers AS seller USING (seller_id)
    GROUP BY item.order_id
    HAVING COUNT(seller.seller_state) = COUNT(*)
       AND COUNT(DISTINCT seller.seller_state) = 1
)
SELECT
    seller_origin.seller_state,
    flags.state AS customer_state,
    flags.category,
    COUNT(*) AS delivered,
    SUM(is_late) AS late,
    SUM(is_late * is_rated) AS late_rated,
    SUM(is_late * is_low) AS late_low
FROM seller_origin
JOIN v_order_flags AS flags USING (order_id)
WHERE flags.category_code IS NOT NULL
GROUP BY seller_origin.seller_state, flags.state, flags.category;

CREATE VIEW v_top_segment_routes AS
SELECT route.*
FROM v_routes AS route
JOIN v_priority_queue AS segment
    ON segment.state = route.customer_state AND segment.category = route.category
WHERE segment.segment_type = 'state_category' AND segment.priority = 1;
