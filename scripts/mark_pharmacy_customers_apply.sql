-- ─────────────────────────────────────────────────────────────────────
-- APPLY: flip matched customers' type to 'Pharmacy'.
-- Run this AFTER reviewing the list from `mark_pharmacy_customers.sql`.
--
-- `WHERE type IS DISTINCT FROM 'Pharmacy'` skips already-tagged rows,
-- so the script is idempotent — rerunning later picks up only newly-
-- added customers.
--
-- The trailing SELECT reports the affected row count so you can sanity-
-- check it matches what you saw in the preview.
-- ─────────────────────────────────────────────────────────────────────

WITH updated AS (
  UPDATE public.customers
  SET    type = 'Pharmacy'
  WHERE  type IS DISTINCT FROM 'Pharmacy'
    AND (
          name ILIKE '%MEDICAL%'
      OR  name ILIKE '%MEDICOS%'
      OR  name ILIKE '%MEDICOSE%'
      OR  name ILIKE '%MEDICO %'
      OR  name ILIKE '% MEDICO'
      OR  name ILIKE '%MEDICINE%'
      OR  name ILIKE '%CHEMIST%'
      OR  name ILIKE '%PHARMACY%'
      OR  name ILIKE '%PHARMA%'
      OR  name ILIKE '%DRUG%'
    )
  RETURNING id
)
SELECT COUNT(*) AS rows_flipped_to_pharmacy FROM updated;
