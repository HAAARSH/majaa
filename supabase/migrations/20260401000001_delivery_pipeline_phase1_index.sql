-- ============================================================
-- Phase 1 Follow-up: Create index for Pending Verification status
-- Must be run after the main Phase 1 migration to allow enum values
-- to be committed before using them in indexes
-- ============================================================

-- Create index for Pending Verification status (now safe to use)
CREATE INDEX IF NOT EXISTS idx_orders_status_pending_verification ON orders(status) WHERE status = 'Pending Verification';

-- Also create index for Verified status for admin queries
CREATE INDEX IF NOT EXISTS idx_orders_status_verified ON orders(status) WHERE status = 'Verified';

-- ============================================================
-- END OF PHASE 1 FOLLOW-UP MIGRATION
-- ============================================================
