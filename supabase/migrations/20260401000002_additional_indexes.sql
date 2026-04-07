-- Additional indexes for customer_team_profiles and trigram search
-- ─────────────────────────────────────────────────────────────────────────────

-- Customer team profile lookups (used in collection balance updates)
CREATE INDEX IF NOT EXISTS idx_customer_team_profiles_composite
  ON customer_team_profiles(customer_id, team_id);

-- Outstanding balance queries on new junction table
CREATE INDEX IF NOT EXISTS idx_customer_team_profiles_outstanding
  ON customer_team_profiles(team_id, outstanding_balance DESC)
  WHERE outstanding_balance > 0;

-- Trigram index for fuzzy customer name search (requires pg_trgm extension)
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE INDEX IF NOT EXISTS idx_customers_name_trgm
  ON customers USING GIN (name gin_trgm_ops);

-- Trigram index for fuzzy product name search
CREATE INDEX IF NOT EXISTS idx_products_name_trgm
  ON products USING GIN (name gin_trgm_ops);
