-- ─────────────────────────────────────────────────────────────────────────────
-- Migration: Two-stage bill number system
--
-- BEFORE:  final_bill_no / actual_billed_amount = written by delivery rep OCR
--          (incorrectly named — these should be FINAL/office values)
--
-- AFTER:
--   preliminary_bill_no   — delivery rep OCR output (Stage 1)
--   preliminary_amount    — delivery rep OCR output (Stage 1)
--   final_bill_no         — admin enters from local software (Stage 2)  ← existing column
--   actual_billed_amount  — admin enters from local software (Stage 2)  ← existing column
--   bill_verified         — admin marks true when Stage 2 is done
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE orders
  ADD COLUMN IF NOT EXISTS preliminary_bill_no  TEXT,
  ADD COLUMN IF NOT EXISTS preliminary_amount   NUMERIC(12,2),
  ADD COLUMN IF NOT EXISTS bill_verified        BOOLEAN DEFAULT FALSE;

-- Backfill: current final_bill_no values were actually written by delivery OCR,
-- so move them to preliminary_bill_no for all unverified orders
UPDATE orders
  SET preliminary_bill_no = final_bill_no,
      preliminary_amount  = actual_billed_amount,
      final_bill_no       = NULL,
      actual_billed_amount = NULL
  WHERE verified_by_delivery = TRUE
    AND verified_by_office   = FALSE
    AND final_bill_no IS NOT NULL;

-- For already office-verified orders, set bill_verified = true
UPDATE orders
  SET bill_verified = TRUE
  WHERE verified_by_office = TRUE;

-- Index for bill verification tab query
CREATE INDEX IF NOT EXISTS idx_orders_bill_verified
  ON orders(team_id, verified_by_delivery, bill_verified)
  WHERE verified_by_delivery = TRUE AND bill_verified = FALSE;

-- ─── ORDER STATUS ENUM EXPANSION ─────────────────────────────────────────────
-- PostgreSQL requires ALTER TYPE to add enum values (cannot be inside transaction
-- on older PG versions, so run separately if needed)
ALTER TYPE order_status ADD VALUE IF NOT EXISTS 'Confirmed';
ALTER TYPE order_status ADD VALUE IF NOT EXISTS 'Invoiced';
ALTER TYPE order_status ADD VALUE IF NOT EXISTS 'Paid';
ALTER TYPE order_status ADD VALUE IF NOT EXISTS 'Cancelled';
ALTER TYPE order_status ADD VALUE IF NOT EXISTS 'Returned';
ALTER TYPE order_status ADD VALUE IF NOT EXISTS 'Partially Delivered';
