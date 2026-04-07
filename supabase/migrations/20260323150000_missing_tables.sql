-- ─────────────────────────────────────────────────────────────────────────────
-- Migration: Add missing tables and columns not covered by earlier migrations
-- ─────────────────────────────────────────────────────────────────────────────

-- ── 1. Extra columns on products ────────────────────────────────────────────
ALTER TABLE products
  ADD COLUMN IF NOT EXISTS gst_rate NUMERIC(5,4) DEFAULT 0.18,
  ADD COLUMN IF NOT EXISTS unit TEXT DEFAULT 'pcs',
  ADD COLUMN IF NOT EXISTS step_size INTEGER DEFAULT 1,
  ADD COLUMN IF NOT EXISTS team_id TEXT DEFAULT 'JA',
  ADD COLUMN IF NOT EXISTS semantic_label TEXT DEFAULT '';

-- ── 2. Extra columns on customers ────────────────────────────────────────────
ALTER TABLE customers
  ADD COLUMN IF NOT EXISTS delivery_route TEXT DEFAULT 'Unassigned',
  ADD COLUMN IF NOT EXISTS outstanding_balance NUMERIC(12,2) DEFAULT 0,
  ADD COLUMN IF NOT EXISTS team_id TEXT DEFAULT 'JA';

-- ── 3. Extra columns on beats ────────────────────────────────────────────────
ALTER TABLE beats
  ADD COLUMN IF NOT EXISTS team_id TEXT DEFAULT 'JA';

-- ── 4. Extra columns on orders ────────────────────────────────────────────────
ALTER TABLE orders
  ADD COLUMN IF NOT EXISTS user_id UUID REFERENCES auth.users(id),
  ADD COLUMN IF NOT EXISTS beat_name TEXT DEFAULT '',
  ADD COLUMN IF NOT EXISTS final_bill_no TEXT,
  ADD COLUMN IF NOT EXISTS actual_billed_amount NUMERIC(12,2),
  ADD COLUMN IF NOT EXISTS team_id TEXT DEFAULT 'JA';

-- ── 5. Extra columns on app_users ────────────────────────────────────────────
ALTER TABLE app_users
  ADD COLUMN IF NOT EXISTS team_id TEXT DEFAULT 'JA',
  ADD COLUMN IF NOT EXISTS upi_id TEXT DEFAULT '';

-- ── 6. collections table ─────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS collections (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  bill_no TEXT,
  customer_id TEXT REFERENCES customers(id),
  customer_name TEXT NOT NULL,
  amount_paid NUMERIC(12,2) NOT NULL DEFAULT 0,
  balance_remaining NUMERIC(12,2) NOT NULL DEFAULT 0,
  rep_email TEXT NOT NULL,
  payment_method TEXT DEFAULT 'Cash',
  drive_file_id TEXT,
  team_id TEXT NOT NULL DEFAULT 'JA',
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_collections_customer_id ON collections(customer_id);
CREATE INDEX IF NOT EXISTS idx_collections_team_id ON collections(team_id);
CREATE INDEX IF NOT EXISTS idx_collections_created_at ON collections(created_at DESC);

ALTER TABLE collections ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "collections_public" ON collections;
CREATE POLICY "collections_public" ON collections FOR ALL USING (true);

-- ── 7. visit_logs table ───────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS visit_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id TEXT REFERENCES customers(id),
  beat_id TEXT REFERENCES beats(id),
  reason TEXT NOT NULL,
  rep_email TEXT NOT NULL,
  team_id TEXT NOT NULL DEFAULT 'JA',
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_visit_logs_team_id ON visit_logs(team_id);
CREATE INDEX IF NOT EXISTS idx_visit_logs_beat_id ON visit_logs(beat_id);
CREATE INDEX IF NOT EXISTS idx_visit_logs_created_at ON visit_logs(created_at DESC);

ALTER TABLE visit_logs ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "visit_logs_public" ON visit_logs;
CREATE POLICY "visit_logs_public" ON visit_logs FOR ALL USING (true);

-- ── 8. app_settings table (for in-app update control) ────────────────────────
CREATE TABLE IF NOT EXISTS app_settings (
  id INTEGER PRIMARY KEY DEFAULT 1,
  latest_version TEXT NOT NULL DEFAULT '1.0.0',
  apk_download_url TEXT DEFAULT '',
  mandatory_update BOOLEAN DEFAULT FALSE,
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  CONSTRAINT single_row CHECK (id = 1)
);

ALTER TABLE app_settings ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "app_settings_public" ON app_settings;
CREATE POLICY "app_settings_public" ON app_settings FOR ALL USING (true);

-- Insert default row if not exists
INSERT INTO app_settings (id, latest_version, mandatory_update)
VALUES (1, '1.0.0', false)
ON CONFLICT (id) DO NOTHING;

-- ── 9. product_subcategories table ───────────────────────────────────────────
CREATE TABLE IF NOT EXISTS product_subcategories (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  category_id UUID REFERENCES product_categories(id) ON DELETE CASCADE,
  sort_order INTEGER DEFAULT 1,
  team_id TEXT NOT NULL DEFAULT 'JA',
  created_at TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE products
  ADD COLUMN IF NOT EXISTS subcategory_id UUID REFERENCES product_subcategories(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_product_subcategories_category ON product_subcategories(category_id);
CREATE INDEX IF NOT EXISTS idx_product_subcategories_team ON product_subcategories(team_id);
CREATE INDEX IF NOT EXISTS idx_products_subcategory ON products(subcategory_id);

ALTER TABLE product_subcategories ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "subcategories_public" ON product_subcategories;
CREATE POLICY "subcategories_public" ON product_subcategories FOR ALL USING (true);
