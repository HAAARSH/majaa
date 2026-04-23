-- ─────────────────────────────────────────────────────────────────────────
-- user_brand_access — per-rep brand allowlist
--
-- Controls which product brands a brand_rep can see / sell. A brand_rep
-- with zero rows in this table sees no products (fail-safe) — admin must
-- explicitly toggle at least one brand on via admin_brand_access_tab.
--
-- Originally applied ad-hoc via SQL Editor (file at project root:
-- supabase_migration_brand_access.sql). Captured here for fresh-env
-- reproducibility; idempotent so it's a no-op on production.
-- ─────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.user_brand_access (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    UUID REFERENCES public.app_users(id) ON DELETE CASCADE,
  team_id    TEXT NOT NULL,
  brand      TEXT NOT NULL, -- matches product_categories.name
  is_enabled BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE (user_id, team_id, brand)
);

ALTER TABLE public.user_brand_access ENABLE ROW LEVEL SECURITY;

-- Matches the ORIGINAL policy from supabase_migration_brand_access.sql:
-- every authenticated session can read + write. This is intentionally
-- permissive because admin + brand_rep both need write access via the
-- admin_brand_access_tab UI. Tightening would require a dedicated RPC;
-- parked for a future hardening pass.
DROP POLICY IF EXISTS "Authenticated users can manage brand access"
  ON public.user_brand_access;
CREATE POLICY "Authenticated users can manage brand access"
  ON public.user_brand_access FOR ALL
  USING (auth.role() = 'authenticated')
  WITH CHECK (auth.role() = 'authenticated');
