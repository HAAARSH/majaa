-- ─────────────────────────────────────────────────────────────────────────
-- Recent Smart Import audit, both teams.
-- Run in Supabase Studio → SQL Editor.
-- ─────────────────────────────────────────────────────────────────────────

-- 1. All saved smart-imports in the last 14 days, JA + MA, newest first.
SELECT
  sih.team_id,
  sih.imported_at,
  sih.status,
  sih.input_type,
  sih.resulting_order_ids,
  array_length(sih.resulting_order_ids, 1) AS order_count,
  au.full_name     AS imported_by,
  au_rep.full_name AS attributed_rep,
  LEFT(sih.input_preview, 80) AS preview
FROM public.smart_import_history sih
LEFT JOIN public.app_users au     ON au.id = sih.imported_by_user_id
LEFT JOIN public.app_users au_rep ON au_rep.id = sih.attributed_brand_rep_user_id
WHERE sih.imported_at > now() - INTERVAL '14 days'
ORDER BY sih.imported_at DESC;


-- 2. Same window — flatten to one row per resulting order, joined to orders.
SELECT
  sih.team_id,
  sih.imported_at,
  ord_id            AS order_id,
  o.customer_name,
  o.grand_total,
  o.status            AS order_status,
  au_rep.full_name    AS attributed_rep
FROM public.smart_import_history sih
CROSS JOIN LATERAL unnest(sih.resulting_order_ids) AS ord_id
LEFT JOIN public.orders o          ON o.id = ord_id
LEFT JOIN public.app_users au_rep  ON au_rep.id = sih.attributed_brand_rep_user_id
WHERE sih.imported_at > now() - INTERVAL '14 days'
  AND sih.status = 'saved'
ORDER BY sih.imported_at DESC, ord_id;


-- 3. Tally per team.
SELECT
  team_id,
  COUNT(*)                                            AS import_rows,
  COUNT(*) FILTER (WHERE status = 'saved')            AS saved_imports,
  SUM(COALESCE(array_length(resulting_order_ids,1),0)) AS total_orders_created,
  MIN(imported_at)                                    AS first_import_at,
  MAX(imported_at)                                    AS last_import_at
FROM public.smart_import_history
WHERE imported_at > now() - INTERVAL '14 days'
GROUP BY team_id
ORDER BY team_id;
