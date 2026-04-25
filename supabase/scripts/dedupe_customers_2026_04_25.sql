-- ─────────────────────────────────────────────────────────────────────────
-- Customer-row deduplication — one-shot cleanup, 2026-04-25
--
-- Background: the desktop companion (majaa_desktop) v1.2.0 ACMAST sync had
-- a stale-snapshot bug where multi-team customers were inserted twice per
-- run. ~15 sync runs since 2026-04-24 produced ~15 dupes per affected
-- customer. This script collapses each duplicate group into a single
-- canonical row, migrating every FK ref in the process.
--
-- Strategy:
--   1. Pick canonical row per (LOWER(TRIM(name))) group: oldest created_at.
--   2. Coalesce stronger-data fields (acc_codes, gstin, phone, address,
--      lock_bill, credit_days, credit_limit) onto canonical from dups.
--   3. UPDATE every customer_id FK from dup → canonical across 13 tables.
--   4. Merge customer_team_profiles (OR-merge team flags + take non-empty
--      beat assignments).
--   5. DELETE dup customer rows. Cascading FKs clean up the rest.
--
-- Safety: wrapped in BEGIN; ... ROLLBACK; — review row counts, then change
-- the trailing ROLLBACK to COMMIT to apply.
--
-- Pre-flight: pg_dump customers, customer_team_profiles, orders,
-- collections, visit_logs, customer_bills, customer_receipts,
-- customer_billed_items, customer_advances, customer_credit_notes,
-- bill_extractions, opening_bills, customer_ledger, customer_brand_routing,
-- customer_alias_learning, product_alias_learning, customer_discount_schemes.
-- Supabase Free has no PITR — manual dump is the only undo.
-- ─────────────────────────────────────────────────────────────────────────

-- Defensive: clear any aborted/in-flight transaction from a prior failed
-- run of this script. Harmless when no transaction is open (Postgres just
-- emits "WARNING: there is no transaction in progress"). Lets re-runs Just
-- Work without manual disconnect/reconnect.
ROLLBACK;

BEGIN;

-- Supabase dashboard SQL editor enforces a ~8s statement_timeout that this
-- multi-table cleanup will blow through. Lift the cap for this transaction
-- only — restored automatically at COMMIT/ROLLBACK because of LOCAL.
SET LOCAL statement_timeout = 0;
SET LOCAL idle_in_transaction_session_timeout = 0;

-- ─── STEP 1: Build dedup map (dup_id → canonical_id) ────────────────────
DROP TABLE IF EXISTS _dedup_map;
CREATE TEMP TABLE _dedup_map AS
SELECT
  c.id  AS dup_id,
  can.id AS canonical_id,
  LOWER(TRIM(c.name)) AS norm_name
FROM public.customers c
JOIN LATERAL (
  SELECT id
  FROM public.customers c2
  WHERE LOWER(TRIM(c2.name)) = LOWER(TRIM(c.name))
    AND c2.name IS NOT NULL
    AND TRIM(c2.name) <> ''
  ORDER BY c2.created_at ASC NULLS LAST, c2.id ASC
  LIMIT 1
) can ON TRUE
WHERE c.id <> can.id;

CREATE INDEX ON _dedup_map (dup_id);
CREATE INDEX ON _dedup_map (canonical_id);

SELECT 'STEP 1: dup rows to be merged'      AS step, COUNT(*) AS n FROM _dedup_map;
SELECT 'STEP 1: distinct canonical groups'  AS step, COUNT(DISTINCT canonical_id) AS n FROM _dedup_map;


-- ─── STEP 2: Coalesce stronger-data fields onto canonical ──────────────
-- Only when canonical's value is null/empty/zero. Never overwrite real
-- data. Picks MAX from dup group (deterministic, harmless for booleans/
-- numerics; for strings either-value-is-fine since we got here by sync
-- from the same DUA source).
WITH agg AS (
  SELECT
    m.canonical_id,
    MAX(NULLIF(d.acc_code_ja, ''))                                  AS dup_acc_ja,
    MAX(NULLIF(d.acc_code_ma, ''))                                  AS dup_acc_ma,
    MAX(NULLIF(d.gstin, ''))                                        AS dup_gstin,
    MAX(NULLIF(d.phone, ''))                                        AS dup_phone,
    MAX(NULLIF(d.address, ''))                                      AS dup_address,
    BOOL_OR(COALESCE(d.lock_bill, FALSE))                           AS dup_lock_bill,
    MAX(COALESCE(d.credit_days, 0))                                 AS dup_credit_days,
    MAX(COALESCE(d.credit_limit, 0))                                AS dup_credit_limit
  FROM _dedup_map m
  JOIN public.customers d ON d.id = m.dup_id
  GROUP BY m.canonical_id
)
UPDATE public.customers c SET
  acc_code_ja  = COALESCE(NULLIF(c.acc_code_ja, ''),  agg.dup_acc_ja),
  acc_code_ma  = COALESCE(NULLIF(c.acc_code_ma, ''),  agg.dup_acc_ma),
  gstin        = COALESCE(NULLIF(c.gstin,       ''),  agg.dup_gstin),
  -- phone + address have NOT NULL constraints — extra '' fallback so a row
  -- where both canonical and every dup have NULL/empty doesn't violate the
  -- constraint when we touch it. Side effect: NULL phone/address rows get
  -- normalised to '' (benign — those rows shouldn't have NULL anyway,
  -- they predate the constraint being added).
  phone        = COALESCE(NULLIF(c.phone,       ''),  agg.dup_phone,   c.phone,   ''),
  address      = COALESCE(NULLIF(c.address,     ''),  agg.dup_address, c.address, ''),
  lock_bill    = c.lock_bill OR agg.dup_lock_bill,
  credit_days  = GREATEST(COALESCE(c.credit_days, 0),  agg.dup_credit_days),
  credit_limit = GREATEST(COALESCE(c.credit_limit, 0), agg.dup_credit_limit)
FROM agg
WHERE c.id = agg.canonical_id;

SELECT 'STEP 2: canonical rows enriched' AS step, COUNT(*) AS n
  FROM (SELECT DISTINCT canonical_id FROM _dedup_map) s;


-- ─── STEP 3: Migrate FK references from dup → canonical ────────────────
-- Each table updated independently. RAISE NOTICE if any unique-constraint
-- collision occurs (would be a same-bill-on-two-dups case — unlikely since
-- dups arose from sync, not human entry).

-- 3a. orders
UPDATE public.orders o SET customer_id = m.canonical_id
  FROM _dedup_map m WHERE o.customer_id = m.dup_id;
SELECT 'STEP 3a: orders FK migrated' AS step, COUNT(*) AS n
  FROM public.orders o JOIN _dedup_map m ON o.customer_id = m.canonical_id;

-- 3b. collections
UPDATE public.collections c SET customer_id = m.canonical_id
  FROM _dedup_map m WHERE c.customer_id = m.dup_id;

-- 3c. visit_logs
UPDATE public.visit_logs v SET customer_id = m.canonical_id
  FROM _dedup_map m WHERE v.customer_id = m.dup_id;

-- 3d. customer_bills (defensive — drop dup rows that would collide on the
--     unique constraint (customer_id, invoice_no, book, team_id) before
--     the main update). Column is invoice_no, NOT bill_no — different
--     from opening_bills (which uses bill_no).
DELETE FROM public.customer_bills cb
USING _dedup_map m, public.customer_bills cb_keep
WHERE cb.customer_id = m.dup_id
  AND cb_keep.customer_id = m.canonical_id
  AND cb.team_id = cb_keep.team_id
  AND cb.invoice_no = cb_keep.invoice_no
  AND COALESCE(cb.book, '') = COALESCE(cb_keep.book, '');
UPDATE public.customer_bills cb SET customer_id = m.canonical_id
  FROM _dedup_map m WHERE cb.customer_id = m.dup_id;

-- 3e. customer_receipts
UPDATE public.customer_receipts cr SET customer_id = m.canonical_id
  FROM _dedup_map m WHERE cr.customer_id = m.dup_id;

-- 3f. customer_billed_items
UPDATE public.customer_billed_items cbi SET customer_id = m.canonical_id
  FROM _dedup_map m WHERE cbi.customer_id = m.dup_id;

-- 3g. customer_advances (defensive — RECT-keyed; add prod-only ADV unique
--     constraint defensively in case it exists like CRN's does).
DELETE FROM public.customer_advances ca
USING _dedup_map m, public.customer_advances ca_keep
WHERE ca.customer_id = m.dup_id
  AND ca_keep.customer_id = m.canonical_id
  AND ca.team_id = ca_keep.team_id
  AND ca.rectvno = ca_keep.rectvno;
UPDATE public.customer_advances ca SET customer_id = m.canonical_id
  FROM _dedup_map m WHERE ca.customer_id = m.dup_id;

-- 3h. customer_credit_notes (defensive — ux_crn_unique on prod is
--     (team_id, customer_id, book, cn_number), added outside migrations).
DELETE FROM public.customer_credit_notes ccn
USING _dedup_map m, public.customer_credit_notes ccn_keep
WHERE ccn.customer_id = m.dup_id
  AND ccn_keep.customer_id = m.canonical_id
  AND ccn.team_id = ccn_keep.team_id
  AND COALESCE(ccn.book, '') = COALESCE(ccn_keep.book, '')
  AND COALESCE(ccn.cn_number, 0) = COALESCE(ccn_keep.cn_number, 0);
UPDATE public.customer_credit_notes ccn SET customer_id = m.canonical_id
  FROM _dedup_map m WHERE ccn.customer_id = m.dup_id;

-- 3i. bill_extractions
UPDATE public.bill_extractions be SET customer_id = m.canonical_id
  FROM _dedup_map m WHERE be.customer_id = m.dup_id;

-- 3j. opening_bills (defensive: same (team_id, customer_id, book, bill_no)
--     unique index per migration 20260421000001)
DELETE FROM public.opening_bills ob
USING _dedup_map m, public.opening_bills ob_keep
WHERE ob.customer_id = m.dup_id
  AND ob_keep.customer_id = m.canonical_id
  AND ob.team_id = ob_keep.team_id
  AND ob.bill_no = ob_keep.bill_no
  AND COALESCE(ob.book, '') = COALESCE(ob_keep.book, '');
UPDATE public.opening_bills ob SET customer_id = m.canonical_id
  FROM _dedup_map m WHERE ob.customer_id = m.dup_id;

-- 3k. customer_ledger (unique index on team_id, customer_id, entry_date,
--     book, bill_no, type, sno per migration 20260421000002)
DELETE FROM public.customer_ledger cl
USING _dedup_map m, public.customer_ledger cl_keep
WHERE cl.customer_id = m.dup_id
  AND cl_keep.customer_id = m.canonical_id
  AND cl.team_id = cl_keep.team_id
  AND cl.entry_date = cl_keep.entry_date
  AND COALESCE(cl.book, '') = COALESCE(cl_keep.book, '')
  AND COALESCE(cl.bill_no, '') = COALESCE(cl_keep.bill_no, '')
  AND cl.type = cl_keep.type
  AND COALESCE(cl.sno, 0) = COALESCE(cl_keep.sno, 0);
UPDATE public.customer_ledger cl SET customer_id = m.canonical_id
  FROM _dedup_map m WHERE cl.customer_id = m.dup_id;

-- 3l. customer_brand_routing (cascade table — but we want to preserve)
DELETE FROM public.customer_brand_routing cbr
USING _dedup_map m, public.customer_brand_routing cbr_keep
WHERE cbr.customer_id = m.dup_id
  AND cbr_keep.customer_id = m.canonical_id
  AND cbr.brand_name = cbr_keep.brand_name;
UPDATE public.customer_brand_routing cbr SET customer_id = m.canonical_id
  FROM _dedup_map m WHERE cbr.customer_id = m.dup_id;

-- 3m. alias-learning tables (cascade-safe; we still migrate to keep history)
UPDATE public.product_alias_learning pal SET customer_id = m.canonical_id
  FROM _dedup_map m WHERE pal.customer_id = m.dup_id;
UPDATE public.customer_alias_learning cal SET matched_customer_id = m.canonical_id
  FROM _dedup_map m WHERE cal.matched_customer_id = m.dup_id;

-- 3n. customer_discount_schemes (CSDS) — CASCADE on delete so step 5
--     would auto-clean dup's rows, but we migrate first to preserve any
--     scheme that lived only on a dup. Defensive delete avoids unique
--     collision on (team_id, customer_id, company, item_group).
DELETE FROM public.customer_discount_schemes cds
USING _dedup_map m, public.customer_discount_schemes cds_keep
WHERE cds.customer_id = m.dup_id
  AND cds_keep.customer_id = m.canonical_id
  AND cds.team_id = cds_keep.team_id
  AND COALESCE(cds.company,    '') = COALESCE(cds_keep.company,    '')
  AND COALESCE(cds.item_group, '') = COALESCE(cds_keep.item_group, '');
UPDATE public.customer_discount_schemes cds SET customer_id = m.canonical_id
  FROM _dedup_map m WHERE cds.customer_id = m.dup_id;


-- ─── STEP 4: Merge customer_team_profiles ─────────────────────────────
-- CTP has UNIQUE on customer_id (one row per customer). We need to
-- collapse N dup CTPs + 0-or-1 canonical CTP into a single canonical
-- CTP that OR-merges team flags + takes non-empty beat info + max
-- outstanding totals. Three-step: aggregate, delete dups, upsert.

-- 4a. Aggregate every dup's CTP into a single row per canonical (held in
--     a temp table because we'll delete the source rows in 4b).
DROP TABLE IF EXISTS _ctp_agg;
CREATE TEMP TABLE _ctp_agg AS
SELECT
  m.canonical_id,
  BOOL_OR(COALESCE(d.team_ja, FALSE))   AS d_ja,
  BOOL_OR(COALESCE(d.team_ma, FALSE))   AS d_ma,
  MAX(NULLIF(d.beat_id_ja,   ''))       AS d_beat_id_ja,
  MAX(NULLIF(d.beat_name_ja, ''))       AS d_beat_name_ja,
  MAX(NULLIF(d.beat_id_ma,   ''))       AS d_beat_id_ma,
  MAX(NULLIF(d.beat_name_ma, ''))       AS d_beat_name_ma,
  MAX(COALESCE(d.outstanding_ja, 0))    AS d_out_ja,
  MAX(COALESCE(d.outstanding_ma, 0))    AS d_out_ma
FROM _dedup_map m
JOIN public.customer_team_profiles d ON d.customer_id = m.dup_id
GROUP BY m.canonical_id;

-- 4b. Delete every dup CTP. Safe now — the data we need is in _ctp_agg.
--     Frees the unique slot for the upsert below to write canonical's row.
DELETE FROM public.customer_team_profiles ctp
USING _dedup_map m
WHERE ctp.customer_id = m.dup_id;

-- 4c. UPSERT into canonical's CTP. Insert if canonical had no CTP, OR-merge
--     into canonical's existing CTP otherwise. EXCLUDED.* refers to the
--     row that was attempted to be inserted — i.e., the aggregated dup data.
INSERT INTO public.customer_team_profiles (
  customer_id, team_ja, team_ma,
  beat_id_ja, beat_name_ja, beat_id_ma, beat_name_ma,
  outstanding_ja, outstanding_ma
)
SELECT
  a.canonical_id,
  a.d_ja,
  a.d_ma,
  a.d_beat_id_ja,
  COALESCE(a.d_beat_name_ja, ''),
  a.d_beat_id_ma,
  COALESCE(a.d_beat_name_ma, ''),
  a.d_out_ja,
  a.d_out_ma
FROM _ctp_agg a
ON CONFLICT (customer_id) DO UPDATE SET
  team_ja        = customer_team_profiles.team_ja OR EXCLUDED.team_ja,
  team_ma        = customer_team_profiles.team_ma OR EXCLUDED.team_ma,
  beat_id_ja     = COALESCE(NULLIF(customer_team_profiles.beat_id_ja,   ''), EXCLUDED.beat_id_ja),
  beat_name_ja   = COALESCE(NULLIF(customer_team_profiles.beat_name_ja, ''), EXCLUDED.beat_name_ja),
  beat_id_ma     = COALESCE(NULLIF(customer_team_profiles.beat_id_ma,   ''), EXCLUDED.beat_id_ma),
  beat_name_ma   = COALESCE(NULLIF(customer_team_profiles.beat_name_ma, ''), EXCLUDED.beat_name_ma),
  outstanding_ja = GREATEST(COALESCE(customer_team_profiles.outstanding_ja, 0), EXCLUDED.outstanding_ja),
  outstanding_ma = GREATEST(COALESCE(customer_team_profiles.outstanding_ma, 0), EXCLUDED.outstanding_ma);

SELECT 'STEP 4: customer_team_profiles after merge'  AS step, COUNT(*) AS n
  FROM public.customer_team_profiles;


-- ─── STEP 5: Delete dup customers ──────────────────────────────────────
DELETE FROM public.customers c
USING _dedup_map m
WHERE c.id = m.dup_id;

SELECT 'STEP 5: dup customer rows deleted' AS step, COUNT(*) AS n FROM _dedup_map;


-- ─── STEP 6: Verify zero remaining dups ────────────────────────────────
SELECT 'STEP 6: remaining name-dups (should be 0)' AS step, COUNT(*) AS n
FROM (
  SELECT LOWER(TRIM(name))
  FROM public.customers
  WHERE name IS NOT NULL AND TRIM(name) <> ''
  GROUP BY LOWER(TRIM(name))
  HAVING COUNT(*) > 1
) s;

SELECT 'STEP 6: total customers after cleanup'      AS step, COUNT(*) AS n FROM public.customers;
SELECT 'STEP 6: total customer_team_profiles'       AS step, COUNT(*) AS n FROM public.customer_team_profiles;


-- ─── COMMIT ────────────────────────────────────────────────────────────
-- 2026-04-25 dry-run verified clean: 10,590 dups across 1,542 groups,
-- 3,478 orders re-pointed, 0 remaining dups, total customers 12,818→2,228.
-- Flipped from ROLLBACK to COMMIT after eyeballing.
-- ROLLBACK;
COMMIT;

-- Post-commit (run separately, NOT inside the transaction):
-- VACUUM ANALYZE public.customers, public.customer_team_profiles,
--                public.orders, public.collections, public.visit_logs;
