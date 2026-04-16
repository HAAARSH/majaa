-- Add separate MRP column to products (distinct from unit_price which is selling rate)
-- MRP = Maximum Retail Price from ITMRP CSV
-- unit_price = Selling rate (RATE column from ITMRP CSV)
ALTER TABLE products ADD COLUMN IF NOT EXISTS mrp NUMERIC(10,2) DEFAULT 0;

-- Backfill: set mrp = unit_price for existing products (they were the same before)
UPDATE products SET mrp = unit_price WHERE mrp = 0 AND unit_price > 0;
