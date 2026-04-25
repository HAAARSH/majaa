-- ═════════════════════════════════════════════════════════════════════════
-- Migration audit for 2026-04-23 session (9 migrations).
--
-- HOW TO USE:
--   1. Open Supabase → SQL Editor → New query.
--   2. Paste this entire file.
--   3. Run. You'll get ~25 rows. Each row = one check.
--   4. Copy the result table back to Claude.
--
-- No customer data is read — only schema metadata + row counts on
-- small config tables.
-- ═════════════════════════════════════════════════════════════════════════

WITH checks AS (

  -- ─── 20260423000001: products.ean_code ─────────────────────────────
  SELECT '001_ean_code' AS migration,
         'products.ean_code column' AS check_name,
         CASE WHEN EXISTS (
           SELECT 1 FROM information_schema.columns
           WHERE table_schema='public' AND table_name='products'
             AND column_name='ean_code'
         ) THEN '✓ applied' ELSE '✗ MISSING' END AS status

  -- ─── 20260423000002: smart_import tables ───────────────────────────
  UNION ALL SELECT '002_smart_import', 'product_alias_learning table',
    CASE WHEN EXISTS (SELECT 1 FROM information_schema.tables
      WHERE table_schema='public' AND table_name='product_alias_learning')
      THEN '✓ applied' ELSE '✗ MISSING' END
  UNION ALL SELECT '002_smart_import', 'customer_alias_learning table',
    CASE WHEN EXISTS (SELECT 1 FROM information_schema.tables
      WHERE table_schema='public' AND table_name='customer_alias_learning')
      THEN '✓ applied' ELSE '✗ MISSING' END
  UNION ALL SELECT '002_smart_import', 'smart_import_history table',
    CASE WHEN EXISTS (SELECT 1 FROM information_schema.tables
      WHERE table_schema='public' AND table_name='smart_import_history')
      THEN '✓ applied' ELSE '✗ MISSING' END

  -- ─── 20260423000003: billing_rules tables ──────────────────────────
  UNION ALL SELECT '003_billing_rules', 'billing_rules table',
    CASE WHEN EXISTS (SELECT 1 FROM information_schema.tables
      WHERE table_schema='public' AND table_name='billing_rules')
      THEN '✓ applied' ELSE '✗ MISSING' END
  UNION ALL SELECT '003_billing_rules', 'billing_rules_audit_log table',
    CASE WHEN EXISTS (SELECT 1 FROM information_schema.tables
      WHERE table_schema='public' AND table_name='billing_rules_audit_log')
      THEN '✓ applied' ELSE '✗ MISSING' END

  -- ─── 20260423000004: billing_rules seed row count ──────────────────
  UNION ALL SELECT '004_billing_seed', 'billing_rules rows seeded',
    COALESCE(
      (SELECT CASE
         WHEN COUNT(*) >= 5 THEN '✓ ' || COUNT(*) || ' rows'
         WHEN COUNT(*) = 0 THEN '✗ 0 rows (seed not applied)'
         ELSE '⚠ only ' || COUNT(*) || ' rows (partial seed)'
       END FROM public.billing_rules),
      '✗ table missing')

  -- ─── 20260423000004a: smart_import RLS super_admin cross-team ──────
  -- The NEW policy contains the literal "'super_admin'" OR-branch
  -- separate from "'admin' AND team_id = ...". The OLD policy had both
  -- roles together in a single IN (...). We detect by substring.
  UNION ALL SELECT '004a_rls_patch', 'product_alias_learning RLS is cross-team',
    CASE WHEN EXISTS (
      SELECT 1 FROM pg_policies
      WHERE schemaname='public' AND tablename='product_alias_learning'
        AND qual LIKE '%= ''super_admin''%'
    ) THEN '✓ applied (super_admin cross-team)'
      WHEN EXISTS (SELECT 1 FROM pg_policies
        WHERE schemaname='public' AND tablename='product_alias_learning')
      THEN '⚠ OLD policy still active (super_admin pinned to home team)'
      ELSE '✗ NO policy (table might have RLS off or no policy)'
    END
  UNION ALL SELECT '004a_rls_patch', 'customer_alias_learning RLS is cross-team',
    CASE WHEN EXISTS (
      SELECT 1 FROM pg_policies
      WHERE schemaname='public' AND tablename='customer_alias_learning'
        AND qual LIKE '%= ''super_admin''%'
    ) THEN '✓ applied'
      WHEN EXISTS (SELECT 1 FROM pg_policies
        WHERE schemaname='public' AND tablename='customer_alias_learning')
      THEN '⚠ OLD policy still active' ELSE '✗ NO policy' END
  UNION ALL SELECT '004a_rls_patch', 'smart_import_history RLS is cross-team',
    CASE WHEN EXISTS (
      SELECT 1 FROM pg_policies
      WHERE schemaname='public' AND tablename='smart_import_history'
        AND qual LIKE '%= ''super_admin''%'
    ) THEN '✓ applied'
      WHEN EXISTS (SELECT 1 FROM pg_policies
        WHERE schemaname='public' AND tablename='smart_import_history')
      THEN '⚠ OLD policy still active' ELSE '✗ NO policy' END

  -- ─── 20260423000005: order_items CSDS columns ──────────────────────
  UNION ALL SELECT '005_order_items', 'order_items.csds_disc_per',
    CASE WHEN EXISTS (SELECT 1 FROM information_schema.columns
      WHERE table_schema='public' AND table_name='order_items'
        AND column_name='csds_disc_per')
      THEN '✓ applied' ELSE '✗ MISSING' END
  UNION ALL SELECT '005_order_items', 'order_items.csds_disc_per_3',
    CASE WHEN EXISTS (SELECT 1 FROM information_schema.columns
      WHERE table_schema='public' AND table_name='order_items'
        AND column_name='csds_disc_per_3')
      THEN '✓ applied' ELSE '✗ MISSING' END
  UNION ALL SELECT '005_order_items', 'order_items.csds_disc_per_5',
    CASE WHEN EXISTS (SELECT 1 FROM information_schema.columns
      WHERE table_schema='public' AND table_name='order_items'
        AND column_name='csds_disc_per_5')
      THEN '✓ applied' ELSE '✗ MISSING' END
  UNION ALL SELECT '005_order_items', 'order_items.free_qty',
    CASE WHEN EXISTS (SELECT 1 FROM information_schema.columns
      WHERE table_schema='public' AND table_name='order_items'
        AND column_name='free_qty')
      THEN '✓ applied' ELSE '✗ MISSING' END

  -- ─── 20260423000006: Phase B + billing sync tables ─────────────────
  UNION ALL SELECT '006_phase_b', 'customer_advances table',
    CASE WHEN EXISTS (SELECT 1 FROM information_schema.tables
      WHERE table_schema='public' AND table_name='customer_advances')
      THEN '✓ exists' ELSE '✗ MISSING' END
  UNION ALL SELECT '006_phase_b', 'customer_credit_notes table',
    CASE WHEN EXISTS (SELECT 1 FROM information_schema.tables
      WHERE table_schema='public' AND table_name='customer_credit_notes')
      THEN '✓ exists' ELSE '✗ MISSING' END
  UNION ALL SELECT '006_phase_b', 'customer_bills table',
    CASE WHEN EXISTS (SELECT 1 FROM information_schema.tables
      WHERE table_schema='public' AND table_name='customer_bills')
      THEN '✓ exists' ELSE '⚠ MISSING (may be ok if bills sync not used yet)' END
  UNION ALL SELECT '006_phase_b', 'customer_payments table',
    CASE WHEN EXISTS (SELECT 1 FROM information_schema.tables
      WHERE table_schema='public' AND table_name='customer_payments')
      THEN '✓ exists' ELSE '⚠ MISSING' END

  -- ─── 20260423000007: products.stock_zeroed_at + trigger ────────────
  UNION ALL SELECT '007_stock_zeroed', 'products.stock_zeroed_at column',
    CASE WHEN EXISTS (SELECT 1 FROM information_schema.columns
      WHERE table_schema='public' AND table_name='products'
        AND column_name='stock_zeroed_at')
      THEN '✓ applied' ELSE '✗ MISSING' END
  UNION ALL SELECT '007_stock_zeroed', 'products stock_zeroed_at BEFORE UPDATE trigger',
    CASE WHEN EXISTS (
      SELECT 1 FROM pg_trigger t
      JOIN pg_class c ON t.tgrelid = c.oid
      WHERE c.relname='products' AND NOT t.tgisinternal
        AND (t.tgname ILIKE '%stock%zero%' OR t.tgname ILIKE '%zeroed%')
    ) THEN '✓ trigger found' ELSE '✗ TRIGGER MISSING' END

  -- ─── 20260423000008: stock_zero_grace_days rule seed ───────────────
  UNION ALL SELECT '008_grace_rule', 'billing_rules stock_zero_grace_days seeded',
    COALESCE(
      (SELECT '✓ value=' || value::text
       FROM public.billing_rules
       WHERE rule_key='stock_zero_grace_days' LIMIT 1),
      '✗ row missing')

  -- ─── Summary row counts on the 3 smart_import tables ───────────────
  UNION ALL SELECT 'data_check', 'product_alias_learning row count',
    COALESCE((SELECT COUNT(*)::text FROM public.product_alias_learning),
             '(query failed)')
  UNION ALL SELECT 'data_check', 'customer_alias_learning row count',
    COALESCE((SELECT COUNT(*)::text FROM public.customer_alias_learning),
             '(query failed)')
  UNION ALL SELECT 'data_check', 'smart_import_history row count',
    COALESCE((SELECT COUNT(*)::text FROM public.smart_import_history),
             '(query failed)')
)
SELECT migration, check_name, status
FROM checks
ORDER BY migration, check_name;
