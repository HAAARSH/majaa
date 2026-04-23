-- ─────────────────────────────────────────────────────────────────────────
-- Smart Import Phase 0 — learning tables + audit log
--
-- Three tables:
--   1. product_alias_learning  — OCR/paste product-name → catalog product
--   2. customer_alias_learning — OCR/paste customer-name → customer row
--   3. smart_import_history    — dedup guard + audit of every admin import
--
-- All FKs use TEXT (customers.id / products.id / orders.id are TEXT, NOT
-- UUID — see 20260323072756_fmcg_core_schema.sql). app_users.id is UUID.
-- RLS: admin + super_admin only, with team scoping. Follows the
-- auth.uid()::TEXT cast pattern established in
-- 20260331000001_enhance_collections.sql:75.
-- ─────────────────────────────────────────────────────────────────────────

-- ═════════════════════════════════════════════════════════════════════════
-- 1. product_alias_learning
-- ═════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.product_alias_learning (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  -- NULL = global alias (any customer). NOT NULL = customer-specific alias.
  customer_id TEXT REFERENCES public.customers(id) ON DELETE CASCADE,
  -- Normalized form: lowercase, whitespace-collapsed, punctuation stripped.
  alias_text TEXT NOT NULL,
  matched_product_id TEXT NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  -- Increments by 1 each time admin confirms this mapping again.
  confidence_score INT NOT NULL DEFAULT 1,
  team_id TEXT NOT NULL,
  created_by_user_id UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_used_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  -- Per-customer uniqueness. NULL customer_id rows are NOT deduped by this
  -- constraint because Postgres treats NULL as distinct — see partial
  -- unique index below for the global-alias dedup.
  UNIQUE (customer_id, alias_text, team_id)
);

-- Primary lookup path: by (customer_id, alias_text, team_id).
CREATE INDEX IF NOT EXISTS idx_product_alias_lookup
  ON public.product_alias_learning(customer_id, alias_text, team_id);

-- Global-alias dedup (fixes the "NULL ≠ NULL in UNIQUE" gap).
CREATE UNIQUE INDEX IF NOT EXISTS ux_product_alias_global
  ON public.product_alias_learning(alias_text, team_id)
  WHERE customer_id IS NULL;

-- Fallback lookup when no customer-specific alias matches.
CREATE INDEX IF NOT EXISTS idx_product_alias_global_lookup
  ON public.product_alias_learning(alias_text, team_id)
  WHERE customer_id IS NULL;

-- Trigram index on alias_text for fuzzy matching suggestions.
-- pg_trgm is already enabled (20260401000002_additional_indexes.sql).
CREATE INDEX IF NOT EXISTS idx_product_alias_text_trgm
  ON public.product_alias_learning USING gin (alias_text gin_trgm_ops);

ALTER TABLE public.product_alias_learning ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admins manage product aliases" ON public.product_alias_learning;
CREATE POLICY "Admins manage product aliases"
  ON public.product_alias_learning FOR ALL
  USING (
    (SELECT role FROM public.app_users WHERE id = auth.uid()::TEXT) IN ('admin', 'super_admin')
    AND team_id = (SELECT team_id FROM public.app_users WHERE id = auth.uid()::TEXT)
  )
  WITH CHECK (
    (SELECT role FROM public.app_users WHERE id = auth.uid()::TEXT) IN ('admin', 'super_admin')
    AND team_id = (SELECT team_id FROM public.app_users WHERE id = auth.uid()::TEXT)
  );


-- ═════════════════════════════════════════════════════════════════════════
-- 2. customer_alias_learning
-- ═════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.customer_alias_learning (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  -- Normalized form of what appeared in the input.
  alias_text TEXT NOT NULL,
  matched_customer_id TEXT NOT NULL REFERENCES public.customers(id) ON DELETE CASCADE,
  confidence_score INT NOT NULL DEFAULT 1,
  team_id TEXT NOT NULL,
  created_by_user_id UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_used_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (alias_text, team_id)
);

CREATE INDEX IF NOT EXISTS idx_customer_alias_lookup
  ON public.customer_alias_learning(alias_text, team_id);

-- Trigram index for fuzzy customer-name matching.
CREATE INDEX IF NOT EXISTS idx_customer_alias_text_trgm
  ON public.customer_alias_learning USING gin (alias_text gin_trgm_ops);

ALTER TABLE public.customer_alias_learning ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admins manage customer aliases" ON public.customer_alias_learning;
CREATE POLICY "Admins manage customer aliases"
  ON public.customer_alias_learning FOR ALL
  USING (
    (SELECT role FROM public.app_users WHERE id = auth.uid()::TEXT) IN ('admin', 'super_admin')
    AND team_id = (SELECT team_id FROM public.app_users WHERE id = auth.uid()::TEXT)
  )
  WITH CHECK (
    (SELECT role FROM public.app_users WHERE id = auth.uid()::TEXT) IN ('admin', 'super_admin')
    AND team_id = (SELECT team_id FROM public.app_users WHERE id = auth.uid()::TEXT)
  );


-- ═════════════════════════════════════════════════════════════════════════
-- 3. smart_import_history (audit + retry + dup-guard)
-- ═════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.smart_import_history (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  -- Who ran the import (admin). Audit only — the order's user_id is set to
  -- the attributed rep, not this admin.
  imported_by_user_id UUID,
  imported_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  -- 'brand_software_text' | 'whatsapp_text' | 'pdf' | 'image_screenshot' | 'image_handwritten'
  input_type TEXT NOT NULL,
  -- First 500 chars of the input for history display. NULL if binary-only.
  input_preview TEXT,
  -- SHA-256 of NORMALIZED input (trim + collapse whitespace + lowercase).
  -- Normalization happens client-side before both insert and the
  -- duplicate-check query, so accidental re-paste is caught.
  input_hash TEXT NOT NULL,
  -- Gemini's full parsed output, for debugging bad parses.
  parsed_result JSONB,
  -- Diff between parsed output and the final saved order.
  admin_corrections JSONB,
  resulting_order_id TEXT REFERENCES public.orders(id) ON DELETE SET NULL,
  team_id TEXT NOT NULL,
  -- 'saved' | 'discarded' | 'in_review'
  status TEXT NOT NULL,
  -- Which rep this import was attributed to on save (brand_rep or sales_rep).
  attributed_brand_rep_user_id UUID REFERENCES public.app_users(id) ON DELETE SET NULL,
  -- Same content in same team cannot be imported twice.
  UNIQUE (input_hash, team_id)
);

CREATE INDEX IF NOT EXISTS idx_smart_import_history_user
  ON public.smart_import_history(imported_by_user_id, imported_at DESC);

CREATE INDEX IF NOT EXISTS idx_smart_import_history_team_time
  ON public.smart_import_history(team_id, imported_at DESC);

ALTER TABLE public.smart_import_history ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admins manage import history" ON public.smart_import_history;
CREATE POLICY "Admins manage import history"
  ON public.smart_import_history FOR ALL
  USING (
    (SELECT role FROM public.app_users WHERE id = auth.uid()::TEXT) IN ('admin', 'super_admin')
    AND team_id = (SELECT team_id FROM public.app_users WHERE id = auth.uid()::TEXT)
  )
  WITH CHECK (
    (SELECT role FROM public.app_users WHERE id = auth.uid()::TEXT) IN ('admin', 'super_admin')
    AND team_id = (SELECT team_id FROM public.app_users WHERE id = auth.uid()::TEXT)
  );


-- ═════════════════════════════════════════════════════════════════════════
-- Verification queries (run after migration to confirm structure)
-- ═════════════════════════════════════════════════════════════════════════
-- SELECT COUNT(*) FROM information_schema.tables WHERE table_name IN
--   ('product_alias_learning','customer_alias_learning','smart_import_history');
-- Should return 3.
--
-- SELECT indexname FROM pg_indexes WHERE tablename = 'product_alias_learning';
-- Should include ux_product_alias_global, idx_product_alias_text_trgm,
-- idx_product_alias_lookup, idx_product_alias_global_lookup.
--
-- Partial unique index sanity check (both INSERTs should succeed; second
-- of the same pair should fail):
-- INSERT INTO product_alias_learning (alias_text, matched_product_id, team_id)
--   VALUES ('test alias', '<any real product id>', 'JA');  -- OK
-- INSERT INTO product_alias_learning (alias_text, matched_product_id, team_id)
--   VALUES ('test alias', '<any real product id>', 'JA');  -- should fail
--   (duplicate key value violates unique constraint "ux_product_alias_global")
