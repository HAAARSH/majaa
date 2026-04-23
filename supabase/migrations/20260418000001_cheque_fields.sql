-- ─────────────────────────────────────────────────────────────────────────────
-- Migration: Add cheque bank / date / photo columns to `collections`
--
-- Why: the settle flow now lets reps record cheque details (number, bank,
-- date) plus an optional photo of the cheque that feeds Gemini OCR to
-- pre-fill those fields. `cheque_number` already exists from the 2026-03-31
-- enhance_collections migration; only the three new columns are added here.
-- All are optional — reps may still log a cheque payment with none of them.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE collections
  ADD COLUMN IF NOT EXISTS cheque_bank      TEXT,
  ADD COLUMN IF NOT EXISTS cheque_date      DATE,
  ADD COLUMN IF NOT EXISTS cheque_photo_url TEXT;
