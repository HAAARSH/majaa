-- Add billing software account codes per team to customers for ACMAST sync
-- JA and MA have separate billing software with independent account codes
ALTER TABLE customers ADD COLUMN IF NOT EXISTS acc_code_ja TEXT;
ALTER TABLE customers ADD COLUMN IF NOT EXISTS acc_code_ma TEXT;

-- Indexes for fast lookup during sync
CREATE INDEX IF NOT EXISTS idx_customers_acc_code_ja ON customers (acc_code_ja) WHERE acc_code_ja IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_customers_acc_code_ma ON customers (acc_code_ma) WHERE acc_code_ma IS NOT NULL;
