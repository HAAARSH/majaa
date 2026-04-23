-- ─────────────────────────────────────────────────────────────────────────
-- order_items drift catchup
--
-- Two purposes:
--
--   1. LATENT BUG FIX — add four CSDS columns that the Dart insert at
--      `order_creation_screen.dart:289-292` and `manual_order_tab.dart`
--      conditionally writes when a CsdsPricing rule matches. Production
--      currently has no such columns. CSDS is seeded OFF in billing_rules
--      (pricing_csds_enabled = false for both JA and MA), so the
--      conditional keys never land today — but the moment an admin
--      toggles CSDS ON via the Rules Tab for either team and places an
--      order against a matching rule, the insert will fail with
--      "column does not exist" and the order is LOST.
--
--   2. DOCUMENT DRIFT — `gst_rate` and `user_id` already exist in
--      production on order_items (added ad-hoc via Supabase SQL Editor
--      during earlier sessions) but no migration records them. On a
--      fresh environment they'd be missing. The ADD COLUMN IF NOT EXISTS
--      below is a no-op on production and a build-up on fresh envs.
--
-- Idempotent — safe to re-run. Confirmed via live `information_schema`
-- query on 2026-04-23 against ctrmpwmnnvvsciqouqyo.supabase.co.
-- ─────────────────────────────────────────────────────────────────────────

-- 1. CSDS line-level columns. Nullable because they are only populated
--    when a CSDS rule matches the line — regular orders leave them NULL.
ALTER TABLE public.order_items
  ADD COLUMN IF NOT EXISTS csds_disc_per   NUMERIC(5,2),
  ADD COLUMN IF NOT EXISTS csds_disc_per_3 NUMERIC(5,2),
  ADD COLUMN IF NOT EXISTS csds_disc_per_5 NUMERIC(5,2),
  ADD COLUMN IF NOT EXISTS free_qty        INTEGER;

COMMENT ON COLUMN public.order_items.csds_disc_per IS
  'D1 discount percent from the matched customer_discount_schemes rule. NULL when no rule matched or CSDS off.';
COMMENT ON COLUMN public.order_items.csds_disc_per_3 IS
  'D3 cascade discount percent. NULL when no rule.';
COMMENT ON COLUMN public.order_items.csds_disc_per_5 IS
  'D5 cascade discount percent. NULL when no rule.';
COMMENT ON COLUMN public.order_items.free_qty IS
  'Scheme free-goods count from SCHEMEPER. NULL/0 when no scheme.';

-- 2. Capture the two undocumented columns that ALREADY exist in prod so
--    fresh environments don't drift. Types match the live
--    information_schema output (gst_rate=double precision, user_id=uuid).
ALTER TABLE public.order_items
  ADD COLUMN IF NOT EXISTS gst_rate  DOUBLE PRECISION,
  ADD COLUMN IF NOT EXISTS user_id   UUID;

COMMENT ON COLUMN public.order_items.gst_rate IS
  'Per-line GST rate as a decimal fraction (e.g. 0.18 for 18%). Usually mirrors products.gst_rate at order-save time. NULL on pre-backfill rows (see 20260331000003_data_integrity_fixes.sql).';
COMMENT ON COLUMN public.order_items.user_id IS
  'app_users.id of the rep who placed the order. Stamped at createOrder() time; null on orders predating user-attribution.';
