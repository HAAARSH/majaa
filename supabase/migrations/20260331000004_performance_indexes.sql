-- ─────────────────────────────────────────────────────────────────────────────
-- Performance Indexes — For 2500+ products and 1200+ customers per team
-- ─────────────────────────────────────────────────────────────────────────────

-- ── PRODUCTS ──────────────────────────────────────────────────────────────────
-- Main catalog query: team + status filter + name ordering
CREATE INDEX IF NOT EXISTS idx_products_team_status
  ON products(team_id, status) WHERE status != 'discontinued';

-- Category browsing (most common query)
CREATE INDEX IF NOT EXISTS idx_products_team_category
  ON products(team_id, category);

-- Subcategory filter
CREATE INDEX IF NOT EXISTS idx_products_team_subcategory
  ON products(team_id, subcategory_id) WHERE subcategory_id IS NOT NULL;

-- Search by name (ilike — full-text GIN index for better performance)
CREATE INDEX IF NOT EXISTS idx_products_name_gin
  ON products USING GIN (to_tsvector('english', name));

-- SKU lookup
CREATE INDEX IF NOT EXISTS idx_products_sku ON products(sku);

-- ── CUSTOMERS ─────────────────────────────────────────────────────────────────
-- Beat-filtered customer list (most common query for sales reps)
CREATE INDEX IF NOT EXISTS idx_customers_team_beat_ja
  ON customers(team_id, beat_ja_id) WHERE beat_ja_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_customers_team_beat_ma
  ON customers(team_id, beat_ma_id) WHERE beat_ma_id IS NOT NULL;

-- Legacy beat_id (still used in queries)
CREATE INDEX IF NOT EXISTS idx_customers_team_beat_id
  ON customers(team_id, beat_id) WHERE beat_id IS NOT NULL;

-- Customer name search
CREATE INDEX IF NOT EXISTS idx_customers_name_gin
  ON customers USING GIN (to_tsvector('simple', name));

-- Outstanding balance queries (collections dashboard)
CREATE INDEX IF NOT EXISTS idx_customers_outstanding_ja
  ON customers(team_id, outstanding_ja DESC) WHERE outstanding_ja > 0;

-- ── ORDERS ───────────────────────────────────────────────────────────────────
-- Daily order query (order_date range + team)
CREATE INDEX IF NOT EXISTS idx_orders_team_date
  ON orders(team_id, order_date DESC);

-- Customer order history
CREATE INDEX IF NOT EXISTS idx_orders_customer_team
  ON orders(customer_id, team_id, order_date DESC);

-- Status filter (delivery dashboard: Pending orders)
CREATE INDEX IF NOT EXISTS idx_orders_team_status
  ON orders(team_id, status) WHERE status IN ('Pending', 'Confirmed');

-- User's own orders
CREATE INDEX IF NOT EXISTS idx_orders_user_team
  ON orders(user_id, team_id, order_date DESC);

-- Bill verification queries
CREATE INDEX IF NOT EXISTS idx_orders_bill_verification
  ON orders(team_id, verified_by_delivery, verified_by_office)
  WHERE verified_by_delivery = FALSE OR verified_by_office = FALSE;

-- ── ORDER_ITEMS ───────────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_order_items_order_id
  ON order_items(order_id);

CREATE INDEX IF NOT EXISTS idx_order_items_product_id
  ON order_items(product_id) WHERE product_id IS NOT NULL;

-- ── VISIT_LOGS ────────────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_visit_logs_team_date
  ON visit_logs(team_id, visit_date DESC);

CREATE INDEX IF NOT EXISTS idx_visit_logs_customer_date
  ON visit_logs(customer_id, visit_date DESC);

-- ── COLLECTIONS ───────────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_collections_team_date
  ON collections(team_id, collection_date DESC);

CREATE INDEX IF NOT EXISTS idx_collections_customer_date
  ON collections(customer_id, collection_date DESC);

-- ── USER_BEATS ────────────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_user_beats_user_id  ON user_beats(user_id);
CREATE INDEX IF NOT EXISTS idx_user_beats_beat_id  ON user_beats(beat_id);

-- ── APP_USERS ─────────────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_app_users_team_role
  ON app_users(team_id, role) WHERE is_active = TRUE;

-- ── PRODUCT_CATEGORIES ───────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_product_categories_team
  ON product_categories(team_id, sort_order);

-- ── PRODUCT_SUBCATEGORIES ────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_subcategories_team_category
  ON product_subcategories(team_id, category_id, sort_order);
