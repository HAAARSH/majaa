-- ─────────────────────────────────────────────────────────────────────
-- PREVIEW: pharmacy-like customers across BOTH teams.
--
-- Single combined query so Supabase SQL Editor returns one result set
-- (previous multi-statement version only displayed the last query's
-- output). Run this, scroll the list, spot false positives. When
-- happy, run `mark_pharmacy_customers_apply.sql`.
--
-- Keywords: MEDICAL / MEDICOS / MEDICOSE / MEDICO (standalone) /
--           MEDICINE / CHEMIST / PHARMACY / PHARMA / DRUG.
-- Both teams live on the same customers row (team split is in
-- customer_team_profiles), so one query covers JA + MA.
-- ─────────────────────────────────────────────────────────────────────

SELECT
  c.id,
  c.name,
  COALESCE(c.type, '(null)') AS current_type,
  CASE
    WHEN c.type = 'Pharmacy' THEN 'already-tagged'
    ELSE 'WILL-CHANGE'
  END AS action,
  CASE WHEN c.acc_code_ja IS NOT NULL AND c.acc_code_ja <> '' THEN 'Y' ELSE '-' END AS ja,
  CASE WHEN c.acc_code_ma IS NOT NULL AND c.acc_code_ma <> '' THEN 'Y' ELSE '-' END AS ma
FROM public.customers c
WHERE
      c.name ILIKE '%MEDICAL%'
  OR  c.name ILIKE '%MEDICOS%'
  OR  c.name ILIKE '%MEDICOSE%'
  OR  c.name ILIKE '%MEDICO %'
  OR  c.name ILIKE '% MEDICO'
  OR  c.name ILIKE '%MEDICINE%'
  OR  c.name ILIKE '%CHEMIST%'
  OR  c.name ILIKE '%PHARMACY%'
  OR  c.name ILIKE '%PHARMA%'
  OR  c.name ILIKE '%DRUG%'
ORDER BY
  -- WILL-CHANGE rows first (the ones you actually need to eyeball),
  -- then already-tagged for sanity, then alphabetical within each group.
  CASE WHEN c.type = 'Pharmacy' THEN 1 ELSE 0 END,
  c.name;
