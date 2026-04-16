-- Customer pending bills from OPNBIL CSV
CREATE TABLE IF NOT EXISTS customer_bills (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id TEXT NOT NULL REFERENCES customers(id),
  acc_code TEXT NOT NULL,
  invoice_no TEXT NOT NULL,
  book TEXT DEFAULT '',
  bill_date DATE,
  bill_amount NUMERIC(12,2) DEFAULT 0,
  pending_amount NUMERIC(12,2) DEFAULT 0,
  received_amount NUMERIC(12,2) DEFAULT 0,
  cleared BOOLEAN DEFAULT false,
  credit_days INTEGER DEFAULT 0,
  team_id TEXT NOT NULL,
  synced_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(invoice_no, book, team_id)
);

CREATE INDEX IF NOT EXISTS idx_customer_bills_customer ON customer_bills (customer_id, team_id);
CREATE INDEX IF NOT EXISTS idx_customer_bills_invoice ON customer_bills (invoice_no, team_id);

-- Customer receipts/payments from RECT CSV
CREATE TABLE IF NOT EXISTS customer_receipts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id TEXT NOT NULL REFERENCES customers(id),
  acc_code TEXT NOT NULL,
  receipt_date DATE,
  amount NUMERIC(12,2) DEFAULT 0,
  bank_name TEXT DEFAULT '',
  receipt_no TEXT DEFAULT '',
  cash_yn BOOLEAN DEFAULT false,
  team_id TEXT NOT NULL,
  synced_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(receipt_no, receipt_date, team_id)
);

CREATE INDEX IF NOT EXISTS idx_customer_receipts_customer ON customer_receipts (customer_id, team_id);

-- Receipt bill-level breakdown from RCTBIL CSV (flat list)
CREATE TABLE IF NOT EXISTS customer_receipt_bills (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  receipt_date DATE,
  receipt_no TEXT NOT NULL,
  invoice_no TEXT NOT NULL,
  bill_date DATE,
  bill_amount NUMERIC(12,2) DEFAULT 0,
  paid_amount NUMERIC(12,2) DEFAULT 0,
  discount NUMERIC(12,2) DEFAULT 0,
  return_amount NUMERIC(12,2) DEFAULT 0,
  scheme_amount NUMERIC(12,2) DEFAULT 0,
  team_id TEXT NOT NULL,
  synced_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(receipt_no, invoice_no, receipt_date, team_id)
);

CREATE INDEX IF NOT EXISTS idx_receipt_bills_receipt ON customer_receipt_bills (receipt_no, team_id);
CREATE INDEX IF NOT EXISTS idx_receipt_bills_invoice ON customer_receipt_bills (invoice_no, team_id);
