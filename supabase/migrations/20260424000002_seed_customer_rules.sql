-- ─────────────────────────────────────────────────────────────────────────
-- Seed 3 customer-category rules (6 rows — 3 rules × 2 teams).
--
-- All default to "disabled" (empty array / zero). Admin opts in via
-- Rules Tab. Per-team because JA and MA have different credit behaviour
-- and different cross-team legal entities.
--
-- ON CONFLICT DO NOTHING — safe to re-run; preserves admin edits.
-- ─────────────────────────────────────────────────────────────────────────

INSERT INTO public.billing_rules
  (category, rule_key, scope_type, scope_id, value, description)
VALUES
  -- 1. Customers whose orders should NEVER merge into a single brand_rep
  -- invoice at export. Their bills stay one-invoice-per-order regardless
  -- of the team's merging strategy. Empty array = no exclusions.
  ('customer', 'no_merge_customer_ids', 'team', 'JA',
   '[]'::jsonb,
   'Customer IDs on JA whose invoices must NEVER merge into a combined brand_rep invoice at export. Each of their orders stays one-invoice-per-order. Useful for customers that cross-check invoice-to-order 1:1 during reconciliation.'),
  ('customer', 'no_merge_customer_ids', 'team', 'MA',
   '[]'::jsonb,
   'Same as JA — customer IDs on MA that must not merge. Separate list because JA and MA can have different reconciliation needs.'),

  -- 2. Auto-block new orders when oldest unpaid bill is older than N days.
  -- 0 = disabled. Typical: 30, 45, 60. Evaluated at order-creation time.
  ('customer', 'auto_block_overdue_days', 'team', 'JA',
   '0'::jsonb,
   'When > 0, reps on JA cannot create new orders for a customer whose oldest unpaid bill is more than N days old. Set to 0 to disable. Threshold is inclusive — a bill 30 days old triggers the block when threshold = 30.'),
  ('customer', 'auto_block_overdue_days', 'team', 'MA',
   '0'::jsonb,
   'Same as JA — MA team''s overdue-days threshold. Teams can set different values.'),

  -- 3. Auto-block when a customer's outstanding balance exceeds this
  -- amount. 0 = disabled. Read from customer_team_profiles.outstanding_ja
  -- or .outstanding_ma depending on team.
  ('customer', 'auto_block_outstanding', 'team', 'JA',
   '0'::jsonb,
   'When > 0, reps on JA cannot create new orders for a customer whose outstanding_ja exceeds this rupee amount. Set to 0 to disable.'),
  ('customer', 'auto_block_outstanding', 'team', 'MA',
   '0'::jsonb,
   'Same as JA — MA team''s outstanding threshold.')
ON CONFLICT DO NOTHING;

-- Mark the audit rows the trigger just wrote so the "how did this rule
-- get here" picker can filter them out of real admin edits.
UPDATE public.billing_rules_audit_log
SET change_reason = 'initial seed (migration 20260424000002)'
WHERE change_reason IS NULL
  AND changed_by_user_id IS NULL
  AND change_type = 'create'
  AND rule_key IN (
    'no_merge_customer_ids',
    'auto_block_overdue_days',
    'auto_block_outstanding'
  );
