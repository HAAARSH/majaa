-- Bill Extraction System — OCR extracted bills + item/customer matching

-- 1. Full bill OCR results
CREATE TABLE IF NOT EXISTS bill_extractions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    bill_no TEXT NOT NULL,
    bill_date DATE,
    customer_name_ocr TEXT,
    customer_id TEXT REFERENCES customers(id),
    customer_matched BOOLEAN DEFAULT false,
    subtotal NUMERIC(12,2),
    cgst_total NUMERIC(12,2),
    sgst_total NUMERIC(12,2),
    grand_total NUMERIC(12,2),
    order_id TEXT REFERENCES orders(id),
    order_matched BOOLEAN DEFAULT false,
    auto_verified BOOLEAN DEFAULT false,
    team_id TEXT DEFAULT 'JA',
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

-- 2. Line items extracted from OCR
CREATE TABLE IF NOT EXISTS order_billed_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    bill_extraction_id UUID REFERENCES bill_extractions(id) ON DELETE CASCADE,
    order_id TEXT REFERENCES orders(id),
    bill_no TEXT,
    product_id TEXT REFERENCES products(id),
    billed_item_name TEXT NOT NULL,
    hsn_code TEXT,
    mrp NUMERIC(10,2),
    gst_rate NUMERIC(5,2),
    quantity NUMERIC(10,2),
    rate NUMERIC(10,2),
    discount_percent NUMERIC(5,2),
    amount NUMERIC(12,2),
    matched BOOLEAN DEFAULT false,
    team_id TEXT DEFAULT 'JA',
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

-- 3. Remembered item name mappings (OCR name → product_id)
CREATE TABLE IF NOT EXISTS item_name_mappings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    ocr_name TEXT NOT NULL,
    product_id TEXT REFERENCES products(id) NOT NULL,
    team_id TEXT DEFAULT 'JA',
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(ocr_name, team_id)
);

-- 4. RLS policies
ALTER TABLE bill_extractions ENABLE ROW LEVEL SECURITY;
ALTER TABLE order_billed_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE item_name_mappings ENABLE ROW LEVEL SECURITY;

CREATE POLICY "bill_extractions_auth" ON bill_extractions
    FOR ALL USING (auth.role() = 'authenticated')
    WITH CHECK (auth.role() = 'authenticated');

CREATE POLICY "order_billed_items_auth" ON order_billed_items
    FOR ALL USING (auth.role() = 'authenticated')
    WITH CHECK (auth.role() = 'authenticated');

CREATE POLICY "item_name_mappings_auth" ON item_name_mappings
    FOR ALL USING (auth.role() = 'authenticated')
    WITH CHECK (auth.role() = 'authenticated');

-- 5. Indexes
CREATE INDEX IF NOT EXISTS idx_bill_extractions_bill_no ON bill_extractions(bill_no, team_id);
CREATE INDEX IF NOT EXISTS idx_bill_extractions_order ON bill_extractions(order_id);
CREATE INDEX IF NOT EXISTS idx_billed_items_bill ON order_billed_items(bill_extraction_id);
CREATE INDEX IF NOT EXISTS idx_billed_items_product ON order_billed_items(product_id);
CREATE INDEX IF NOT EXISTS idx_billed_items_matched ON order_billed_items(matched) WHERE matched = false;
CREATE INDEX IF NOT EXISTS idx_item_mappings_name ON item_name_mappings(ocr_name, team_id);
