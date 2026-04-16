-- Customer billed items from ITTR CSV (actual invoiced items from billing software)
CREATE TABLE IF NOT EXISTS customer_billed_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id TEXT REFERENCES customers(id),
  acc_name TEXT NOT NULL,
  bill_date DATE,
  invoice_no TEXT NOT NULL,  -- BOOK+VNO or BILLNO
  item_name TEXT NOT NULL,
  packing TEXT DEFAULT '',
  company TEXT DEFAULT '',
  quantity INTEGER DEFAULT 0,
  mrp NUMERIC(10,2) DEFAULT 0,
  rate NUMERIC(10,2) DEFAULT 0,
  amount NUMERIC(12,2) DEFAULT 0,
  team_id TEXT NOT NULL,
  synced_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(invoice_no, item_name, bill_date, team_id)
);

CREATE INDEX IF NOT EXISTS idx_billed_items_customer ON customer_billed_items (customer_id, team_id);
CREATE INDEX IF NOT EXISTS idx_billed_items_invoice ON customer_billed_items (invoice_no, team_id);
CREATE INDEX IF NOT EXISTS idx_billed_items_date ON customer_billed_items (bill_date, team_id);
