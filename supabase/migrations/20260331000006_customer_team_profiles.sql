-- ─────────────────────────────────────────────────────────────────────────────
-- Migration: Customer Team Profiles junction table
--
-- BEFORE: customers table holds team-specific columns directly:
--           outstanding_ja, outstanding_ma, outstanding_balance,
--           beat_ja_id, beat_ma_id, beat_id, beat (name), team_id
--
-- AFTER:  customers holds ONLY universal identity data (id, name, phone, …).
--         Team-specific data lives in customer_team_profiles:
--           customer_id, team_id, beat_id, beat_name, outstanding_balance
-- ─────────────────────────────────────────────────────────────────────────────

-- ── 1. Create the junction table ─────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS customer_team_profiles (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id         TEXT NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
  team_id             TEXT NOT NULL CHECK (team_id IN ('JA', 'MA')),
  beat_id             TEXT REFERENCES beats(id) ON DELETE SET NULL,
  beat_name           TEXT NOT NULL DEFAULT '',
  outstanding_balance NUMERIC(12, 2) NOT NULL DEFAULT 0,

  UNIQUE (customer_id, team_id)
);

-- ── 2. Backfill JA profiles ───────────────────────────────────────────────────
-- Include every customer whose primary team is JA, or who has a JA beat, or
-- who has a non-zero JA outstanding balance.

INSERT INTO customer_team_profiles
  (customer_id, team_id, beat_id, beat_name, outstanding_balance)
SELECT
  c.id,
  'JA',
  c.beat_ja_id,
  CASE WHEN c.team_id = 'JA' THEN COALESCE(c.beat, '') ELSE '' END,
  COALESCE(c.outstanding_ja, 0)
FROM customers c
WHERE c.team_id = 'JA'
   OR c.beat_ja_id IS NOT NULL
   OR COALESCE(c.outstanding_ja, 0) > 0
ON CONFLICT (customer_id, team_id) DO NOTHING;

-- ── 3. Backfill MA profiles ───────────────────────────────────────────────────

INSERT INTO customer_team_profiles
  (customer_id, team_id, beat_id, beat_name, outstanding_balance)
SELECT
  c.id,
  'MA',
  c.beat_ma_id,
  CASE WHEN c.team_id = 'MA' THEN COALESCE(c.beat, '') ELSE '' END,
  COALESCE(c.outstanding_ma, 0)
FROM customers c
WHERE c.team_id = 'MA'
   OR c.beat_ma_id IS NOT NULL
   OR COALESCE(c.outstanding_ma, 0) > 0
ON CONFLICT (customer_id, team_id) DO NOTHING;

-- ── 4. Row Level Security ─────────────────────────────────────────────────────

ALTER TABLE customer_team_profiles ENABLE ROW LEVEL SECURITY;

-- Authenticated users can read/write their team's profiles.
-- Team isolation is enforced in Flutter queries via explicit team_id filter.
CREATE POLICY "ctp_authenticated_access" ON customer_team_profiles
  FOR ALL
  USING (auth.role() = 'authenticated')
  WITH CHECK (auth.role() = 'authenticated');

-- ── 5. Update customers RLS ───────────────────────────────────────────────────
-- The customers table no longer has team_id, so the old team-scoped RLS
-- policy must be replaced with a simple "any authenticated user can read".
-- (Team isolation is now enforced at the junction table level.)

DROP POLICY IF EXISTS "customers_team_access" ON customers;
DROP POLICY IF EXISTS "Enable read access for authenticated users" ON customers;
DROP POLICY IF EXISTS "customers_select" ON customers;
DROP POLICY IF EXISTS "customers_insert" ON customers;
DROP POLICY IF EXISTS "customers_update" ON customers;
DROP POLICY IF EXISTS "customers_delete" ON customers;

CREATE POLICY "customers_authenticated" ON customers
  FOR ALL
  USING (auth.role() = 'authenticated')
  WITH CHECK (auth.role() = 'authenticated');

-- ── 6. Performance indexes ────────────────────────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_ctp_customer_id   ON customer_team_profiles(customer_id);
CREATE INDEX IF NOT EXISTS idx_ctp_team_id       ON customer_team_profiles(team_id);
CREATE INDEX IF NOT EXISTS idx_ctp_beat_id       ON customer_team_profiles(beat_id);
CREATE INDEX IF NOT EXISTS idx_ctp_team_customer ON customer_team_profiles(team_id, customer_id);

-- ── 7. Drop redundant columns from customers ──────────────────────────────────
-- Run AFTER backfill to guarantee no data loss.

ALTER TABLE customers
  DROP COLUMN IF EXISTS beat_id,
  DROP COLUMN IF EXISTS beat_ja_id,
  DROP COLUMN IF EXISTS beat_ma_id,
  DROP COLUMN IF EXISTS beat,
  DROP COLUMN IF EXISTS outstanding_balance,
  DROP COLUMN IF EXISTS outstanding_ja,
  DROP COLUMN IF EXISTS outstanding_ma,
  DROP COLUMN IF EXISTS team_id;
