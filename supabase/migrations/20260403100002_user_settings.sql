-- ─────────────────────────────────────────────────────────────────────────
-- user_settings — per-user UI preferences
--
-- Today stores one flag: show_stock. Controls whether a rep sees live
-- stock quantities in the product catalog. Super-admin flips via the
-- admin_users_tab "Stock visibility" switch.
--
-- Originally applied ad-hoc via SQL Editor (file at project root:
-- supabase_migration_stock_visibility.sql). Captured here for fresh-env
-- reproducibility; idempotent so it's a no-op on production.
-- ─────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.user_settings (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    UUID REFERENCES public.app_users(id) ON DELETE CASCADE UNIQUE,
  show_stock BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE public.user_settings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Authenticated users can manage user settings"
  ON public.user_settings;
CREATE POLICY "Authenticated users can manage user settings"
  ON public.user_settings FOR ALL
  USING (auth.role() = 'authenticated')
  WITH CHECK (auth.role() = 'authenticated');
