-- Поле ok должно быть равно 1 у всех проверок согласованности.
CREATE VIEW v_checks AS
WITH reference AS (
    SELECT
        COUNT(*) AS delivered,
        COUNT(score) AS rated,
        COUNT(CASE WHEN score BETWEEN 1 AND 2 THEN 1 END) AS low,
        COUNT(CASE WHEN delivered_date > promised_date THEN 1 END) AS late,
        COUNT(CASE WHEN delivered_date > promised_date AND score BETWEEN 1 AND 2 THEN 1 END) AS late_low,
        COUNT(category_code) AS category_orders
    FROM order_mart
),
checks AS (
    SELECT 'mart_has_rows' AS check_name, (SELECT COUNT(*) FROM order_mart) AS actual, 1 AS expected
    UNION ALL
    SELECT 'one_row_per_order', (SELECT COUNT(order_id) FROM order_mart),
           (SELECT COUNT(DISTINCT order_id) FROM order_mart)
    UNION ALL
    SELECT 'source_delivered_eligible',
           (SELECT delivered FROM reference),
           (SELECT COUNT(*) FROM raw_orders WHERE order_status = 'delivered'
            AND date(delivered_ts) >= date(purchase_ts) AND date(promised_ts) >= date(purchase_ts))
    UNION ALL
    SELECT 'summary_rated', (SELECT rated FROM v_summary), (SELECT rated FROM reference)
    UNION ALL
    SELECT 'summary_low', (SELECT low FROM v_summary), (SELECT low FROM reference)
    UNION ALL
    SELECT 'summary_late', (SELECT late FROM v_summary), (SELECT late FROM reference)
    UNION ALL
    SELECT 'summary_late_low', (SELECT late_low FROM v_summary), (SELECT late_low FROM reference)
    UNION ALL
    SELECT 'monthly_delivered', (SELECT SUM(delivered) FROM v_monthly), (SELECT delivered FROM reference)
    UNION ALL
    SELECT 'monthly_late_low', (SELECT SUM(late_low) FROM v_monthly), (SELECT late_low FROM reference)
    UNION ALL
    SELECT 'state_scope', (SELECT SUM(delivered) FROM v_segments WHERE segment_type = 'state'),
           (SELECT delivered FROM reference)
    UNION ALL
    SELECT 'category_scope', (SELECT SUM(delivered) FROM v_segments WHERE segment_type = 'category'),
           (SELECT category_orders FROM reference)
    UNION ALL
    SELECT 'state_category_scope', (SELECT SUM(delivered) FROM v_segments WHERE segment_type = 'state_category'),
           (SELECT category_orders FROM reference)
    UNION ALL
    SELECT 'same_calendar_day_is_on_time',
           (SELECT COUNT(*) FROM order_mart WHERE delivered_date = promised_date AND bucket <> 'on_time'), 0
    UNION ALL
    SELECT 'valid_severity_denominators',
           (SELECT COUNT(*) FROM v_severity WHERE low > rated OR rated > delivered
            OR low_after_delivery > rated_after_delivery OR rated_after_delivery > rated), 0
)
SELECT check_name, actual, expected,
       CASE WHEN check_name = 'mart_has_rows' THEN actual >= expected ELSE actual = expected END AS ok
FROM checks;

-- Наблюдения о покрытии и аномалиях. Ненулевые значения ожидаемы.
CREATE VIEW v_coverage AS
SELECT 'raw_orders' AS metric, COUNT(*) AS value FROM raw_orders
UNION ALL
SELECT 'status_delivered', COUNT(*) FROM raw_orders WHERE order_status = 'delivered'
UNION ALL
SELECT 'excluded_delivered', COUNT(*) FROM raw_orders AS orders
WHERE orders.order_status = 'delivered'
  AND NOT EXISTS (SELECT 1 FROM order_mart AS mart WHERE mart.order_id = orders.order_id)
UNION ALL
SELECT 'orders_with_multiple_review_rows', COUNT(*) FROM (
    SELECT order_id FROM raw_reviews GROUP BY order_id HAVING COUNT(*) > 1
)
UNION ALL
SELECT 'reviews_missing_in_mart', COUNT(*) FROM order_mart WHERE score IS NULL
UNION ALL
SELECT 'answers_before_purchase', COUNT(*) FROM order_mart AS mart JOIN raw_orders AS orders USING (order_id)
WHERE datetime(mart.answered_ts) < datetime(orders.purchase_ts)
UNION ALL
SELECT 'answers_before_delivery', COUNT(*) FROM order_mart
WHERE datetime(answered_ts) < datetime(delivered_ts)
UNION ALL
SELECT 'late_8_plus_answers_before_delivery', COUNT(*) FROM order_mart
WHERE bucket = 'late_8_plus' AND datetime(answered_ts) < datetime(delivered_ts)
UNION ALL
SELECT 'late_8_plus_answers_before_delivery_after_promised_day', COUNT(*) FROM order_mart
WHERE bucket = 'late_8_plus'
  AND datetime(answered_ts) < datetime(delivered_ts)
  AND date(answered_ts) > promised_date
UNION ALL
SELECT 'category_' || category_status, COUNT(*) FROM order_mart GROUP BY category_status;
