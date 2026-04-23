-- ─────────────────────────────────────────────────────────────────────────
-- Rules Tab Phase 1.A — schema for the central billing_rules engine
--
-- Two tables:
--   1. billing_rules           — generic key-value-with-scope rule store
--   2. billing_rules_audit_log — every change captured automatically
--
-- One trigger function fn_log_billing_rule_change auto-populates the audit
-- log on INSERT / UPDATE / DELETE.
--
-- Convention notes (driven by past lessons in this project):
--   • app_users.id is UUID; auth.uid() returns UUID. Casting both sides to
--     TEXT in RLS sidesteps the "operator does not exist: uuid = text"
--     error seen across Supabase versions. See 20260423000002 migration.
--   • SECURITY DEFINER functions MUST set search_path = public to block
--     search-path hijacking. Same lesson as 20260423000002.
--   • UNIQUE on a nullable column treats NULL as distinct in Postgres.
--     For 'global'-scope rules (scope_id IS NULL) we use a partial unique
--     index so re-inserting the same global rule fails as expected.
-- ─────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.billing_rules (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  category TEXT NOT NULL,
    -- 'export' | 'routing' | 'pricing' | 'customer'
  rule_key TEXT NOT NULL,
    -- machine key, e.g. 'export_merging_strategy'
  scope_type TEXT NOT NULL DEFAULT 'global',
    -- 'global' | 'team' | 'customer' | 'brand'
  scope_id TEXT,
    -- NULL for global; team_id for team; customer_id for customer; brand for brand
  value JSONB NOT NULL,
    -- the actual configuration (bool, enum string, object, etc.)
  enabled BOOLEAN NOT NULL DEFAULT TRUE,
  description TEXT,
  last_edited_by_user_id UUID,
  last_edited_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- E3 fix: partial unique indexes — Postgres counts NULLs as distinct in a
-- plain UNIQUE, so a single (rule_key, scope_type, NULL) row can be
-- inserted unlimited times. Two partial indexes cover both cases.
CREATE UNIQUE INDEX IF NOT EXISTS uq_billing_rules_scoped
  ON public.billing_rules (rule_key, scope_type, scope_id)
  WHERE scope_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_billing_rules_global
  ON public.billing_rules (rule_key, scope_type)
  WHERE scope_id IS NULL;

CREATE INDEX IF NOT EXISTS idx_billing_rules_lookup
  ON public.billing_rules (rule_key, scope_type, scope_id);

CREATE INDEX IF NOT EXISTS idx_billing_rules_category
  ON public.billing_rules (category);

ALTER TABLE public.billing_rules ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "All authenticated users read billing rules" ON public.billing_rules;
CREATE POLICY "All authenticated users read billing rules"
  ON public.billing_rules FOR SELECT
  USING (auth.uid() IS NOT NULL);

DROP POLICY IF EXISTS "Super admins write billing rules" ON public.billing_rules;
CREATE POLICY "Super admins write billing rules"
  ON public.billing_rules FOR ALL
  USING (
    (SELECT role FROM public.app_users
       WHERE id::TEXT = auth.uid()::TEXT) = 'super_admin'
  )
  WITH CHECK (
    (SELECT role FROM public.app_users
       WHERE id::TEXT = auth.uid()::TEXT) = 'super_admin'
  );


CREATE TABLE IF NOT EXISTS public.billing_rules_audit_log (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  rule_id UUID,
    -- nullable: deleted rules still audit
  rule_key TEXT NOT NULL,
  scope_type TEXT NOT NULL,
  scope_id TEXT,
  old_value JSONB,
  new_value JSONB,
  change_type TEXT NOT NULL,
    -- 'create' | 'update' | 'enable' | 'disable' | 'delete' | 'seed'
  changed_by_user_id UUID,
  changed_by_name TEXT,
  change_reason TEXT,
  changed_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_rules_audit_rule_key
  ON public.billing_rules_audit_log (rule_key, changed_at DESC);

CREATE INDEX IF NOT EXISTS idx_rules_audit_by_user
  ON public.billing_rules_audit_log (changed_by_user_id, changed_at DESC);

ALTER TABLE public.billing_rules_audit_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admins read billing rules audit" ON public.billing_rules_audit_log;
CREATE POLICY "Admins read billing rules audit"
  ON public.billing_rules_audit_log FOR SELECT
  USING (
    (SELECT role FROM public.app_users
       WHERE id::TEXT = auth.uid()::TEXT) IN ('admin', 'super_admin')
  );


-- Trigger function. SECURITY DEFINER + locked search_path so it can write
-- to the audit table even when the caller's role can't, and so a
-- compromised search_path can't shadow app_users (E10 in audit).
CREATE OR REPLACE FUNCTION public.fn_log_billing_rule_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_name TEXT;
  v_change_type TEXT;
BEGIN
  -- auth.uid() is NULL during migrations / service-role writes; that's ok.
  -- The audit row simply records NULL user — useful signal that the change
  -- did not come from a real admin session.
  SELECT full_name INTO v_user_name
  FROM public.app_users
  WHERE id::TEXT = auth.uid()::TEXT;

  IF TG_OP = 'INSERT' THEN
    INSERT INTO public.billing_rules_audit_log
      (rule_id, rule_key, scope_type, scope_id, old_value, new_value,
       change_type, changed_by_user_id, changed_by_name)
    VALUES
      (NEW.id, NEW.rule_key, NEW.scope_type, NEW.scope_id,
       NULL, NEW.value, 'create', auth.uid(), v_user_name);
    RETURN NEW;

  ELSIF TG_OP = 'UPDATE' THEN
    -- Only audit if value or enabled actually changed. Bumping
    -- last_edited_at alone shouldn't flood the log.
    IF OLD.value IS DISTINCT FROM NEW.value
       OR OLD.enabled IS DISTINCT FROM NEW.enabled THEN
      v_change_type := CASE
        WHEN OLD.enabled = TRUE  AND NEW.enabled = FALSE THEN 'disable'
        WHEN OLD.enabled = FALSE AND NEW.enabled = TRUE  THEN 'enable'
        ELSE 'update'
      END;
      INSERT INTO public.billing_rules_audit_log
        (rule_id, rule_key, scope_type, scope_id, old_value, new_value,
         change_type, changed_by_user_id, changed_by_name)
      VALUES
        (NEW.id, NEW.rule_key, NEW.scope_type, NEW.scope_id,
         OLD.value, NEW.value,
         v_change_type, auth.uid(), v_user_name);
    END IF;
    RETURN NEW;

  ELSIF TG_OP = 'DELETE' THEN
    INSERT INTO public.billing_rules_audit_log
      (rule_id, rule_key, scope_type, scope_id, old_value, new_value,
       change_type, changed_by_user_id, changed_by_name)
    VALUES
      (OLD.id, OLD.rule_key, OLD.scope_type, OLD.scope_id,
       OLD.value, NULL, 'delete', auth.uid(), v_user_name);
    RETURN OLD;
  END IF;

  RETURN NULL;
END;
$$;

REVOKE ALL ON FUNCTION public.fn_log_billing_rule_change() FROM PUBLIC;

DROP TRIGGER IF EXISTS trg_billing_rules_audit ON public.billing_rules;
CREATE TRIGGER trg_billing_rules_audit
  AFTER INSERT OR UPDATE OR DELETE ON public.billing_rules
  FOR EACH ROW
  EXECUTE FUNCTION public.fn_log_billing_rule_change();
