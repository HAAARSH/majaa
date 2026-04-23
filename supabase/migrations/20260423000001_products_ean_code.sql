-- Smart Import Phase 0 prerequisite — EAN codes on products.
-- Populated gradually as admin imports PDFs with EAN columns. Sparse column.
-- Partial index keeps lookup fast without bloating for the mostly-null rows.
ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS ean_code TEXT;

CREATE INDEX IF NOT EXISTS idx_products_ean_code
  ON public.products(ean_code)
  WHERE ean_code IS NOT NULL;
