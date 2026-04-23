-- ─────────────────────────────────────────────────────────────────────────
-- Per-customer manual order block
--
-- Admin wants to freeze a specific customer's ability to accept new orders
-- at will — could be payment dispute, credit hold, legal hold, etc.
-- Blocks are per-TEAM (customer on JA blocked, same customer on MA still
-- open) because the two teams have different billing software and one
-- team's dispute shouldn't stop the other.
--
-- Stored on customer_team_profiles. A single profile row carries BOTH
-- team_ja + team_ma booleans today, but the order_blocked flag is one
-- value per row — which matches "one row per customer" — so to give
-- per-team block semantics we read team_ja / team_ma to decide WHICH
-- team the block applies to at write time. If the customer is on both
-- teams and admin wants to block only one, a second migration can add
-- order_blocked_ja / order_blocked_ma columns. For v1 the profile is
-- the team boundary: admin blocks the customer-on-that-team by
-- filtering the profile row via team_ja OR team_ma matching the active
-- team at write time.
--
-- Idempotent: ADD COLUMN IF NOT EXISTS. Re-run safe.
-- ─────────────────────────────────────────────────────────────────────────

ALTER TABLE public.customer_team_profiles
  ADD COLUMN IF NOT EXISTS order_blocked_ja       BOOLEAN     NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS order_blocked_ma       BOOLEAN     NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS order_block_reason_ja  TEXT,
  ADD COLUMN IF NOT EXISTS order_block_reason_ma  TEXT,
  ADD COLUMN IF NOT EXISTS order_block_set_at_ja  TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS order_block_set_at_ma  TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS order_block_set_by_ja  UUID REFERENCES public.app_users(id),
  ADD COLUMN IF NOT EXISTS order_block_set_by_ma  UUID REFERENCES public.app_users(id);

COMMENT ON COLUMN public.customer_team_profiles.order_blocked_ja IS
  'Admin-set manual block: when TRUE, reps on JA cannot create new orders for this customer regardless of outstanding / overdue state.';
COMMENT ON COLUMN public.customer_team_profiles.order_blocked_ma IS
  'Same as order_blocked_ja but for MA team.';

-- Partial indexes so "list all blocked customers for team X" is fast.
CREATE INDEX IF NOT EXISTS idx_ctp_blocked_ja
  ON public.customer_team_profiles(order_blocked_ja)
  WHERE order_blocked_ja = TRUE;

CREATE INDEX IF NOT EXISTS idx_ctp_blocked_ma
  ON public.customer_team_profiles(order_blocked_ma)
  WHERE order_blocked_ma = TRUE;
