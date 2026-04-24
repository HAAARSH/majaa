-- ─────────────────────────────────────────────────────────────────────────
-- Smart Import override: super_admin revoke + auto-unblock discarded/failed.
--
-- BEFORE:
--   * smart_import_history had a blunt UNIQUE(input_hash, team_id). Any
--     prior attempt — including one where admin skipped every draft or
--     the save failed — blocked future re-imports of the same content.
--   * No way for super_admin to force a re-parse when the first parse
--     was wrong or incomplete.
--
-- AFTER:
--   * Soft-delete columns: revoked_at + revoked_by_user_id. Super_admin
--     can mark a row revoked to unblock its hash without destroying audit.
--   * Partial unique index replaces the UNIQUE constraint: only "active"
--     rows (not revoked, not discarded, not failed) enforce uniqueness.
--     Discarded/failed/revoked rows stay for audit but stop blocking.
--
-- ADDITIVE migration — orders never touched. Rollback:
--   * Drop the partial index + restore the original UNIQUE constraint.
-- ─────────────────────────────────────────────────────────────────────────

-- ═════════════════════════════════════════════════════════════════════════
-- 1. Revoke columns (soft-delete, preserves audit)
-- ═════════════════════════════════════════════════════════════════════════

ALTER TABLE public.smart_import_history
  ADD COLUMN IF NOT EXISTS revoked_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS revoked_by_user_id UUID
    REFERENCES public.app_users(id) ON DELETE SET NULL;


-- ═════════════════════════════════════════════════════════════════════════
-- 2. Swap the blunt UNIQUE for a partial unique index
--
-- The original inline `UNIQUE (input_hash, team_id)` in migration
-- 20260423000002 produced a Postgres-auto-named constraint:
--   smart_import_history_input_hash_team_id_key
-- We drop it and replace with a partial unique index that mirrors the
-- dedup intent but skips rows that never produced an order.
-- ═════════════════════════════════════════════════════════════════════════

ALTER TABLE public.smart_import_history
  DROP CONSTRAINT IF EXISTS smart_import_history_input_hash_team_id_key;

-- Only "active saved" rows block future re-imports.
-- A row unblocks the hash when ANY of:
--   * revoked_at IS NOT NULL   → super_admin revoked it
--   * status = 'discarded'     → admin skipped every draft
--   * status = 'failed'        → save errored, no order created
CREATE UNIQUE INDEX IF NOT EXISTS ux_smart_import_active_hash
  ON public.smart_import_history (input_hash, team_id)
  WHERE revoked_at IS NULL AND status NOT IN ('discarded', 'failed');


-- ═════════════════════════════════════════════════════════════════════════
-- 3. Index for revoke lookups (super_admin audit screen, future)
-- ═════════════════════════════════════════════════════════════════════════

CREATE INDEX IF NOT EXISTS idx_smart_import_history_revoked_by
  ON public.smart_import_history(revoked_by_user_id, revoked_at DESC)
  WHERE revoked_at IS NOT NULL;


-- ═════════════════════════════════════════════════════════════════════════
-- Verification queries
-- ═════════════════════════════════════════════════════════════════════════
-- Columns present:
--   SELECT column_name FROM information_schema.columns
--     WHERE table_name='smart_import_history'
--     AND column_name IN ('revoked_at','revoked_by_user_id');
--   -- Should return 2 rows.
--
-- Old constraint gone:
--   SELECT conname FROM pg_constraint
--     WHERE conrelid = 'public.smart_import_history'::regclass
--     AND contype = 'u';
--   -- Should NOT list smart_import_history_input_hash_team_id_key.
--
-- Partial unique index in place:
--   SELECT indexdef FROM pg_indexes
--     WHERE tablename='smart_import_history'
--     AND indexname='ux_smart_import_active_hash';
