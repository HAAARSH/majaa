-- Add billing_name (local software item name) and print_name (invoice print name) to products
ALTER TABLE products ADD COLUMN IF NOT EXISTS billing_name TEXT;
ALTER TABLE products ADD COLUMN IF NOT EXISTS print_name TEXT;

-- Index for matching
CREATE INDEX IF NOT EXISTS idx_products_billing_name ON products(billing_name, team_id);
CREATE INDEX IF NOT EXISTS idx_products_print_name ON products(print_name, team_id);
