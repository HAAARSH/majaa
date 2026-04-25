-- ─────────────────────────────────────────────────────────────────────────
-- Sweep ALL non-billed orders for stale-rate leak — both teams.
--
-- Scope: every order whose status is still mutable — i.e. NOT IN
-- ('Invoiced','Paid','Cancelled','Returned') — where at least one line
-- was saved BELOW the products table's current rate. Invoiced/Paid
-- orders are excluded because the invoice is already locked in DUA and
-- patching their order_items now would diverge from what was billed.
-- (Delivered + Confirmed + Pending Verification + Verified + Partially
-- Delivered + Pending are all included.)
--
-- Run all four queries; copy Q4 output to decide which orders to patch.
-- ─────────────────────────────────────────────────────────────────────────


-- Q0. List the actual order_status values that exist in YOUR live DB
-- (migrations have drifted — don't trust the migration files). Run this
-- first; whatever values show up here can be put into Q1's filter.
SELECT enumlabel
FROM pg_enum
WHERE enumtypid = (SELECT oid FROM pg_type WHERE typname = 'order_status')
ORDER BY enumsortorder;


-- ─── meanwhile, use distinct status values from orders themselves: ───
SELECT status, COUNT(*) AS n
FROM public.orders
GROUP BY status
ORDER BY n DESC;


-- Q1. Top-level tally per team — how big is the exposure?
-- Splits "plausible drift" (≤50% jump) from "suspect" (>50% jump or product
-- now charges more than 3× the saved rate). Suspect lines almost always
-- mean a bad ITMRP row, not a real hike — exclude before any UPDATE.
SELECT
  o.team_id,
  COUNT(DISTINCT o.id)                                                 AS affected_orders,
  COUNT(*)                                                             AS underold_lines,
  -- All deltas
  ROUND(SUM((p.unit_price - oi.unit_price) * oi.quantity)::numeric, 2) AS rate_loss_rs_all,
  ROUND(SUM((p.mrp        - oi.mrp)        * oi.quantity)::numeric, 2) AS mrp_drift_rs_all,
  -- Plausible only (≤50% rate hike)
  ROUND(SUM(
    CASE WHEN p.unit_price <= 1.5 * oi.unit_price
         THEN (p.unit_price - oi.unit_price) * oi.quantity
         ELSE 0 END)::numeric, 2)                                      AS rate_loss_plausible_rs,
  -- Suspect (>50% rate hike) — likely bad ITMRP match, NOT a real loss
  COUNT(*) FILTER (WHERE p.unit_price > 1.5 * oi.unit_price)           AS suspect_lines,
  ROUND(SUM(
    CASE WHEN p.unit_price > 1.5 * oi.unit_price
         THEN (p.unit_price - oi.unit_price) * oi.quantity
         ELSE 0 END)::numeric, 2)                                      AS rate_loss_suspect_rs
FROM public.order_items oi
JOIN public.orders   o ON o.id = oi.order_id
JOIN public.products p ON p.id = oi.product_id
WHERE o.status::text IN ('Pending', 'Confirmed', 'Delivered', 'Pending Verification', 'Verified', 'Partially Delivered')
  AND oi.unit_price > 0
  AND (p.unit_price > oi.unit_price OR p.mrp > oi.mrp)
GROUP BY o.team_id
ORDER BY o.team_id;


-- Q1b. The big offenders by SKU — which products drive most of the leak.
-- This is where the "DU 25/- AA" type data-quality issues become obvious.
SELECT
  oi.product_name,
  oi.sku,
  COUNT(DISTINCT oi.order_id)                                          AS in_orders,
  ROUND(AVG(oi.unit_price)::numeric, 2)                                AS avg_sold_rate,
  ROUND(MIN(p.unit_price)::numeric, 2)                                 AS curr_rate,
  ROUND((MIN(p.unit_price) / NULLIF(AVG(oi.unit_price), 0))::numeric, 2)
                                                                       AS curr_over_sold_x,
  ROUND(SUM((p.unit_price - oi.unit_price) * oi.quantity)::numeric, 2) AS rate_loss_rs,
  CASE WHEN MIN(p.unit_price) > 1.5 * AVG(oi.unit_price) THEN 'SUSPECT'
       ELSE 'plausible' END                                            AS verdict
FROM public.order_items oi
JOIN public.orders   o ON o.id = oi.order_id
JOIN public.products p ON p.id = oi.product_id
WHERE o.status::text IN ('Pending', 'Confirmed', 'Delivered', 'Pending Verification', 'Verified', 'Partially Delivered')
  AND oi.unit_price > 0
  AND p.unit_price  > oi.unit_price
GROUP BY oi.product_name, oi.sku
ORDER BY rate_loss_rs DESC
LIMIT 50;


-- Q2. Same exposure split by order source (smart-import vs rep-created).
-- Smart-import order ids start with 'IMP-{TEAM}-' (see _generateOrderId
-- in smart_import_tab.dart). Everything else is rep / desktop create.
SELECT
  o.team_id,
  CASE WHEN o.id LIKE 'IMP-%' THEN 'smart_import' ELSE 'rep_or_desktop' END AS src,
  COUNT(DISTINCT o.id)                                          AS affected_orders,
  COUNT(*)                                                      AS underold_lines,
  ROUND(SUM((p.unit_price - oi.unit_price) * oi.quantity)::numeric, 2)
                                                                AS rate_loss_rs
FROM public.order_items oi
JOIN public.orders   o ON o.id = oi.order_id
JOIN public.products p ON p.id = oi.product_id
WHERE o.status::text IN ('Pending', 'Confirmed', 'Delivered', 'Pending Verification', 'Verified', 'Partially Delivered')
  AND oi.unit_price > 0
  AND p.unit_price  > oi.unit_price
GROUP BY o.team_id, src
ORDER BY o.team_id, src;


-- Q3. Per-order summary — every affected order ranked by ₹ leak.
-- Use this to decide which to patch first.
SELECT
  o.team_id,
  o.id                                                          AS order_id,
  o.customer_name,
  o.created_at                                                  AS saved_at,
  o.status,
  o.grand_total,
  COUNT(*)                                                      AS underold_lines,
  ROUND(SUM((p.unit_price - oi.unit_price) * oi.quantity)::numeric, 2)
                                                                AS rate_loss_rs,
  ROUND(
    100.0 * SUM((p.unit_price - oi.unit_price) * oi.quantity) / NULLIF(o.grand_total, 0),
    1
  )                                                             AS leak_pct_of_total
FROM public.order_items oi
JOIN public.orders   o ON o.id = oi.order_id
JOIN public.products p ON p.id = oi.product_id
WHERE o.status::text IN ('Pending', 'Confirmed', 'Delivered', 'Pending Verification', 'Verified', 'Partially Delivered')
  AND oi.unit_price > 0
  AND p.unit_price  > oi.unit_price
GROUP BY o.team_id, o.id, o.customer_name, o.created_at, o.status, o.grand_total
ORDER BY rate_loss_rs DESC
LIMIT 200;


-- Q4. Verdict per affected line — CACHE_STALE vs ITMRP_LATE.
-- ITMRP_LATE: products row was updated AFTER order saved → DB was stale
--             at save-time, no app fault. Fix: ITMRP-fresh gate (already
--             added to smart_import_tab; reps need similar guard).
-- CACHE_STALE: DB was already correct at save-time → app wrote stale Hive
--             cache. Fix: forceRefresh (already added to smart_import_tab).
SELECT
  o.team_id,
  oi.order_id,
  o.customer_name,
  o.created_at                                  AS saved_at,
  oi.product_name,
  oi.sku,
  oi.quantity                                   AS qty,
  oi.unit_price                                 AS sold_rate,
  p.unit_price                                  AS curr_rate,
  oi.mrp                                        AS sold_mrp,
  p.mrp                                         AS curr_mrp,
  ROUND(((p.unit_price - oi.unit_price) * oi.quantity)::numeric, 2) AS line_rate_loss,
  ROUND(((p.mrp        - oi.mrp)        * oi.quantity)::numeric, 2) AS line_mrp_drift,
  p.updated_at                                  AS product_updated_at,
  CASE
    WHEN p.updated_at > o.created_at THEN 'ITMRP_LATE'
    WHEN p.updated_at < o.created_at THEN 'CACHE_STALE'
    ELSE                                  'SIMULTANEOUS'
  END                                           AS timing_verdict,
  CASE
    WHEN p.unit_price > 1.5 * oi.unit_price THEN 'SUSPECT'  -- likely bad ITMRP row
    ELSE                                         'plausible'
  END                                           AS sanity_verdict
FROM public.order_items oi
JOIN public.orders   o ON o.id = oi.order_id
JOIN public.products p ON p.id = oi.product_id
WHERE o.status::text IN ('Pending', 'Confirmed', 'Delivered', 'Pending Verification', 'Verified', 'Partially Delivered')
  AND oi.unit_price > 0
  AND (p.unit_price > oi.unit_price OR p.mrp > oi.mrp)
ORDER BY (p.unit_price - oi.unit_price) * oi.quantity DESC
LIMIT 500;


-- Q5. Reverse direction — orders OVERCHARGED (saved above current rate).
-- These mean the catalog DROPPED after save (rare). Worth knowing for
-- customer fairness, even though they're not a margin loss to us.
SELECT
  o.team_id,
  o.id                                          AS order_id,
  o.customer_name,
  COUNT(*)                                      AS overcharged_lines,
  ROUND(SUM((oi.unit_price - p.unit_price) * oi.quantity)::numeric, 2)
                                                AS overcharge_rs
FROM public.order_items oi
JOIN public.orders   o ON o.id = oi.order_id
JOIN public.products p ON p.id = oi.product_id
WHERE o.status::text IN ('Pending', 'Confirmed', 'Delivered', 'Pending Verification', 'Verified', 'Partially Delivered')
  AND oi.unit_price > 0
  AND p.unit_price  > 0
  AND oi.unit_price > p.unit_price
GROUP BY o.team_id, o.id, o.customer_name
ORDER BY overcharge_rs DESC
LIMIT 50;
