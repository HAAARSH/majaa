-- Add credit_notes and current_year_billed columns to customer_team_profiles
-- Used to detect real discrepancies between ledger and bill-level outstanding
ALTER TABLE customer_team_profiles
  ADD COLUMN IF NOT EXISTS credit_notes_ja NUMERIC(12,2) DEFAULT 0,
  ADD COLUMN IF NOT EXISTS credit_notes_ma NUMERIC(12,2) DEFAULT 0,
  ADD COLUMN IF NOT EXISTS current_year_billed_ja NUMERIC(12,2) DEFAULT 0,
  ADD COLUMN IF NOT EXISTS current_year_billed_ma NUMERIC(12,2) DEFAULT 0;
