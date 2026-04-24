-- ─────────────────────────────────────────────────────────────────────────
-- Fix RLS for users whose app_users.id ≠ auth.uid().
--
-- BACKGROUND
-- ----------
-- Six billing tables (customer_bills + 5 siblings, created in
-- 20260423000006_phase_b_tables_catchup) plus billing_rules / Smart-Import
-- tables gate access on `app_users.id::TEXT = auth.uid()::TEXT`. Early
-- users imported before the auth-uid linkage was enforced have rows where
-- the two IDs differ — e.g. ranjeet@majaa.com has app_users.id
-- `c2daf66d-816c-4411-8c87-cb961bb60cb4` and auth.uid()
-- `958f9ea4-c98f-41ee-b533-fb54b1323f8f`. For those users the RLS
-- subquery returns NULL, every `team_id = NULL` test is false, and:
--   • SELECT policies → silently return zero rows (Print Outstanding empty)
--   • WRITE  policies → silently reject every INSERT/UPDATE
--                       (legacy admin's OPNBIL "succeeds" but table stays empty)
--
-- The Dart side already routes around this with `_resolveAppUserId`
-- (lib/services/supabase_service.dart:56) — direct id, then email fallback.
-- This migration teaches every affected RLS policy to do the same:
--   `id::TEXT = auth.uid()::TEXT OR email = (auth.jwt() ->> 'email')`
--
-- `email` is UNIQUE on app_users (idx_app_users_email — see
-- 20260323101500_app_users.sql), so the OR can match at most one row.
-- LIMIT 1 added defensively.
--
-- IDEMPOTENT — DROP POLICY IF EXISTS before each CREATE.
-- AUTHORATIVE — supersedes the original definitions in:
--   • 20260423000003_billing_rules.sql
--   • 20260423000004a_smart_import_rls_super_admin_cross_team.sql
--   • 20260423000006_phase_b_tables_catchup.sql
-- ─────────────────────────────────────────────────────────────────────────


-- ═════════════════════════════════════════════════════════════════════════
-- PART 1 — Six billing tables: SELECT (READ) policies
-- Affects every team member; without this fix legacy reps see empty
-- Outstanding / Settle / Statement / Billed.
-- ═════════════════════════════════════════════════════════════════════════

-- customer_bills
DROP POLICY IF EXISTS "Team members read customer_bills" ON public.customer_bills;
CREATE POLICY "Team members read customer_bills"
  ON public.customer_bills FOR SELECT
  USING (team_id = (
    SELECT team_id FROM public.app_users
    WHERE id::TEXT = auth.uid()::TEXT
       OR email = (auth.jwt() ->> 'email')
    LIMIT 1
  ));

-- customer_advances
DROP POLICY IF EXISTS "Team members read customer_advances" ON public.customer_advances;
CREATE POLICY "Team members read customer_advances"
  ON public.customer_advances FOR SELECT
  USING (team_id = (
    SELECT team_id FROM public.app_users
    WHERE id::TEXT = auth.uid()::TEXT
       OR email = (auth.jwt() ->> 'email')
    LIMIT 1
  ));

-- customer_credit_notes
DROP POLICY IF EXISTS "Team members read customer_credit_notes" ON public.customer_credit_notes;
CREATE POLICY "Team members read customer_credit_notes"
  ON public.customer_credit_notes FOR SELECT
  USING (team_id = (
    SELECT team_id FROM public.app_users
    WHERE id::TEXT = auth.uid()::TEXT
       OR email = (auth.jwt() ->> 'email')
    LIMIT 1
  ));

-- customer_billed_items
DROP POLICY IF EXISTS "Team members read customer_billed_items" ON public.customer_billed_items;
CREATE POLICY "Team members read customer_billed_items"
  ON public.customer_billed_items FOR SELECT
  USING (team_id = (
    SELECT team_id FROM public.app_users
    WHERE id::TEXT = auth.uid()::TEXT
       OR email = (auth.jwt() ->> 'email')
    LIMIT 1
  ));

-- customer_receipts
DROP POLICY IF EXISTS "Team members read customer_receipts" ON public.customer_receipts;
CREATE POLICY "Team members read customer_receipts"
  ON public.customer_receipts FOR SELECT
  USING (team_id = (
    SELECT team_id FROM public.app_users
    WHERE id::TEXT = auth.uid()::TEXT
       OR email = (auth.jwt() ->> 'email')
    LIMIT 1
  ));

-- customer_receipt_bills
DROP POLICY IF EXISTS "Team members read customer_receipt_bills" ON public.customer_receipt_bills;
CREATE POLICY "Team members read customer_receipt_bills"
  ON public.customer_receipt_bills FOR SELECT
  USING (team_id = (
    SELECT team_id FROM public.app_users
    WHERE id::TEXT = auth.uid()::TEXT
       OR email = (auth.jwt() ->> 'email')
    LIMIT 1
  ));


-- ═════════════════════════════════════════════════════════════════════════
-- PART 2 — Six billing tables: WRITE (admin) policies
-- Affects every Drive-sync run by a legacy admin/super_admin (e.g.
-- sa@gmail.com). Without this fix OPNBIL/INV/CRN/ADV upserts are silently
-- 0-affected — the table stays empty even though the sync log says "done".
-- ═════════════════════════════════════════════════════════════════════════

-- customer_bills (write)
DROP POLICY IF EXISTS "Admins write customer_bills" ON public.customer_bills;
CREATE POLICY "Admins write customer_bills"
  ON public.customer_bills FOR ALL
  USING (
    (SELECT role FROM public.app_users
     WHERE id::TEXT = auth.uid()::TEXT
        OR email = (auth.jwt() ->> 'email')
     LIMIT 1) IN ('admin', 'super_admin')
  )
  WITH CHECK (
    (SELECT role FROM public.app_users
     WHERE id::TEXT = auth.uid()::TEXT
        OR email = (auth.jwt() ->> 'email')
     LIMIT 1) IN ('admin', 'super_admin')
  );

-- customer_advances (write)
DROP POLICY IF EXISTS "Admins write customer_advances" ON public.customer_advances;
CREATE POLICY "Admins write customer_advances"
  ON public.customer_advances FOR ALL
  USING (
    (SELECT role FROM public.app_users
     WHERE id::TEXT = auth.uid()::TEXT
        OR email = (auth.jwt() ->> 'email')
     LIMIT 1) IN ('admin', 'super_admin')
  )
  WITH CHECK (
    (SELECT role FROM public.app_users
     WHERE id::TEXT = auth.uid()::TEXT
        OR email = (auth.jwt() ->> 'email')
     LIMIT 1) IN ('admin', 'super_admin')
  );

-- customer_credit_notes (write)
DROP POLICY IF EXISTS "Admins write customer_credit_notes" ON public.customer_credit_notes;
CREATE POLICY "Admins write customer_credit_notes"
  ON public.customer_credit_notes FOR ALL
  USING (
    (SELECT role FROM public.app_users
     WHERE id::TEXT = auth.uid()::TEXT
        OR email = (auth.jwt() ->> 'email')
     LIMIT 1) IN ('admin', 'super_admin')
  )
  WITH CHECK (
    (SELECT role FROM public.app_users
     WHERE id::TEXT = auth.uid()::TEXT
        OR email = (auth.jwt() ->> 'email')
     LIMIT 1) IN ('admin', 'super_admin')
  );

-- customer_billed_items (write)
DROP POLICY IF EXISTS "Admins write customer_billed_items" ON public.customer_billed_items;
CREATE POLICY "Admins write customer_billed_items"
  ON public.customer_billed_items FOR ALL
  USING (
    (SELECT role FROM public.app_users
     WHERE id::TEXT = auth.uid()::TEXT
        OR email = (auth.jwt() ->> 'email')
     LIMIT 1) IN ('admin', 'super_admin')
  )
  WITH CHECK (
    (SELECT role FROM public.app_users
     WHERE id::TEXT = auth.uid()::TEXT
        OR email = (auth.jwt() ->> 'email')
     LIMIT 1) IN ('admin', 'super_admin')
  );

-- customer_receipts (write)
DROP POLICY IF EXISTS "Admins write customer_receipts" ON public.customer_receipts;
CREATE POLICY "Admins write customer_receipts"
  ON public.customer_receipts FOR ALL
  USING (
    (SELECT role FROM public.app_users
     WHERE id::TEXT = auth.uid()::TEXT
        OR email = (auth.jwt() ->> 'email')
     LIMIT 1) IN ('admin', 'super_admin')
  )
  WITH CHECK (
    (SELECT role FROM public.app_users
     WHERE id::TEXT = auth.uid()::TEXT
        OR email = (auth.jwt() ->> 'email')
     LIMIT 1) IN ('admin', 'super_admin')
  );

-- customer_receipt_bills (write)
DROP POLICY IF EXISTS "Admins write customer_receipt_bills" ON public.customer_receipt_bills;
CREATE POLICY "Admins write customer_receipt_bills"
  ON public.customer_receipt_bills FOR ALL
  USING (
    (SELECT role FROM public.app_users
     WHERE id::TEXT = auth.uid()::TEXT
        OR email = (auth.jwt() ->> 'email')
     LIMIT 1) IN ('admin', 'super_admin')
  )
  WITH CHECK (
    (SELECT role FROM public.app_users
     WHERE id::TEXT = auth.uid()::TEXT
        OR email = (auth.jwt() ->> 'email')
     LIMIT 1) IN ('admin', 'super_admin')
  );


-- ═════════════════════════════════════════════════════════════════════════
-- PART 3 — billing_rules + audit log
-- ═════════════════════════════════════════════════════════════════════════

-- billing_rules WRITE (super_admin only) — without this, legacy super_admin
-- (e.g. sa@gmail.com) cannot toggle any rule from the admin Rules tab.
DROP POLICY IF EXISTS "Super admins write billing rules" ON public.billing_rules;
CREATE POLICY "Super admins write billing rules"
  ON public.billing_rules FOR ALL
  USING (
    (SELECT role FROM public.app_users
     WHERE id::TEXT = auth.uid()::TEXT
        OR email = (auth.jwt() ->> 'email')
     LIMIT 1) = 'super_admin'
  )
  WITH CHECK (
    (SELECT role FROM public.app_users
     WHERE id::TEXT = auth.uid()::TEXT
        OR email = (auth.jwt() ->> 'email')
     LIMIT 1) = 'super_admin'
  );

-- billing_rules_audit_log READ — legacy admin sees empty audit otherwise.
DROP POLICY IF EXISTS "Admins read billing rules audit" ON public.billing_rules_audit_log;
CREATE POLICY "Admins read billing rules audit"
  ON public.billing_rules_audit_log FOR SELECT
  USING (
    (SELECT role FROM public.app_users
     WHERE id::TEXT = auth.uid()::TEXT
        OR email = (auth.jwt() ->> 'email')
     LIMIT 1) IN ('admin', 'super_admin')
  );


-- ═════════════════════════════════════════════════════════════════════════
-- PART 4 — Smart Import tables (super_admin cross-team variant from 004a)
-- Without this, legacy admin/super_admin's alias writes + import history
-- INSERTs silently fail.
-- ═════════════════════════════════════════════════════════════════════════

-- product_alias_learning
DROP POLICY IF EXISTS "Admins manage product aliases" ON public.product_alias_learning;
CREATE POLICY "Admins manage product aliases"
  ON public.product_alias_learning FOR ALL
  USING (
    (SELECT role FROM public.app_users
     WHERE id::TEXT = auth.uid()::TEXT
        OR email = (auth.jwt() ->> 'email')
     LIMIT 1) = 'super_admin'
    OR (
      (SELECT role FROM public.app_users
       WHERE id::TEXT = auth.uid()::TEXT
          OR email = (auth.jwt() ->> 'email')
       LIMIT 1) = 'admin'
      AND team_id = (SELECT team_id FROM public.app_users
                     WHERE id::TEXT = auth.uid()::TEXT
                        OR email = (auth.jwt() ->> 'email')
                     LIMIT 1)
    )
  )
  WITH CHECK (
    (SELECT role FROM public.app_users
     WHERE id::TEXT = auth.uid()::TEXT
        OR email = (auth.jwt() ->> 'email')
     LIMIT 1) = 'super_admin'
    OR (
      (SELECT role FROM public.app_users
       WHERE id::TEXT = auth.uid()::TEXT
          OR email = (auth.jwt() ->> 'email')
       LIMIT 1) = 'admin'
      AND team_id = (SELECT team_id FROM public.app_users
                     WHERE id::TEXT = auth.uid()::TEXT
                        OR email = (auth.jwt() ->> 'email')
                     LIMIT 1)
    )
  );

-- customer_alias_learning
DROP POLICY IF EXISTS "Admins manage customer aliases" ON public.customer_alias_learning;
CREATE POLICY "Admins manage customer aliases"
  ON public.customer_alias_learning FOR ALL
  USING (
    (SELECT role FROM public.app_users
     WHERE id::TEXT = auth.uid()::TEXT
        OR email = (auth.jwt() ->> 'email')
     LIMIT 1) = 'super_admin'
    OR (
      (SELECT role FROM public.app_users
       WHERE id::TEXT = auth.uid()::TEXT
          OR email = (auth.jwt() ->> 'email')
       LIMIT 1) = 'admin'
      AND team_id = (SELECT team_id FROM public.app_users
                     WHERE id::TEXT = auth.uid()::TEXT
                        OR email = (auth.jwt() ->> 'email')
                     LIMIT 1)
    )
  )
  WITH CHECK (
    (SELECT role FROM public.app_users
     WHERE id::TEXT = auth.uid()::TEXT
        OR email = (auth.jwt() ->> 'email')
     LIMIT 1) = 'super_admin'
    OR (
      (SELECT role FROM public.app_users
       WHERE id::TEXT = auth.uid()::TEXT
          OR email = (auth.jwt() ->> 'email')
       LIMIT 1) = 'admin'
      AND team_id = (SELECT team_id FROM public.app_users
                     WHERE id::TEXT = auth.uid()::TEXT
                        OR email = (auth.jwt() ->> 'email')
                     LIMIT 1)
    )
  );

-- smart_import_history
DROP POLICY IF EXISTS "Admins manage import history" ON public.smart_import_history;
CREATE POLICY "Admins manage import history"
  ON public.smart_import_history FOR ALL
  USING (
    (SELECT role FROM public.app_users
     WHERE id::TEXT = auth.uid()::TEXT
        OR email = (auth.jwt() ->> 'email')
     LIMIT 1) = 'super_admin'
    OR (
      (SELECT role FROM public.app_users
       WHERE id::TEXT = auth.uid()::TEXT
          OR email = (auth.jwt() ->> 'email')
       LIMIT 1) = 'admin'
      AND team_id = (SELECT team_id FROM public.app_users
                     WHERE id::TEXT = auth.uid()::TEXT
                        OR email = (auth.jwt() ->> 'email')
                     LIMIT 1)
    )
  )
  WITH CHECK (
    (SELECT role FROM public.app_users
     WHERE id::TEXT = auth.uid()::TEXT
        OR email = (auth.jwt() ->> 'email')
     LIMIT 1) = 'super_admin'
    OR (
      (SELECT role FROM public.app_users
       WHERE id::TEXT = auth.uid()::TEXT
          OR email = (auth.jwt() ->> 'email')
       LIMIT 1) = 'admin'
      AND team_id = (SELECT team_id FROM public.app_users
                     WHERE id::TEXT = auth.uid()::TEXT
                        OR email = (auth.jwt() ->> 'email')
                     LIMIT 1)
    )
  );
