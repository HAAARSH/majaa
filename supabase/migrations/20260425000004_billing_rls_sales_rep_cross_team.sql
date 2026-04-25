-- ─────────────────────────────────────────────────────────────────────────
-- Extend cross-team READ on the six billing tables to sales_rep.
--
-- Background:
--   20260424000006_billing_rls_admin_cross_team.sql widened cross-team
--   reads to admin/super_admin so the desktop Print Outstanding could
--   pull the other team's rows. Sales reps were intentionally left
--   pinned to their own team_id — but that breaks shared-beat print:
--
--     3–4 reps run the same weekday beat across both JA & MA (see the
--     "Shared Beat Special Cases" memo). Tomorrow's outstanding sheet
--     spans both teams. beat_selection_screen.dart auto-detects this
--     (_nextDayCrossTeamId) and calls getCustomerBillsForTeam(teamId:
--     <other team>) for cross-team bills/advances/CNs. Under the
--     current RLS the predicate `team_id = caller_team` evaluates false
--     and the call returns 0 rows — the printed PDF has bills for the
--     rep's own team only, the other team's section is empty.
--
--   User-visible symptom: "MA rep can't print JA outstanding and vice
--   versa" on the Next Day Due tab.
--
-- Fix: add 'sales_rep' to the role allowlist alongside admin/super_admin
-- on the SELECT policies for the six billing tables. Customers themselves
-- are already readable cross-team via public_read_customers (core schema
-- 20260323072756), so this aligns billing visibility with the existing
-- customer visibility model.
--
-- Scope: READ-only. WRITE policies (PART 2 of 20260424000005) still
-- restrict admin/super_admin and are not touched. Sales reps cannot
-- INSERT/UPDATE other-team billing rows.
--
-- IDEMPOTENT: DROP POLICY IF EXISTS before each CREATE.
-- AUTHORITATIVE — supersedes 20260424000006 for these six tables.
-- ─────────────────────────────────────────────────────────────────────────


-- customer_bills
DROP POLICY IF EXISTS "Team members read customer_bills" ON public.customer_bills;
CREATE POLICY "Team members read customer_bills"
  ON public.customer_bills FOR SELECT
  USING (
    team_id = (
      SELECT team_id FROM public.app_users
      WHERE id::TEXT = auth.uid()::TEXT
         OR email = (auth.jwt() ->> 'email')
      LIMIT 1
    )
    OR EXISTS (
      SELECT 1 FROM public.app_users
      WHERE (id::TEXT = auth.uid()::TEXT OR email = (auth.jwt() ->> 'email'))
        AND role IN ('admin', 'super_admin', 'sales_rep')
      LIMIT 1
    )
  );

-- customer_advances
DROP POLICY IF EXISTS "Team members read customer_advances" ON public.customer_advances;
CREATE POLICY "Team members read customer_advances"
  ON public.customer_advances FOR SELECT
  USING (
    team_id = (
      SELECT team_id FROM public.app_users
      WHERE id::TEXT = auth.uid()::TEXT
         OR email = (auth.jwt() ->> 'email')
      LIMIT 1
    )
    OR EXISTS (
      SELECT 1 FROM public.app_users
      WHERE (id::TEXT = auth.uid()::TEXT OR email = (auth.jwt() ->> 'email'))
        AND role IN ('admin', 'super_admin', 'sales_rep')
      LIMIT 1
    )
  );

-- customer_credit_notes
DROP POLICY IF EXISTS "Team members read customer_credit_notes" ON public.customer_credit_notes;
CREATE POLICY "Team members read customer_credit_notes"
  ON public.customer_credit_notes FOR SELECT
  USING (
    team_id = (
      SELECT team_id FROM public.app_users
      WHERE id::TEXT = auth.uid()::TEXT
         OR email = (auth.jwt() ->> 'email')
      LIMIT 1
    )
    OR EXISTS (
      SELECT 1 FROM public.app_users
      WHERE (id::TEXT = auth.uid()::TEXT OR email = (auth.jwt() ->> 'email'))
        AND role IN ('admin', 'super_admin', 'sales_rep')
      LIMIT 1
    )
  );

-- customer_billed_items
DROP POLICY IF EXISTS "Team members read customer_billed_items" ON public.customer_billed_items;
CREATE POLICY "Team members read customer_billed_items"
  ON public.customer_billed_items FOR SELECT
  USING (
    team_id = (
      SELECT team_id FROM public.app_users
      WHERE id::TEXT = auth.uid()::TEXT
         OR email = (auth.jwt() ->> 'email')
      LIMIT 1
    )
    OR EXISTS (
      SELECT 1 FROM public.app_users
      WHERE (id::TEXT = auth.uid()::TEXT OR email = (auth.jwt() ->> 'email'))
        AND role IN ('admin', 'super_admin', 'sales_rep')
      LIMIT 1
    )
  );

-- customer_receipts
DROP POLICY IF EXISTS "Team members read customer_receipts" ON public.customer_receipts;
CREATE POLICY "Team members read customer_receipts"
  ON public.customer_receipts FOR SELECT
  USING (
    team_id = (
      SELECT team_id FROM public.app_users
      WHERE id::TEXT = auth.uid()::TEXT
         OR email = (auth.jwt() ->> 'email')
      LIMIT 1
    )
    OR EXISTS (
      SELECT 1 FROM public.app_users
      WHERE (id::TEXT = auth.uid()::TEXT OR email = (auth.jwt() ->> 'email'))
        AND role IN ('admin', 'super_admin', 'sales_rep')
      LIMIT 1
    )
  );

-- customer_receipt_bills
DROP POLICY IF EXISTS "Team members read customer_receipt_bills" ON public.customer_receipt_bills;
CREATE POLICY "Team members read customer_receipt_bills"
  ON public.customer_receipt_bills FOR SELECT
  USING (
    team_id = (
      SELECT team_id FROM public.app_users
      WHERE id::TEXT = auth.uid()::TEXT
         OR email = (auth.jwt() ->> 'email')
      LIMIT 1
    )
    OR EXISTS (
      SELECT 1 FROM public.app_users
      WHERE (id::TEXT = auth.uid()::TEXT OR email = (auth.jwt() ->> 'email'))
        AND role IN ('admin', 'super_admin', 'sales_rep')
      LIMIT 1
    )
  );
