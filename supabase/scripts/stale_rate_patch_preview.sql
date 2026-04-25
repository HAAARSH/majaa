-- ─────────────────────────────────────────────────────────────────────────
-- Preview the stale-rate patch — NO WRITES.
--
-- For every non-locked order with at least one line saved below the
-- current products row, this shows the exact new values we'd write.
--
-- Strategy: PRESERVE the saved discount ratio.
--   new_unit = (oi.unit_price / oi.mrp) × p.mrp   when oi.mrp > 0
--            = p.unit_price                       when oi.mrp = 0 (no ratio info)
--   new_mrp  = p.mrp
--   new_line_total = quantity × new_unit
--
-- This means:
--   • Wholesale-25% lines stay at 25% off the new MRP.
--   • CSDS-applied lines (csds_disc_per IS NOT NULL) keep their discount.
--   • Lines that were stamped at the master rate get bumped to the new master rate.
--
-- Run this first. Vet the preview (especially `delta_grand_total`). Only
-- then run stale_rate_patch_apply.sql.
-- ─────────────────────────────────────────────────────────────────────────


-- P1. Per-line preview: old → new for every line that needs patching.
WITH affected_lines AS (
  SELECT
    oi.id                                       AS oi_id,
    oi.order_id,
    o.team_id,
    o.customer_name,
    oi.product_name,
    oi.sku,
    oi.quantity,
    oi.unit_price                               AS old_unit,
    oi.mrp                                      AS old_mrp,
    oi.line_total                               AS old_line_total,
    p.unit_price                                AS p_unit,
    p.mrp                                       AS p_mrp,
    -- Preserve discount ratio. If old_mrp is 0/null (no ratio info),
    -- snap straight to current master rate.
    CASE
      WHEN oi.mrp IS NULL OR oi.mrp = 0 THEN p.unit_price
      ELSE ROUND((oi.unit_price / oi.mrp * p.mrp)::numeric, 2)
    END                                         AS new_unit,
    p.mrp                                       AS new_mrp,
    oi.gst_rate                                 AS gst_rate,
    o.status                                    AS order_status
  FROM public.order_items oi
  JOIN public.orders   o ON o.id = oi.order_id
  JOIN public.products p ON p.id = oi.product_id
  WHERE o.status::text IN ('Pending', 'Confirmed', 'Delivered',
                           'Pending Verification', 'Verified', 'Partially Delivered')
    AND oi.unit_price > 0
    AND (p.unit_price > oi.unit_price OR p.mrp > oi.mrp)
)
SELECT
  team_id,
  order_id,
  customer_name,
  product_name,
  quantity                                      AS qty,
  old_unit,
  new_unit,
  old_mrp,
  new_mrp,
  ROUND(((new_unit - old_unit) * quantity)::numeric, 2) AS delta_line_total
FROM affected_lines
ORDER BY (new_unit - old_unit) * quantity DESC
LIMIT 500;


-- P2. Per-order preview: old totals → new totals.
WITH affected_lines AS (
  SELECT
    oi.id, oi.order_id, oi.quantity, oi.unit_price AS old_unit, oi.mrp AS old_mrp,
    oi.line_total AS old_line_total, oi.gst_rate,
    CASE
      WHEN oi.mrp IS NULL OR oi.mrp = 0 THEN p.unit_price
      ELSE ROUND((oi.unit_price / oi.mrp * p.mrp)::numeric, 2)
    END AS new_unit,
    p.mrp AS new_mrp
  FROM public.order_items oi
  JOIN public.orders   o ON o.id = oi.order_id
  JOIN public.products p ON p.id = oi.product_id
  WHERE o.status::text IN ('Pending', 'Confirmed', 'Delivered',
                           'Pending Verification', 'Verified', 'Partially Delivered')
    AND oi.unit_price > 0
    AND (p.unit_price > oi.unit_price OR p.mrp > oi.mrp)
),
patched_orders AS (
  -- Sum NEW values across ALL lines of each affected order, including
  -- the lines we're NOT changing (those keep their existing line_total).
  SELECT
    o.id                AS order_id,
    o.team_id,
    o.customer_name,
    o.subtotal          AS old_subtotal,
    o.vat               AS old_vat,
    o.grand_total       AS old_grand_total,
    SUM(
      COALESCE(al.new_unit, oi.unit_price) * oi.quantity
    )                                                  AS new_subtotal,
    SUM(
      COALESCE(al.new_unit, oi.unit_price) * oi.quantity
        * COALESCE(oi.gst_rate, 0)
    )                                                  AS new_vat
  FROM public.orders o
  JOIN public.order_items oi ON oi.order_id = o.id
  LEFT JOIN affected_lines al ON al.id = oi.id
  WHERE o.id IN (SELECT DISTINCT order_id FROM affected_lines)
  GROUP BY o.id, o.team_id, o.customer_name, o.subtotal, o.vat, o.grand_total
)
SELECT
  team_id,
  order_id,
  customer_name,
  ROUND(old_grand_total::numeric, 2)                         AS old_grand_total,
  ROUND((new_subtotal + new_vat)::numeric, 2)                AS new_grand_total,
  ROUND(((new_subtotal + new_vat) - old_grand_total)::numeric, 2)
                                                             AS delta_grand_total
FROM patched_orders
ORDER BY delta_grand_total DESC;


-- P3. Bottom-line: total ₹ recovery if you apply the patch.
WITH affected_lines AS (
  SELECT oi.quantity, oi.unit_price AS old_unit, oi.mrp AS old_mrp,
         oi.gst_rate,
         CASE
           WHEN oi.mrp IS NULL OR oi.mrp = 0 THEN p.unit_price
           ELSE ROUND((oi.unit_price / oi.mrp * p.mrp)::numeric, 2)
         END AS new_unit,
         o.team_id
  FROM public.order_items oi
  JOIN public.orders   o ON o.id = oi.order_id
  JOIN public.products p ON p.id = oi.product_id
  WHERE o.status::text IN ('Pending', 'Confirmed', 'Delivered',
                           'Pending Verification', 'Verified', 'Partially Delivered')
    AND oi.unit_price > 0
    AND (p.unit_price > oi.unit_price OR p.mrp > oi.mrp)
)
SELECT
  team_id,
  COUNT(*)                                                              AS lines_to_patch,
  ROUND(SUM((new_unit - old_unit) * quantity)::numeric, 2)              AS recovered_subtotal,
  ROUND(SUM((new_unit - old_unit) * quantity * COALESCE(gst_rate, 0))::numeric, 2)
                                                                        AS recovered_vat,
  ROUND(SUM((new_unit - old_unit) * quantity * (1 + COALESCE(gst_rate, 0)))::numeric, 2)
                                                                        AS recovered_grand
FROM affected_lines
GROUP BY team_id
ORDER BY team_id;
