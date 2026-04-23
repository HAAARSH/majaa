-- ─────────────────────────────────────────────────────────────────────────
-- products drift catchup — mrp + subcategory
--
-- Two columns added to products via SQL Editor during the Phase 2 data
-- migration on 2026-04-03 (see supabase_migration_phase2.sql at project
-- root). They live in production today but were never captured in a
-- tracked migration. Without them, a fresh environment's products table
-- is missing MRP (used on invoices / outstanding prints) and subcategory
-- (used in the category picker).
--
-- The rest of supabase_migration_phase2.sql is a destructive data
-- migration (DELETE FROM products / order_billed_items / …) and is NOT
-- moved into this tracked tree — its schema side-effects on
-- customer_team_profiles are already captured by
-- 20260331000006_customer_team_profiles.sql which creates the final
-- schema from scratch. Only the two forgotten products columns need
-- catchup.
--
-- Idempotent — no-op on current production.
-- ─────────────────────────────────────────────────────────────────────────

ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS mrp         NUMERIC DEFAULT 0,
  ADD COLUMN IF NOT EXISTS subcategory TEXT;

COMMENT ON COLUMN public.products.mrp IS
  'Maximum Retail Price. Populated from DUA ITMRP RATE during Drive sync.';
COMMENT ON COLUMN public.products.subcategory IS
  'Free-form sub-category text used by the category picker. May be empty.';
