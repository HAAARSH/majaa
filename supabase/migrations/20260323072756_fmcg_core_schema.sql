-- ============================================================
-- FMCG Orders App – Core Schema Migration
-- Tables: products, beats, customers, orders, order_items
-- ============================================================

-- ─── 1. ENUM TYPES ───────────────────────────────────────────

DROP TYPE IF EXISTS public.product_status CASCADE;
CREATE TYPE public.product_status AS ENUM ('available', 'lowStock', 'outOfStock', 'discontinued');

DROP TYPE IF EXISTS public.order_status CASCADE;
CREATE TYPE public.order_status AS ENUM ('Pending', 'Confirmed', 'Delivered', 'Cancelled');

-- ─── 2. CORE TABLES ──────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.products (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    sku TEXT NOT NULL UNIQUE,
    category TEXT NOT NULL,
    brand TEXT NOT NULL DEFAULT '',
    unit_price NUMERIC(10,2) NOT NULL DEFAULT 0,
    pack_size TEXT NOT NULL DEFAULT '',
    status public.product_status NOT NULL DEFAULT 'available',
    stock_qty INTEGER NOT NULL DEFAULT 0,
    image_url TEXT NOT NULL DEFAULT '',
    semantic_label TEXT NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS public.beats (
    id TEXT PRIMARY KEY,
    beat_name TEXT NOT NULL,
    beat_code TEXT NOT NULL UNIQUE,
    weekdays TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS public.customers (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    address TEXT NOT NULL DEFAULT '',
    phone TEXT NOT NULL DEFAULT '',
    type TEXT NOT NULL DEFAULT 'General Trade',
    beat_id TEXT REFERENCES public.beats(id) ON DELETE SET NULL,
    beat TEXT NOT NULL DEFAULT '',
    last_order_value NUMERIC(10,2) NOT NULL DEFAULT 0,
    last_order_date DATE,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS public.orders (
    id TEXT PRIMARY KEY,
    customer_id TEXT REFERENCES public.customers(id) ON DELETE SET NULL,
    customer_name TEXT NOT NULL,
    beat TEXT NOT NULL DEFAULT '',
    order_date TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    delivery_date DATE,
    subtotal NUMERIC(10,2) NOT NULL DEFAULT 0,
    vat NUMERIC(10,2) NOT NULL DEFAULT 0,
    grand_total NUMERIC(10,2) NOT NULL DEFAULT 0,
    item_count INTEGER NOT NULL DEFAULT 0,
    total_units INTEGER NOT NULL DEFAULT 0,
    status public.order_status NOT NULL DEFAULT 'Pending',
    notes TEXT,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS public.order_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id TEXT NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
    product_id TEXT REFERENCES public.products(id) ON DELETE SET NULL,
    product_name TEXT NOT NULL,
    sku TEXT NOT NULL DEFAULT '',
    quantity INTEGER NOT NULL DEFAULT 1,
    unit_price NUMERIC(10,2) NOT NULL DEFAULT 0,
    line_total NUMERIC(10,2) NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

-- ─── 3. INDEXES ──────────────────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_products_category ON public.products(category);
CREATE INDEX IF NOT EXISTS idx_products_status ON public.products(status);
CREATE INDEX IF NOT EXISTS idx_customers_beat_id ON public.customers(beat_id);
CREATE INDEX IF NOT EXISTS idx_orders_customer_id ON public.orders(customer_id);
CREATE INDEX IF NOT EXISTS idx_orders_status ON public.orders(status);
CREATE INDEX IF NOT EXISTS idx_orders_order_date ON public.orders(order_date DESC);
CREATE INDEX IF NOT EXISTS idx_order_items_order_id ON public.order_items(order_id);

-- ─── 4. UPDATED_AT TRIGGER FUNCTION ──────────────────────────

CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_products_updated_at ON public.products;
CREATE TRIGGER trg_products_updated_at
    BEFORE UPDATE ON public.products
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

DROP TRIGGER IF EXISTS trg_customers_updated_at ON public.customers;
CREATE TRIGGER trg_customers_updated_at
    BEFORE UPDATE ON public.customers
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

DROP TRIGGER IF EXISTS trg_orders_updated_at ON public.orders;
CREATE TRIGGER trg_orders_updated_at
    BEFORE UPDATE ON public.orders
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- ─── 5. ENABLE RLS ───────────────────────────────────────────

ALTER TABLE public.products ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.beats ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_items ENABLE ROW LEVEL SECURITY;

-- ─── 6. RLS POLICIES (Public read, open write for field app) ─

DROP POLICY IF EXISTS "public_read_products" ON public.products;
CREATE POLICY "public_read_products" ON public.products
    FOR SELECT TO public USING (true);

DROP POLICY IF EXISTS "public_write_products" ON public.products;
CREATE POLICY "public_write_products" ON public.products
    FOR ALL TO public USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "public_read_beats" ON public.beats;
CREATE POLICY "public_read_beats" ON public.beats
    FOR SELECT TO public USING (true);

DROP POLICY IF EXISTS "public_write_beats" ON public.beats;
CREATE POLICY "public_write_beats" ON public.beats
    FOR ALL TO public USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "public_read_customers" ON public.customers;
CREATE POLICY "public_read_customers" ON public.customers
    FOR SELECT TO public USING (true);

DROP POLICY IF EXISTS "public_write_customers" ON public.customers;
CREATE POLICY "public_write_customers" ON public.customers
    FOR ALL TO public USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "public_read_orders" ON public.orders;
CREATE POLICY "public_read_orders" ON public.orders
    FOR SELECT TO public USING (true);

DROP POLICY IF EXISTS "public_write_orders" ON public.orders;
CREATE POLICY "public_write_orders" ON public.orders
    FOR ALL TO public USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "public_read_order_items" ON public.order_items;
CREATE POLICY "public_read_order_items" ON public.order_items
    FOR SELECT TO public USING (true);

DROP POLICY IF EXISTS "public_write_order_items" ON public.order_items;
CREATE POLICY "public_write_order_items" ON public.order_items
    FOR ALL TO public USING (true) WITH CHECK (true);

-- ─── 7. SAMPLE DATA ──────────────────────────────────────────

DO $$
BEGIN
    -- Products
    INSERT INTO public.products (id, name, sku, category, brand, unit_price, pack_size, status, stock_qty, image_url, semantic_label) VALUES
        ('p001', 'Tropical Burst Orange Juice', 'BEV-TBO-1L', 'Beverages', 'Tropical Burst', 3.49, '12 × 1L', 'available', 240, 'https://images.unsplash.com/photo-1716834092549-7d8fd540b51a', 'Fresh orange juice in a clear glass with orange slices beside it on white background'),
        ('p002', 'CrunchMaster Salted Crackers', 'SNK-CMC-200G', 'Snacks', 'CrunchMaster', 2.15, '24 × 200g', 'available', 480, 'https://images.unsplash.com/photo-1637016656745-c9c20c35b27f', 'Crispy golden crackers stacked on wooden board with salt crystals visible'),
        ('p003', 'PureWhite Full Cream Milk', 'DAI-PWM-500ML', 'Dairy', 'PureWhite', 1.89, '24 × 500ml', 'lowStock', 36, 'https://images.unsplash.com/photo-1631175316696-ee41839378dc', 'White milk bottle with blue cap against clean white background'),
        ('p004', 'GreenFresh Liquid Dishwash', 'HH-GFL-750ML', 'Household', 'GreenFresh', 2.79, '12 × 750ml', 'available', 144, 'https://img.rocket.new/generatedImages/rocket_gen_img_1f9393925-1768475830568.png', 'Green dishwashing liquid bottle with foam bubbles on turquoise background'),
        ('p005', 'SilkSoft Shampoo Moisturising', 'PC-SSM-400ML', 'Personal Care', 'SilkSoft', 4.25, '12 × 400ml', 'available', 108, 'https://images.unsplash.com/photo-1609749237986-228bbec5fc5f', 'Purple shampoo bottle with pearl drops on gradient lavender background'),
        ('p006', 'FrostBite Ice Cream Vanilla', 'FRZ-FBV-2L', 'Frozen Foods', 'FrostBite', 5.99, '6 × 2L', 'outOfStock', 0, 'https://img.rocket.new/generatedImages/rocket_gen_img_1f249f221-1773434791668.png', 'Vanilla ice cream scoop in waffle cone with sprinkles on blue background'),
        ('p007', 'ZestUp Sparkling Lemon Water', 'BEV-ZUL-330ML', 'Beverages', 'ZestUp', 1.25, '24 × 330ml', 'available', 576, 'https://images.unsplash.com/photo-1603968070333-58761fa00853', 'Sparkling water in glass with lemon slice and ice cubes on white marble'),
        ('p008', 'CheddarPeak Cheese Slices', 'DAI-CPC-250G', 'Dairy', 'CheddarPeak', 3.15, '12 × 250g', 'available', 96, 'https://images.unsplash.com/photo-1673877263028-384d6e48a576', 'Stack of yellow cheddar cheese slices on wooden cutting board'),
        ('p009', 'BoldBite Chilli Corn Chips', 'SNK-BBC-150G', 'Snacks', 'BoldBite', 1.75, '30 × 150g', 'lowStock', 45, 'https://img.rocket.new/generatedImages/rocket_gen_img_1ec1d32d2-1772728172176.png', 'Spicy red corn chips in open bag with chilli peppers on dark background'),
        ('p010', 'AquaFlow Mineral Water', 'BEV-AFM-500ML', 'Beverages', 'AquaFlow', 0.89, '24 × 500ml', 'available', 960, 'https://images.unsplash.com/photo-1671527304437-9a2f286479a3', 'Clear water bottle with blue cap on white background with water droplets'),
        ('p011', 'CleanPro Antibacterial Soap', 'PC-CPA-125G', 'Personal Care', 'CleanPro', 1.45, '48 × 125g', 'available', 288, 'https://images.unsplash.com/photo-1622116555373-bf1bfa08ba1e', 'White bar of antibacterial soap with foam bubbles on light blue background'),
        ('p012', 'SparkShine Floor Cleaner', 'HH-SSF-1L', 'Household', 'SparkShine', 3.25, '12 × 1L', 'discontinued', 0, 'https://img.rocket.new/generatedImages/rocket_gen_img_10f4140bc-1765808158607.png', 'Yellow cleaning spray bottle with sparkling floor tiles in background')
    ON CONFLICT (id) DO NOTHING;

    -- Beats
    INSERT INTO public.beats (id, beat_name, beat_code, weekdays) VALUES
        ('bt-a', 'Beat A – North', 'BT-A', ARRAY['Monday', 'Thursday']),
        ('bt-b', 'Beat B – South', 'BT-B', ARRAY['Tuesday', 'Friday']),
        ('bt-c', 'Beat C – East', 'BT-C', ARRAY['Wednesday', 'Saturday']),
        ('bt-d', 'Beat D – West', 'BT-D', ARRAY['Monday', 'Wednesday', 'Friday'])
    ON CONFLICT (id) DO NOTHING;

    -- Customers
    INSERT INTO public.customers (id, name, address, phone, type, beat_id, beat, last_order_value, last_order_date) VALUES
        ('c001', 'Sunrise General Store', '12 North Main St, Sector 4', '+91 98765 43210', 'General Trade', 'bt-a', 'Beat A – North', 1248.50, '2026-03-22'),
        ('c002', 'City Corner Shop', '45 North Ave, Block B', '+91 87654 32109', 'Convenience', 'bt-a', 'Beat A – North', 1105.60, '2026-03-18'),
        ('c003', 'Fresh & Fast Mart', '7 North Ring Rd', '+91 76543 21098', 'Supermarket', 'bt-a', 'Beat A – North', 2100.00, '2026-03-15'),
        ('c004', 'Daily Needs Depot', '23 North Cross Rd', '+91 65432 10987', 'General Trade', 'bt-a', 'Beat A – North', 780.00, '2026-03-10'),
        ('c005', 'Metro Mart Pvt Ltd', '88 South Blvd, Zone 2', '+91 54321 09876', 'Supermarket', 'bt-b', 'Beat B – South', 876.00, '2026-03-21'),
        ('c006', 'Handy Mart', '3 South Lane, Colony 5', '+91 43210 98765', 'Convenience', 'bt-b', 'Beat B – South', 320.00, '2026-03-17'),
        ('c007', 'Value Bazaar', '56 South Market Rd', '+91 32109 87654', 'General Trade', 'bt-b', 'Beat B – South', 1450.00, '2026-03-14'),
        ('c008', 'Quick Pick Superstore', '101 East Highway, Sector 9', '+91 21098 76543', 'Supermarket', 'bt-c', 'Beat C – East', 2340.75, '2026-03-20'),
        ('c009', 'East End Grocers', '34 East Park Rd', '+91 10987 65432', 'General Trade', 'bt-c', 'Beat C – East', 990.00, '2026-03-16'),
        ('c010', 'Neighbourhood Store', '67 East Colony', '+91 99876 54321', 'Convenience', 'bt-c', 'Beat C – East', 450.00, '2026-03-12'),
        ('c011', 'Family Needs Store', '22 West End Rd, Block A', '+91 88765 43210', 'General Trade', 'bt-d', 'Beat D – West', 540.30, '2026-03-19'),
        ('c012', 'West Gate Mart', '9 West Gate Colony', '+91 77654 32109', 'Convenience', 'bt-d', 'Beat D – West', 670.00, '2026-03-13'),
        ('c013', 'Wholesale Hub', '45 West Industrial Area', '+91 66543 21098', 'Wholesale', 'bt-d', 'Beat D – West', 5200.00, '2026-03-11')
    ON CONFLICT (id) DO NOTHING;

    -- Sample Orders
    INSERT INTO public.orders (id, customer_id, customer_name, beat, order_date, delivery_date, subtotal, vat, grand_total, item_count, total_units, status, notes) VALUES
        ('ORD-2026-0312', 'c001', 'Sunrise General Store', 'Beat A – North', '2026-03-22 10:30:00+00', '2026-03-24', 1134.09, 113.41, 1248.50, 5, 252, 'Delivered', 'Deliver before 9 AM'),
        ('ORD-2026-0311', 'c005', 'Metro Mart Pvt Ltd', 'Beat B – South', '2026-03-21 14:15:00+00', '2026-03-23', 796.36, 79.64, 876.00, 3, 108, 'Delivered', NULL),
        ('ORD-2026-0310', 'c008', 'Quick Pick Superstore', 'Beat C – East', '2026-03-20 09:00:00+00', '2026-03-22', 2128.86, 212.89, 2340.75, 7, 558, 'Delivered', 'Weekly bulk order'),
        ('ORD-2026-0309', 'c011', 'Family Needs Store', 'Beat D – West', '2026-03-19 11:45:00+00', '2026-03-21', 491.18, 49.12, 540.30, 4, 60, 'Pending', NULL),
        ('ORD-2026-0308', 'c002', 'City Corner Shop', 'Beat A – North', '2026-03-18 08:30:00+00', '2026-03-20', 1005.09, 100.51, 1105.60, 6, 264, 'Delivered', NULL)
    ON CONFLICT (id) DO NOTHING;

    -- Sample Order Items
    INSERT INTO public.order_items (order_id, product_id, product_name, sku, quantity, unit_price, line_total) VALUES
        ('ORD-2026-0312', 'p001', 'Tropical Burst Orange Juice', 'BEV-TBO-1L', 24, 3.49, 83.76),
        ('ORD-2026-0312', 'p002', 'CrunchMaster Salted Crackers', 'SNK-CMC-200G', 48, 2.15, 103.20),
        ('ORD-2026-0312', 'p003', 'PureWhite Full Cream Milk', 'DAI-PWM-500ML', 36, 1.89, 68.04),
        ('ORD-2026-0312', 'p010', 'AquaFlow Mineral Water', 'BEV-AFM-500ML', 96, 0.89, 85.44),
        ('ORD-2026-0312', 'p011', 'CleanPro Antibacterial Soap', 'PC-CPA-125G', 48, 1.45, 69.60),
        ('ORD-2026-0311', 'p005', 'SilkSoft Shampoo Moisturising', 'PC-SSM-400ML', 24, 4.25, 102.00),
        ('ORD-2026-0311', 'p004', 'GreenFresh Liquid Dishwash', 'HH-GFL-750ML', 36, 2.79, 100.44),
        ('ORD-2026-0311', 'p008', 'CheddarPeak Cheese Slices', 'DAI-CPC-250G', 48, 3.15, 151.20),
        ('ORD-2026-0310', 'p001', 'Tropical Burst Orange Juice', 'BEV-TBO-1L', 48, 3.49, 167.52),
        ('ORD-2026-0310', 'p007', 'ZestUp Sparkling Lemon Water', 'BEV-ZUL-330ML', 96, 1.25, 120.00),
        ('ORD-2026-0310', 'p009', 'BoldBite Chilli Corn Chips', 'SNK-BBC-150G', 60, 1.75, 105.00),
        ('ORD-2026-0310', 'p002', 'CrunchMaster Salted Crackers', 'SNK-CMC-200G', 72, 2.15, 154.80),
        ('ORD-2026-0310', 'p010', 'AquaFlow Mineral Water', 'BEV-AFM-500ML', 144, 0.89, 128.16),
        ('ORD-2026-0310', 'p003', 'PureWhite Full Cream Milk', 'DAI-PWM-500ML', 48, 1.89, 90.72),
        ('ORD-2026-0310', 'p011', 'CleanPro Antibacterial Soap', 'PC-CPA-125G', 96, 1.45, 139.20),
        ('ORD-2026-0309', 'p005', 'SilkSoft Shampoo Moisturising', 'PC-SSM-400ML', 12, 4.25, 51.00),
        ('ORD-2026-0309', 'p004', 'GreenFresh Liquid Dishwash', 'HH-GFL-750ML', 24, 2.79, 66.96),
        ('ORD-2026-0309', 'p008', 'CheddarPeak Cheese Slices', 'DAI-CPC-250G', 24, 3.15, 75.60),
        ('ORD-2026-0309', 'p006', 'FrostBite Ice Cream Vanilla', 'FRZ-FBV-2L', 12, 5.99, 71.88),
        ('ORD-2026-0308', 'p001', 'Tropical Burst Orange Juice', 'BEV-TBO-1L', 36, 3.49, 125.64),
        ('ORD-2026-0308', 'p010', 'AquaFlow Mineral Water', 'BEV-AFM-500ML', 72, 0.89, 64.08)
    ON CONFLICT (id) DO NOTHING;

EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'Sample data insertion failed: %', SQLERRM;
END $$;
