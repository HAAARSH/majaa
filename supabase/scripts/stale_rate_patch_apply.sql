-- ─────────────────────────────────────────────────────────────────────────
-- Apply the stale-rate patch — DESTRUCTIVE. Run preview first.
--
-- Wraps three steps in a single transaction:
--   1. Snapshot every affected order_items + orders row into backup tables
--      named with today's date so you can roll back later.
--   2. UPDATE order_items: bump unit_price, mrp, line_total — preserving
--      the saved discount ratio.
--   3. UPDATE orders: recompute subtotal, vat, grand_total from the
--      patched line_totals.
--
-- HOW TO RUN:
--   • Open Supabase Studio → SQL Editor.
--   • Paste this entire file.
--   • Click Run. The transaction commits atomically — either everything
--     applies or nothing does.
--   • Verify with the post-run SELECTs at the bottom.
--   • If anything looks wrong, run rollback section (commented out).
-- ─────────────────────────────────────────────────────────────────────────

BEGIN;


-- ═════════════════════════════════════════════════════════════════════════
-- 1. Snapshot affected rows into backup tables.
-- ═════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.backup_order_items_2026_04_25 AS
SELECT oi.*
FROM public.order_items oi
JOIN public.orders   o ON o.id = oi.order_id
JOIN public.products p ON p.id = oi.product_id
WHERE o.status::text IN ('Pending', 'Confirmed', 'Delivered',
                         'Pending Verification', 'Verified', 'Partially Delivered')
  AND oi.unit_price > 0
  AND (p.unit_price > oi.unit_price OR p.mrp > oi.mrp);

CREATE TABLE IF NOT EXISTS public.backup_orders_2026_04_25 AS
SELECT DISTINCT o.*
FROM public.orders o
JOIN public.order_items oi ON oi.order_id = o.id
JOIN public.products    p  ON p.id = oi.product_id
WHERE o.status::text IN ('Pending', 'Confirmed', 'Delivered',
                         'Pending Verification', 'Verified', 'Partially Delivered')
  AND oi.unit_price > 0
  AND (p.unit_price > oi.unit_price OR p.mrp > oi.mrp);


-- ═════════════════════════════════════════════════════════════════════════
-- 2. Patch order_items.
-- ═════════════════════════════════════════════════════════════════════════

UPDATE public.order_items oi
SET
  unit_price = CASE
    WHEN oi.mrp IS NULL OR oi.mrp = 0 THEN p.unit_price
    ELSE ROUND((oi.unit_price / oi.mrp * p.mrp)::numeric, 2)
  END,
  mrp        = p.mrp,
  line_total = oi.quantity * (
    CASE
      WHEN oi.mrp IS NULL OR oi.mrp = 0 THEN p.unit_price
      ELSE ROUND((oi.unit_price / oi.mrp * p.mrp)::numeric, 2)
    END
  )
FROM public.orders   o,
     public.products p
WHERE o.id  = oi.order_id
  AND p.id  = oi.product_id
  AND o.status::text IN ('Pending', 'Confirmed', 'Delivered',
                         'Pending Verification', 'Verified', 'Partially Delivered')
  AND oi.unit_price > 0
  AND (p.unit_price > oi.unit_price OR p.mrp > oi.mrp);


-- ═════════════════════════════════════════════════════════════════════════
-- 3. Recompute order totals from patched line_totals.
-- Only touch orders that had at least one line in the backup.
-- ═════════════════════════════════════════════════════════════════════════

WITH order_recalc AS (
  SELECT
    oi.order_id,
    SUM(oi.line_total)                                            AS new_subtotal,
    SUM(oi.line_total * COALESCE(oi.gst_rate, 0))                 AS new_vat
  FROM public.order_items oi
  WHERE oi.order_id IN (SELECT DISTINCT order_id FROM public.backup_order_items_2026_04_25)
  GROUP BY oi.order_id
)
UPDATE public.orders o
SET
  subtotal    = ROUND(r.new_subtotal::numeric, 2),
  vat         = ROUND(r.new_vat::numeric, 2),
  grand_total = ROUND((r.new_subtotal + r.new_vat)::numeric, 2),
  updated_at  = now()
FROM order_recalc r
WHERE o.id = r.order_id;


-- ═════════════════════════════════════════════════════════════════════════
-- 4. Sanity check before commit. Inspect these rows; if anything is wrong,
-- run ROLLBACK; instead of COMMIT;
-- ═════════════════════════════════════════════════════════════════════════

-- 4a. How many rows were patched?
SELECT 'order_items_backed_up' AS metric, COUNT(*) AS n
  FROM public.backup_order_items_2026_04_25
UNION ALL
SELECT 'orders_backed_up',                COUNT(*)
  FROM public.backup_orders_2026_04_25;

-- 4b. Spot-check the two known orders.
SELECT id, customer_name, subtotal, vat, grand_total, updated_at
FROM public.orders
WHERE id IN ('IMP-MA-260424022726', 'IMP-MA-260423220622');


COMMIT;


-- ─────────────────────────────────────────────────────────────────────────
-- ROLLBACK PROCEDURE (run only if you change your mind AFTER COMMIT).
-- Uncomment, run as a separate session.
-- ─────────────────────────────────────────────────────────────────────────
-- BEGIN;
-- UPDATE public.order_items oi
-- SET unit_price = b.unit_price, mrp = b.mrp, line_total = b.line_total
-- FROM public.backup_order_items_2026_04_25 b
-- WHERE oi.id = b.id;
--
-- UPDATE public.orders o
-- SET subtotal = b.subtotal, vat = b.vat, grand_total = b.grand_total,
--     updated_at = b.updated_at
-- FROM public.backup_orders_2026_04_25 b
-- WHERE o.id = b.id;
-- COMMIT;
