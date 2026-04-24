-- ─────────────────────────────────────────────────────────────────────────
-- Grant admin + super_admin cross-team READ on the six billing tables.
--
-- Background:
--   20260424000005 widened the user-id match with an email fallback
--   (auth.jwt() ->> 'email') so legacy users whose app_users.id ≠ auth.uid
--   could still read their OWN team's rows. That fix works for reps but
--   leaves super_admin / admin pinned to app_users.team_id — when the
--   desktop Print Outstanding picks the other team, the RLS predicate
--   `team_id = <caller team>` evaluates false on every row and the PDF
--   is empty.
--
-- Fix: extend each SELECT policy with an OR branch that matches any
-- caller whose role is admin or super_admin. Two independent matchers:
-- `id::TEXT = auth.uid()::TEXT` and `email = jwt email`, so either path
-- is sufficient.
--
-- Scope: READ-only. The PART 2 write policies from 20260424000005
-- already check role = ('admin','super_admin') and are left alone.
--
-- IDEMPOTENT: DROP POLICY IF EXISTS before CREATE so this can safely
-- replay after staging.
-- ─────────────────────────────────────────────────────────────────────────


-- Tables covered: same six as 20260424000005.
--   customer_bills, customer_advances, customer_credit_notes,
--   customer_billed_items, customer_receipts, customer_receipt_bills


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
        AND role IN ('admin', 'super_admin')
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
        AND role IN ('admin', 'super_admin')
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
        AND role IN ('admin', 'super_admin')
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
        AND role IN ('admin', 'super_admin')
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
        AND role IN ('admin', 'super_admin')
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
        AND role IN ('admin', 'super_admin')
      LIMIT 1
    )
  );
