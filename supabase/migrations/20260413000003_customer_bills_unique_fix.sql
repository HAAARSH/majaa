-- Fix: invoice numbers restart yearly, so same (invoice_no, book, team_id) can belong
-- to different customers across OPNBIL (old year) and INV (current year).
-- Add customer_id to the unique constraint to prevent overwrites.

-- Drop old constraint
ALTER TABLE customer_bills DROP CONSTRAINT IF EXISTS customer_bills_invoice_no_book_team_id_key;

-- Add new constraint with customer_id
ALTER TABLE customer_bills ADD CONSTRAINT customer_bills_cust_inv_book_team_key
  UNIQUE (customer_id, invoice_no, book, team_id);
