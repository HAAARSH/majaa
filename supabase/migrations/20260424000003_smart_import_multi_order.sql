-- ─────────────────────────────────────────────────────────────────────────
-- Smart Import: multi-order-per-attachment support.
--
-- One uploaded file or paste can now produce N orders (e.g. a handwritten
-- slip with 3 shops listed one after another). The dedup key remains
-- per-attachment (input_hash + team_id), but the audit row now records
-- ALL resulting order IDs instead of one.
--
-- ADDITIVE migration — safe rollback:
--   * `resulting_order_ids TEXT[]` added.
--   * Old scalar `resulting_order_id` stays NULLABLE and writable.
--   * Backfill populates the array from the scalar for existing rows.
--   * Code writes BOTH columns until a future migration drops the scalar.
-- ─────────────────────────────────────────────────────────────────────────

ALTER TABLE public.smart_import_history
  ADD COLUMN IF NOT EXISTS resulting_order_ids TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[];

-- Backfill: for any row that already has a scalar resulting_order_id, seed
-- the array with that single value. Array stays empty for unsaved/discarded.
UPDATE public.smart_import_history
SET resulting_order_ids = ARRAY[resulting_order_id]
WHERE resulting_order_id IS NOT NULL
  AND (resulting_order_ids IS NULL OR cardinality(resulting_order_ids) = 0);

-- Fast lookup by any contained order id — "which import produced this order?"
CREATE INDEX IF NOT EXISTS idx_smart_import_history_order_ids
  ON public.smart_import_history USING gin (resulting_order_ids);


-- ═════════════════════════════════════════════════════════════════════════
-- Verification
-- ═════════════════════════════════════════════════════════════════════════
-- SELECT column_name, data_type FROM information_schema.columns
--   WHERE table_name = 'smart_import_history' AND column_name = 'resulting_order_ids';
-- Should return: resulting_order_ids | ARRAY
--
-- SELECT indexname FROM pg_indexes WHERE tablename = 'smart_import_history';
-- Should list idx_smart_import_history_order_ids.
