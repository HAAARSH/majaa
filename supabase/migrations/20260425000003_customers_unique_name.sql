-- ─────────────────────────────────────────────────────────────────────────
-- DB-level guard: block duplicate customer names case/whitespace-insensitive.
--
-- Belt-and-braces against any sync path that forgets to dedup. After the
-- desktop ACMAST sync's stale-snapshot bug (2026-04-25) created ~15 dupes
-- per multi-team customer, we cleaned via dedupe_customers_2026_04_25.sql
-- and now lock the door so it can't recur.
--
-- Partial index ignores rows where name is empty (shouldn't exist; defensive).
-- Apply ONLY AFTER the dedup script's COMMIT — otherwise this CREATE will
-- fail with "could not create unique index" listing the dup rows.
-- ─────────────────────────────────────────────────────────────────────────

-- Wrapped in BEGIN/COMMIT so SET LOCAL is valid (it requires an explicit
-- transaction block — DBeaver and the Supabase dashboard both run in
-- auto-commit mode by default, where SET LOCAL errors out).
BEGIN;

-- Supabase dashboard SQL editor enforces a ~8s statement_timeout. The
-- index build does a full table scan; on a non-trivial customers table
-- that can overrun. SET LOCAL only affects this transaction, restored
-- at COMMIT below.
SET LOCAL statement_timeout = 0;

CREATE UNIQUE INDEX IF NOT EXISTS uq_customers_name_lower
  ON public.customers (LOWER(TRIM(name)))
  WHERE name IS NOT NULL AND TRIM(name) <> '';

COMMIT;
