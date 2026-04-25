-- ─────────────────────────────────────────────────────────────────────────
-- Audit: hunt for OTHER desktop-sync stale-snapshot dupes beyond customers.
-- Read-only — safe to run in a second DBeaver tab while the dedupe COMMIT
-- is still executing in tab 1. Each query returns a single summary row;
-- non-zero values point at a similar bug to investigate.
--
-- Tables the desktop sync touches (per local_csv_sync_service.dart):
--   ACMAST  → customers              (already cleaning)
--   ITMRP   → products
--   OPNBIL  → customer_bills
--   RECT    → customer_receipts, customer_advances, customer_credit_notes
--   LEDGER  → customer_ledger
--   OPUBL   → opening_bills
--   ITTR    → customer_billed_items
--   CSDS    → customer_discount_schemes
--
-- Each has the same risk pattern: stale in-memory snapshot at sync start
-- + per-team file → potential double-insert. SELECT below counts rows
-- that violate the natural uniqueness key for each.
-- ─────────────────────────────────────────────────────────────────────────

SET LOCAL statement_timeout = 0;

WITH a AS (
  -- 1. Customers (post-cleanup; should be 0 if dedupe COMMITTED, else
  --    will show 1542 from the in-flight dry-run state)
  SELECT 'A1. customers — name dups' AS check_name,
         COUNT(*)::text AS bad_rows
  FROM (SELECT 1 FROM customers
        WHERE name IS NOT NULL AND TRIM(name) <> ''
        GROUP BY LOWER(TRIM(name)) HAVING COUNT(*) > 1) s
), b AS (
  -- 2. Products: identical-name dupes (desktop ITMRP sync risk)
  SELECT 'A2. products — name+team dups' AS check_name,
         COUNT(*)::text AS bad_rows
  FROM (SELECT 1 FROM products
        WHERE name IS NOT NULL AND TRIM(name) <> ''
        GROUP BY team_id, LOWER(TRIM(name)) HAVING COUNT(*) > 1) s
), c AS (
  -- 3. customer_team_profiles: more than 1 row per customer (CTP unique
  --    is on customer_id alone in current schema)
  SELECT 'A3. CTPs per customer' AS check_name,
         COUNT(*)::text AS bad_rows
  FROM (SELECT 1 FROM customer_team_profiles
        GROUP BY customer_id HAVING COUNT(*) > 1) s
), d AS (
  -- 4. customer_bills: dupes by natural key (team_id, invoice_no, book)
  --    — should be 0 because there's a UNIQUE; non-zero means sync is
  --    inserting bills with mismatched customer_id keys
  SELECT 'A4. customer_bills — dup invoices' AS check_name,
         COUNT(*)::text AS bad_rows
  FROM (SELECT 1 FROM customer_bills
        GROUP BY team_id, invoice_no, COALESCE(book,'')
        HAVING COUNT(*) > 1) s
), e AS (
  -- 5. opening_bills: same pattern (team_id, customer_id, book, bill_no)
  --    is the unique. If two rows have same (team_id, book, bill_no) but
  --    different customer_id, that's a sync split.
  SELECT 'A5. opening_bills — same bill split across customers' AS check_name,
         COUNT(*)::text AS bad_rows
  FROM (SELECT 1 FROM opening_bills
        GROUP BY team_id, COALESCE(book,''), bill_no
        HAVING COUNT(DISTINCT customer_id) > 1) s
), f AS (
  -- 6. customer_ledger: similar — same (team, date, book, bill_no, type,
  --    sno) but different customer_id
  SELECT 'A6. customer_ledger — same entry split across customers' AS check_name,
         COUNT(*)::text AS bad_rows
  FROM (SELECT 1 FROM customer_ledger
        GROUP BY team_id, entry_date, COALESCE(book,''),
                 COALESCE(bill_no,''), type, COALESCE(sno,0)
        HAVING COUNT(DISTINCT customer_id) > 1) s
), g AS (
  -- 7. customer_credit_notes: ux_crn_unique (team_id, customer_id, book,
  --    cn_number) → check if same (team, book, cn_number) split
  SELECT 'A7. customer_credit_notes — same CN split' AS check_name,
         COUNT(*)::text AS bad_rows
  FROM (SELECT 1 FROM customer_credit_notes
        WHERE cn_number IS NOT NULL
        GROUP BY team_id, COALESCE(book,''), cn_number
        HAVING COUNT(DISTINCT customer_id) > 1) s
), h AS (
  -- 8. customer_advances: same (team, rectvno) split
  SELECT 'A8. customer_advances — same rectvno split' AS check_name,
         COUNT(*)::text AS bad_rows
  FROM (SELECT 1 FROM customer_advances
        WHERE rectvno IS NOT NULL
        GROUP BY team_id, rectvno
        HAVING COUNT(DISTINCT customer_id) > 1) s
), i AS (
  -- 9. customer_receipts: dupes by (receipt_no, receipt_date, team_id)
  SELECT 'A9. customer_receipts — dup receipts' AS check_name,
         COUNT(*)::text AS bad_rows
  FROM (SELECT 1 FROM customer_receipts
        GROUP BY team_id, receipt_no, receipt_date
        HAVING COUNT(*) > 1) s
), j AS (
  -- 10. customer_billed_items: dupes by (invoice_no, item_name, bill_date,
  --     team_id)
  SELECT 'A10. customer_billed_items — dup line items' AS check_name,
         COUNT(*)::text AS bad_rows
  FROM (SELECT 1 FROM customer_billed_items
        GROUP BY team_id, invoice_no, item_name, bill_date
        HAVING COUNT(*) > 1) s
), k AS (
  -- 11. beats: name+team dupes (desktop's beat creation could double up)
  SELECT 'A11. beats — name+team dups' AS check_name,
         COUNT(*)::text AS bad_rows
  FROM (SELECT 1 FROM beats
        WHERE beat_name IS NOT NULL AND TRIM(beat_name) <> ''
        GROUP BY team_id, LOWER(TRIM(beat_name))
        HAVING COUNT(*) > 1) s
), l AS (
  -- 12. app_users: email dupes (login PIN sync added today; check)
  SELECT 'A12. app_users — email dups' AS check_name,
         COUNT(*)::text AS bad_rows
  FROM (SELECT 1 FROM app_users
        WHERE email IS NOT NULL AND TRIM(email) <> ''
        GROUP BY LOWER(TRIM(email))
        HAVING COUNT(*) > 1) s
), m AS (
  -- 13. customer_discount_schemes: dupes by (team_id, customer_id, company,
  --     item_group). Different from the CSDS dedupe in main script
  --     (which targets customer_id swap collisions). This catches
  --     plain-old duplicate insertion.
  SELECT 'A13. CSDS — duplicate scheme rows' AS check_name,
         COUNT(*)::text AS bad_rows
  FROM (SELECT 1 FROM customer_discount_schemes
        GROUP BY team_id, customer_id,
                 COALESCE(company,''), COALESCE(item_group,'')
        HAVING COUNT(*) > 1) s
)
SELECT * FROM a
UNION ALL SELECT * FROM b
UNION ALL SELECT * FROM c
UNION ALL SELECT * FROM d
UNION ALL SELECT * FROM e
UNION ALL SELECT * FROM f
UNION ALL SELECT * FROM g
UNION ALL SELECT * FROM h
UNION ALL SELECT * FROM i
UNION ALL SELECT * FROM j
UNION ALL SELECT * FROM k
UNION ALL SELECT * FROM l
UNION ALL SELECT * FROM m
ORDER BY check_name;

-- Any row with bad_rows > 0 means another sync path is double-inserting
-- the same logical record under different keys. Tell me which line(s)
-- are non-zero and I'll add the matching dedupe + fix the sync code.
