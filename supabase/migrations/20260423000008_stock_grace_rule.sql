-- ─────────────────────────────────────────────────────────────────────────
-- billing_rules seed — stock_zero_grace_days
--
-- Makes the 2-day post-zero grace window admin-tunable from the Rules Tab
-- instead of hardcoding in Dart. Stored as a JSON number so the same
-- access pattern as every other rule works.
--
-- Global scope — one value for both teams (and both app versions —
-- majaa mobile + majaa_desktop). Splitting by team is easy later if
-- business wants.
--
-- Idempotent via ON CONFLICT DO NOTHING — running this migration after
-- the rule is already present keeps the admin's last-edited value.
-- ─────────────────────────────────────────────────────────────────────────

INSERT INTO public.billing_rules
  (category, rule_key, scope_type, scope_id, value, description)
VALUES
  ('pricing', 'stock_zero_grace_days', 'global', NULL,
   '2'::jsonb,
   'Whole days after a product''s stock first hits zero during which reps can still add it to cart. Set to 0 to disable the grace window (rep locked immediately on zero). Typical values: 1, 2, or 3.')
ON CONFLICT DO NOTHING;

-- Clean up any default audit-log row the trigger wrote for this insert.
UPDATE public.billing_rules_audit_log
SET change_reason = 'initial seed (migration 20260423000008)'
WHERE change_reason IS NULL
  AND changed_by_user_id IS NULL
  AND change_type = 'create'
  AND rule_key = 'stock_zero_grace_days';
