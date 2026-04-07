-- ─────────────────────────────────────────────────────────────────────────────
-- Migration: Enhance visit_logs table with full field-rep visit tracking
-- Adds GPS, check-in/out, order & collection linkage, photo URL
-- ─────────────────────────────────────────────────────────────────────────────

-- 1. Add new columns (existing: id, customer_id, beat_id, reason, rep_email, team_id, created_at)
ALTER TABLE visit_logs
  -- Fields already written by Flutter app (add if not present)
  ADD COLUMN IF NOT EXISTS user_id         UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS visit_date      DATE,
  ADD COLUMN IF NOT EXISTS visit_time      TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS notes           TEXT DEFAULT '',
  -- New fields
  ADD COLUMN IF NOT EXISTS visit_purpose   TEXT DEFAULT 'sales_call', -- sales_call/delivery/collection/complaint
  ADD COLUMN IF NOT EXISTS check_in_time   TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS check_out_time  TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS latitude        DOUBLE PRECISION,
  ADD COLUMN IF NOT EXISTS longitude       DOUBLE PRECISION,
  ADD COLUMN IF NOT EXISTS order_placed    BOOLEAN DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS order_id        TEXT REFERENCES orders(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS collection_done BOOLEAN DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS collection_id   UUID REFERENCES collections(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS visit_photo_url TEXT,
  ADD COLUMN IF NOT EXISTS updated_at      TIMESTAMPTZ DEFAULT NOW();

-- 2. Migrate existing reason → visit_purpose where purpose not yet set
UPDATE visit_logs
  SET visit_purpose = reason
  WHERE visit_purpose = 'sales_call' AND reason IS NOT NULL AND reason != '';

-- 3. Backfill visit_date from created_at for existing rows
UPDATE visit_logs
  SET visit_date = created_at::DATE
  WHERE visit_date IS NULL;

-- 4. Updated_at trigger
DROP TRIGGER IF EXISTS set_visit_logs_updated_at ON visit_logs;
CREATE TRIGGER set_visit_logs_updated_at
  BEFORE UPDATE ON visit_logs
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- 5. Additional indexes
CREATE INDEX IF NOT EXISTS idx_visit_logs_user_id      ON visit_logs(user_id);
CREATE INDEX IF NOT EXISTS idx_visit_logs_visit_date   ON visit_logs(visit_date DESC);
CREATE INDEX IF NOT EXISTS idx_visit_logs_customer_id  ON visit_logs(customer_id);
CREATE INDEX IF NOT EXISTS idx_visit_logs_order_placed ON visit_logs(order_placed) WHERE order_placed = TRUE;

-- 6. RLS: team-isolated policy
ALTER TABLE visit_logs ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "visit_logs_public"      ON visit_logs;
DROP POLICY IF EXISTS "visit_logs_team_iso"    ON visit_logs;

CREATE POLICY "visit_logs_team_iso" ON visit_logs
  FOR ALL USING (
    team_id = (
      SELECT team_id FROM app_users WHERE id = auth.uid()::TEXT
    )
  );

DROP POLICY IF EXISTS "visit_logs_service_role" ON visit_logs;
CREATE POLICY "visit_logs_service_role" ON visit_logs
  FOR ALL TO service_role USING (true) WITH CHECK (true);
