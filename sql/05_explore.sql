-- Запросы для анализа в PostgreSQL.
SET search_path TO olist_delivery, pg_catalog;

-- Итог по всему наблюдаемому периоду.
SELECT * FROM v_summary;

-- Связь оценок с задержкой и проверка по ответам после доставки.
SELECT
    bucket, delivered, rated, low, ROUND(100 * low_rate, 2) AS low_pct,
    rated_after_delivery, low_after_delivery,
    ROUND(100 * low_after_delivery_rate, 2) AS low_pct_after_delivery
FROM v_severity
ORDER BY bucket_order;

-- Динамика по месяцу покупки и взвешенная доля опозданий за 3 месяца.
-- Календарь сохраняет пропуски, чтобы LAG всегда смотрел ровно на месяц назад.
WITH calendar AS (
    SELECT TO_CHAR(month_start, 'YYYY-MM') AS month
    FROM GENERATE_SERIES(
        TIMESTAMP '2017-01-01', TIMESTAMP '2018-08-01', INTERVAL '1 month'
    ) AS months(month_start)
),
monthly_counts AS (
    SELECT
        calendar.month,
        COALESCE(v_monthly.delivered, 0) AS delivered,
        COALESCE(v_monthly.late, 0) AS late,
        COALESCE(v_monthly.rated, 0) AS rated,
        COALESCE(v_monthly.low, 0) AS low,
        v_monthly.delay_rate,
        v_monthly.low_rate
    FROM calendar
    LEFT JOIN v_monthly USING (month)
),
monthly_windows AS (
    SELECT
        monthly_counts.*,
        LAG(delay_rate) OVER chronological AS previous_delay_rate,
        SUM(late) OVER trailing_3 AS late_3m,
        SUM(delivered) OVER trailing_3 AS delivered_3m,
        COUNT(delay_rate) OVER trailing_3 AS months_with_deliveries
    FROM monthly_counts
    WINDOW
        chronological AS (ORDER BY month),
        trailing_3 AS (chronological ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)
)
SELECT
    month,
    delivered,
    late,
    ROUND(100 * delay_rate, 2) AS late_pct,
    ROUND(100 * previous_delay_rate, 2) AS previous_late_pct,
    ROUND(100 * (delay_rate - previous_delay_rate), 2) AS late_change_pp,
    CASE WHEN months_with_deliveries = 3
         THEN ROUND(100.0 * late_3m / delivered_3m, 2)
    END AS late_3m_pct,
    rated,
    low,
    ROUND(100 * low_rate, 2) AS low_pct
FROM monthly_windows
ORDER BY month;

-- В каких штатах сосредоточены заказы с опозданием и оценкой 1–2.
-- Для доли от общего числа таких заказов учитываются даже малые штаты.
WITH state_contribution AS (
    SELECT
        state,
        delivered,
        late,
        late_low,
        ROW_NUMBER() OVER state_order AS position,
        SUM(late_low) OVER () AS total_late_low,
        SUM(late_low) OVER (
            state_order ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS cumulative_late_low
    FROM v_segments
    WHERE segment_type = 'state'
    WINDOW state_order AS (ORDER BY late_low DESC, delivered DESC, state)
)
SELECT
    position,
    state,
    delivered,
    late,
    late_low,
    ROUND(100.0 * late / delivered, 2) AS late_pct,
    ROUND(100.0 * late_low / NULLIF(total_late_low, 0), 2) AS share_of_late_low_pct,
    ROUND(100.0 * cumulative_late_low / NULLIF(total_late_low, 0), 2)
        AS cumulative_share_of_late_low_pct
FROM state_contribution
ORDER BY position;

-- Первые пять сегментов каждого типа.
SELECT
    segment_type, priority, segment, delivered, late, late_rated, late_low,
    ROUND(100 * delay_rate, 2) AS late_pct,
    ROUND(100 * late_low_rate, 2) AS low_pct_among_late,
    ROUND(100 * ontime_low_rate, 2) AS low_pct_among_ontime
FROM v_priority_queue
WHERE priority <= 5
ORDER BY segment_type, priority;

-- Сравнение оценок внутри одинакового штата и категории.
-- В таблице 10 сегментов по числу оценённых опозданий. Итоги считаются до этого ограничения.
WITH comparable_segments AS (
    SELECT
        state,
        category,
        delivered,
        late_rated,
        rated - late_rated AS ontime_rated,
        late_low_rate,
        ontime_low_rate,
        late_low_rate - ontime_low_rate AS low_rate_gap
    FROM v_segments
    WHERE segment_type = 'state_category'
      AND delivered >= 100
      AND late_rated >= 20
      AND rated - late_rated >= 20
),
ranked_segments AS (
    SELECT
        comparable_segments.*,
        ROW_NUMBER() OVER (ORDER BY late_rated DESC, delivered DESC, state, category)
            AS position,
        COUNT(*) OVER () AS segments_compared,
        COUNT(*) FILTER (WHERE low_rate_gap > 0) OVER () AS segments_with_higher_low_rate,
        SUM(late_rated) OVER () AS late_rated_in_comparison
    FROM comparable_segments
)
SELECT
    position,
    state,
    category,
    delivered,
    late_rated,
    ontime_rated,
    ROUND(100 * late_low_rate, 2) AS late_low_pct,
    ROUND(100 * ontime_low_rate, 2) AS ontime_low_pct,
    ROUND(100 * low_rate_gap, 2) AS low_rate_gap_pp,
    segments_compared,
    segments_with_higher_low_rate,
    ROUND(100.0 * segments_with_higher_low_rate / segments_compared, 2)
        AS share_of_segments_with_higher_low_rate_pct,
    late_rated_in_comparison
FROM ranked_segments
WHERE position <= 10
ORDER BY position;

-- Штаты продавцов среди заказов ведущего сегмента «штат × категория».
SELECT *
FROM v_top_segment_routes
ORDER BY late_low DESC, delivered DESC, seller_state;

SELECT * FROM v_checks ORDER BY check_name;
SELECT * FROM v_coverage ORDER BY metric;
