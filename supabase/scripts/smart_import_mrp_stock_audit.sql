-- ─────────────────────────────────────────────────────────────────────────
-- Smart-Import MRP / Stock leak audit — MA team
--
-- The user reports that on Mahawar Brothers (IMP-MA-260424022726) and
-- Vishal Gen Store, some lines were saved at:
--   (a) prices LOWER than the current selling rate → margin loss, AND/OR
--   (b) products that have NO stock → can't be billed without manual sub.
--
-- This script:
--   0. Finds the Vishal Gen Store order id (we only know its name).
--   1. Joins order_items to current products to compare prices + stock.
--   2. Flags every problematic line.
-- ─────────────────────────────────────────────────────────────────────────


-- 0. Find candidate Vishal General Store orders on MA in the last 7 days.
SELECT id, customer_name, order_date, grand_total, status
FROM public.orders
WHERE id LIKE 'IMP-MA-%'
  AND customer_name ILIKE '%vishal%'
  AND order_date > now() - INTERVAL '7 days'
ORDER BY order_date DESC;
-- ↑ grab the matching order id and substitute it below where it says
--   '<VISHAL_ORDER_ID>' (or just keep the customer-name LIKE — query 2 uses both).


-- 1. Line-by-line audit for the two suspect orders.
-- Compares each saved line against the CURRENT product row.
WITH suspect_orders AS (
  SELECT id FROM public.orders
  WHERE id = 'IMP-MA-260424022726'           -- Mahawar Brothers
     OR (id LIKE 'IMP-MA-%'
         AND customer_name ILIKE '%vishal%'
         AND order_date > now() - INTERVAL '7 days')
)
SELECT
  oi.order_id,
  o.customer_name,
  oi.product_name,
  oi.sku,
  oi.quantity,
  -- What the order saved
  oi.unit_price        AS sold_rate,
  oi.mrp               AS sold_mrp,
  oi.line_total        AS sold_line_total,
  -- What the product master currently says
  p.unit_price         AS curr_rate,
  p.mrp                AS curr_mrp,
  p.stock_qty          AS curr_stock,
  p.status             AS prod_status,
  -- Differences — positive = customer billed below current rate (loss).
  (p.unit_price - oi.unit_price) AS rate_loss_per_unit,
  (p.unit_price - oi.unit_price) * oi.quantity AS rate_loss_total,
  (p.mrp        - oi.mrp)        AS mrp_drift,
  -- Flags
  CASE WHEN p.stock_qty = 0 THEN 'OUT_OF_STOCK' END AS flag_stock,
  CASE WHEN oi.unit_price < p.unit_price THEN 'UNDERSOLD'  END AS flag_rate,
  CASE WHEN oi.mrp        < p.mrp        THEN 'STALE_MRP'  END AS flag_mrp
FROM public.order_items oi
JOIN public.orders   o ON o.id = oi.order_id
LEFT JOIN public.products p ON p.id = oi.product_id
WHERE oi.order_id IN (SELECT id FROM suspect_orders)
ORDER BY o.id, rate_loss_total DESC NULLS LAST, oi.product_name;


-- 1b. Forensic: when did the products' MRP/rate get updated vs when each order was saved?
-- If products.updated_at < order.created_at, the live Supabase row was already
-- correct at save-time → the app wrote stale CACHE data, not stale DB data.
-- If products.updated_at > order.created_at, ITMRP push happened AFTER the import.
SELECT
  oi.order_id,
  o.created_at         AS order_saved_at,
  oi.product_name,
  oi.sku,
  oi.unit_price        AS sold_rate,
  oi.mrp               AS sold_mrp,
  p.unit_price         AS curr_rate,
  p.mrp                AS curr_mrp,
  p.updated_at         AS product_last_updated,
  CASE
    WHEN p.updated_at < o.created_at THEN 'CACHE_STALE   (DB was correct, app cache was old)'
    WHEN p.updated_at > o.created_at THEN 'ITMRP_LATE    (ITMRP push happened after save)'
    ELSE                                  'SIMULTANEOUS'
  END AS verdict
FROM public.order_items oi
JOIN public.orders   o ON o.id = oi.order_id
LEFT JOIN public.products p ON p.id = oi.product_id
WHERE oi.order_id IN ('IMP-MA-260424022726', 'IMP-MA-260423220622')
  AND (oi.unit_price < p.unit_price OR oi.mrp < p.mrp)
ORDER BY oi.order_id, p.updated_at;


-- 2. Per-order summary of the leak.
WITH suspect_orders AS (
  SELECT id FROM public.orders
  WHERE id = 'IMP-MA-260424022726'
     OR (id LIKE 'IMP-MA-%'
         AND customer_name ILIKE '%vishal%'
         AND order_date > now() - INTERVAL '7 days')
)
SELECT
  oi.order_id,
  COUNT(*)                                                             AS lines,
  COUNT(*) FILTER (WHERE p.stock_qty = 0)                              AS lines_no_stock,
  COUNT(*) FILTER (WHERE oi.unit_price < p.unit_price)                 AS lines_undersold,
  COUNT(*) FILTER (WHERE oi.mrp        < p.mrp)                        AS lines_stale_mrp,
  ROUND(SUM(GREATEST(p.unit_price - oi.unit_price, 0) * oi.quantity)::numeric, 2)
                                                                       AS rate_loss_rs,
  ROUND(SUM(oi.line_total)::numeric, 2)                                AS order_total
FROM public.order_items oi
LEFT JOIN public.products p ON p.id = oi.product_id
WHERE oi.order_id IN (SELECT id FROM suspect_orders)
GROUP BY oi.order_id
ORDER BY oi.order_id;
