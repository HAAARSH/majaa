-- Product Categories Table (fresh migration to ensure it is applied)
CREATE TABLE IF NOT EXISTS public.product_categories (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    sort_order INTEGER DEFAULT 0,
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_product_categories_name ON public.product_categories (name);
CREATE INDEX IF NOT EXISTS idx_product_categories_sort ON public.product_categories (sort_order);

ALTER TABLE public.product_categories ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "categories_public_read" ON public.product_categories;
CREATE POLICY "categories_public_read"
ON public.product_categories
FOR SELECT
TO public
USING (true);

DROP POLICY IF EXISTS "categories_authenticated_write" ON public.product_categories;
CREATE POLICY "categories_authenticated_write"
ON public.product_categories
FOR ALL
TO authenticated
USING (true)
WITH CHECK (true);

-- Seed default categories
DO $$
BEGIN
    INSERT INTO public.product_categories (name, sort_order) VALUES
        ('Beverages', 1),
        ('Snacks', 2),
        ('Dairy', 3),
        ('Personal Care', 4),
        ('Household', 5),
        ('Frozen Foods', 6)
    ON CONFLICT (name) DO NOTHING;
END $$;
