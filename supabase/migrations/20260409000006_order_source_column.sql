-- Add source column to orders to distinguish app orders from office-billed
-- 'app' = created by sales rep, 'office' = auto-created from ITTR billing data
ALTER TABLE orders ADD COLUMN IF NOT EXISTS source TEXT DEFAULT 'app';
