-- ─────────────────────────────────────────────────────────────────────────
-- Rules Tab Phase 1.B — seed billing_rules with current behavior
--
-- Goal: app behaves identically the moment the engine starts reading from
-- this table. Every hardcoded rule listed in RULES_TAB_PLAN.md gets a row
-- here matching the current production logic.
--
-- Idempotency: ON CONFLICT … DO NOTHING (E2 in audit). Re-running this
-- migration is safe and won't stomp values an admin has since edited.
--
-- String quoting: Postgres uses doubled single-quotes; the original plan
-- had backslash-escaped apostrophes which is a syntax error under
-- standard_conforming_strings = on (E1 in audit).
--
-- Map keys for customer-type lookups are LOWERCASE because the Dart side
-- normalizes c.type.toLowerCase() before lookup. Current hardcoded code
-- is `c.type.toLowerCase() == ''pharmacy''` so we keep that contract here
-- (E6 in audit).
--
-- The audit trigger fires for these inserts and writes rows with NULL
-- changed_by_user_id (no auth context during a migration) — that's the
-- expected signal "seeded by migration, not by an admin."
-- ─────────────────────────────────────────────────────────────────────────

INSERT INTO public.billing_rules
  (category, rule_key, scope_type, scope_id, value, description)
VALUES
  -- Current JA behavior: split by rep role.
  -- Source: lib/presentation/admin_panel_screen/widgets/admin_orders_tab.dart
  --         line 371 — `if (role == ''brand_rep'')` branch.
  ('export', 'export_merging_strategy', 'team', 'JA',
   '"split_by_rep_role"'::jsonb,
   'How JA orders are grouped into invoices. split_by_rep_role: brand_rep merges per customer, sales_rep stays per-order. merge_all_by_customer: all orders merge per customer. no_merge: one invoice per order regardless.'),

  -- Pre-existing MA behavior. Currently MA also uses split_by_rep_role
  -- (the brand_rep/sales_rep code path is team-agnostic). The plan calls
  -- to flip MA to merge_all_by_customer in Phase 2 PR 2.3 — at that point
  -- the admin updates this row via the Rules Tab. Seed preserves today.
  ('export', 'export_merging_strategy', 'team', 'MA',
   '"split_by_rep_role"'::jsonb,
   'How MA orders are grouped into invoices. Same options as JA. Today MA mirrors JA; flip to merge_all_by_customer when ready.'),

  -- CSDS per-team toggle. Migrated from SharedPreferences keys
  --   csds_enabled_JA / csds_enabled_MA
  -- Read from at least 3 sites today (admin_pricing_tab, order_creation_screen,
  -- core/pricing.dart). Default false matches the SharedPreferences default
  -- and the kForcedOff kill-switch state.
  ('pricing', 'pricing_csds_enabled', 'team', 'JA',
   'false'::jsonb,
   'When ON, JA orders apply each customer''s DUA-synced discount cascade (D1→D3→D5) plus scheme free-goods. When OFF, MRP-only pricing applies.'),
  ('pricing', 'pricing_csds_enabled', 'team', 'MA',
   'false'::jsonb,
   'When ON, MA orders apply each customer''s DUA-synced discount cascade (D1→D3→D5) plus scheme free-goods. When OFF, MRP-only pricing applies.'),

  -- Organic India default routing by customer type.
  -- Source: lib/presentation/admin_panel_screen/widgets/admin_orders_tab.dart
  --         line 1382 — `c.type.toLowerCase() == ''pharmacy'' ? ''JA'' : ''MA''`.
  -- Keys are lowercase to match c.type.toLowerCase() lookup convention.
  -- _default is the fallback when c.type is NULL or unknown.
  ('routing', 'organic_india_default_by_customer_type', 'global', NULL,
   '{"pharmacy": "JA", "general trade": "MA", "modern trade": "MA", "wholesale": "MA", "horeca": "MA", "other": "MA", "_default": "MA"}'::jsonb,
   'Default billing team for Organic India items per customer type. Per-customer overrides live in customer_brand_routing and take precedence.')
ON CONFLICT DO NOTHING;

-- Mark the seed-origin audit rows so they're easy to filter out from real
-- admin activity when reviewing the audit log.
UPDATE public.billing_rules_audit_log
SET change_reason = 'initial seed (migration 20260423000004)'
WHERE change_reason IS NULL
  AND changed_by_user_id IS NULL
  AND change_type = 'create'
  AND rule_key IN (
    'export_merging_strategy',
    'pricing_csds_enabled',
    'organic_india_default_by_customer_type'
  );
