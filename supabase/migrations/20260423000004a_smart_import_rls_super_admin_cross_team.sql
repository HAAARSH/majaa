-- Smart Import tables: allow super_admin to manage aliases + import history
-- across ALL teams (JA / MA). The original policy in
-- 20260423000002_smart_import_phase0.sql pinned super_admin to their own
-- team_id, which broke the Smart Import UI's team toggle: when a super_admin
-- with app_users.team_id = 'JA' picked team MA in the UI, writeCustomerAlias
-- / writeProductAlias were silently blocked by the WITH CHECK clause.
--
-- This migration keeps the admin role team-scoped (admins manage only their
-- own team) but lets super_admin operate cross-team, matching the pattern
-- already used by export_batches (20260422000003) and customer_brand_routing
-- (20260422000004).

-- ─────────────────────────────────────────────────────────────────────────
-- product_alias_learning
-- ─────────────────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "Admins manage product aliases" ON public.product_alias_learning;
CREATE POLICY "Admins manage product aliases"
  ON public.product_alias_learning FOR ALL
  USING (
    (SELECT role FROM public.app_users WHERE id::TEXT = auth.uid()::TEXT) = 'super_admin'
    OR (
      (SELECT role FROM public.app_users WHERE id::TEXT = auth.uid()::TEXT) = 'admin'
      AND team_id = (SELECT team_id FROM public.app_users WHERE id::TEXT = auth.uid()::TEXT)
    )
  )
  WITH CHECK (
    (SELECT role FROM public.app_users WHERE id::TEXT = auth.uid()::TEXT) = 'super_admin'
    OR (
      (SELECT role FROM public.app_users WHERE id::TEXT = auth.uid()::TEXT) = 'admin'
      AND team_id = (SELECT team_id FROM public.app_users WHERE id::TEXT = auth.uid()::TEXT)
    )
  );

-- ─────────────────────────────────────────────────────────────────────────
-- customer_alias_learning
-- ─────────────────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "Admins manage customer aliases" ON public.customer_alias_learning;
CREATE POLICY "Admins manage customer aliases"
  ON public.customer_alias_learning FOR ALL
  USING (
    (SELECT role FROM public.app_users WHERE id::TEXT = auth.uid()::TEXT) = 'super_admin'
    OR (
      (SELECT role FROM public.app_users WHERE id::TEXT = auth.uid()::TEXT) = 'admin'
      AND team_id = (SELECT team_id FROM public.app_users WHERE id::TEXT = auth.uid()::TEXT)
    )
  )
  WITH CHECK (
    (SELECT role FROM public.app_users WHERE id::TEXT = auth.uid()::TEXT) = 'super_admin'
    OR (
      (SELECT role FROM public.app_users WHERE id::TEXT = auth.uid()::TEXT) = 'admin'
      AND team_id = (SELECT team_id FROM public.app_users WHERE id::TEXT = auth.uid()::TEXT)
    )
  );

-- ─────────────────────────────────────────────────────────────────────────
-- smart_import_history
-- ─────────────────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "Admins manage import history" ON public.smart_import_history;
CREATE POLICY "Admins manage import history"
  ON public.smart_import_history FOR ALL
  USING (
    (SELECT role FROM public.app_users WHERE id::TEXT = auth.uid()::TEXT) = 'super_admin'
    OR (
      (SELECT role FROM public.app_users WHERE id::TEXT = auth.uid()::TEXT) = 'admin'
      AND team_id = (SELECT team_id FROM public.app_users WHERE id::TEXT = auth.uid()::TEXT)
    )
  )
  WITH CHECK (
    (SELECT role FROM public.app_users WHERE id::TEXT = auth.uid()::TEXT) = 'super_admin'
    OR (
      (SELECT role FROM public.app_users WHERE id::TEXT = auth.uid()::TEXT) = 'admin'
      AND team_id = (SELECT team_id FROM public.app_users WHERE id::TEXT = auth.uid()::TEXT)
    )
  );
