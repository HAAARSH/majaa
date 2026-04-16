-- Add MRP column to order_items table
ALTER TABLE order_items ADD COLUMN IF NOT EXISTS mrp NUMERIC(12,2) DEFAULT 0;
