-- Add salesman name column to customer_bills table
ALTER TABLE customer_bills ADD COLUMN IF NOT EXISTS sman_name TEXT DEFAULT '';
