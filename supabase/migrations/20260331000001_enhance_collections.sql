-- ─────────────────────────────────────────────────────────────────────────────
-- Migration: Enhance collections table with full payment tracking schema
-- Backward-compatible: existing columns renamed with aliases, new columns added
-- ─────────────────────────────────────────────────────────────────────────────

-- 1. Add new columns (existing columns kept for backward compat)
ALTER TABLE collections
  ADD COLUMN IF NOT EXISTS collected_by    UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS collection_date DATE,
  ADD COLUMN IF NOT EXISTS payment_mode    TEXT DEFAULT 'Cash',   -- Cash/UPI/Cheque/Bank Transfer
  ADD COLUMN IF NOT EXISTS cheque_number   TEXT,
  ADD COLUMN IF NOT EXISTS upi_transaction_id TEXT,
  ADD COLUMN IF NOT EXISTS notes          TEXT DEFAULT '',
  ADD COLUMN IF NOT EXISTS bill_photo_url  TEXT,                  -- receipt photo URL
  ADD COLUMN IF NOT EXISTS outstanding_before NUMERIC(12,2) DEFAULT 0,
  ADD COLUMN IF NOT EXISTS outstanding_after  NUMERIC(12,2) DEFAULT 0,
  ADD COLUMN IF NOT EXISTS updated_at      TIMESTAMPTZ DEFAULT NOW();

-- 2. Migrate existing data: copy amount_paid → amount_collected alias not possible in PG
--    Instead, add amount_collected as alias alias column and backfill
ALTER TABLE collections
  ADD COLUMN IF NOT EXISTS amount_collected NUMERIC(12,2);

UPDATE collections
  SET amount_collected = amount_paid
  WHERE amount_collected IS NULL;

ALTER TABLE collections
  ALTER COLUMN amount_collected SET DEFAULT 0;

-- 3. Migrate payment_method → payment_mode (backfill)
UPDATE collections
  SET payment_mode = payment_method
  WHERE payment_mode = 'Cash' AND payment_method IS NOT NULL;

-- 4. Backfill collection_date from created_at for existing rows
UPDATE collections
  SET collection_date = created_at::DATE
  WHERE collection_date IS NULL;

-- 5. Backfill collected_by from rep_email lookup (best-effort)
UPDATE collections c
  SET collected_by = u.id
  FROM auth.users u
  WHERE u.email = c.rep_email
    AND c.collected_by IS NULL;

-- 6. Add updated_at trigger
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS set_collections_updated_at ON collections;
CREATE TRIGGER set_collections_updated_at
  BEFORE UPDATE ON collections
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- 7. Additional indexes for new query patterns
CREATE INDEX IF NOT EXISTS idx_collections_collected_by  ON collections(collected_by);
CREATE INDEX IF NOT EXISTS idx_collections_collection_date ON collections(collection_date DESC);
CREATE INDEX IF NOT EXISTS idx_collections_payment_mode  ON collections(payment_mode);

-- 8. RLS: team-isolated policy (replace open policy)
ALTER TABLE collections ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "collections_public"    ON collections;
DROP POLICY IF EXISTS "collections_team_iso"  ON collections;

CREATE POLICY "collections_team_iso" ON collections
  FOR ALL USING (
    team_id = (
      SELECT team_id FROM app_users WHERE id = auth.uid()::TEXT
    )
  );

-- Fallback for service-role (admin operations)
DROP POLICY IF EXISTS "collections_service_role" ON collections;
CREATE POLICY "collections_service_role" ON collections
  FOR ALL TO service_role USING (true) WITH CHECK (true);
