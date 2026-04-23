-- ─────────────────────────────────────────────────────────────────────────
-- Phase B + billing-sync tables catchup
--
-- Six tables exist in production today but have no migration file on disk.
-- They were created by hand via Supabase SQL Editor during earlier
-- sessions (Phase B CRN+ADV on 2026-04-20, billing-sync work later), and
-- `drive_sync_service.dart` reads/writes them every Drive sync.
--
-- The shapes below are reverse-engineered from a live information_schema
-- dump on 2026-04-23 against ctrmpwmnnvvsciqouqyo.supabase.co, so they
-- match prod byte-for-byte.
--
-- Purpose: make `supabase/migrations/` reproducible on a fresh environment.
-- Idempotent on production — every statement is CREATE ... IF NOT EXISTS.
--
-- Indexes: keyed on team_id because drive_sync_service clears+reinserts
-- per team on every ITTR/CRN/ADV/RECT sync. Composite team+invoice index
-- on customer_bills because the invoice export joins by invoice_no.
--
-- NOT covered here: RLS policies. Deciding on policies requires product
-- input (who sees which team's bills?). For now these tables follow the
-- service-role-writes-via-drive-sync pattern and are read client-side
-- with team_id filters. If RLS is needed later, add in a separate
-- migration.
-- ─────────────────────────────────────────────────────────────────────────

-- 1. customer_advances — unallocated advance balances synced from ADV file.
CREATE TABLE IF NOT EXISTS public.customer_advances (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id TEXT REFERENCES public.customers(id),
  team_id     TEXT NOT NULL,
  acc_code    TEXT,
  rectvno     INTEGER NOT NULL,
  amount      NUMERIC NOT NULL,
  synced_at   TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_customer_advances_team
  ON public.customer_advances(team_id);
CREATE INDEX IF NOT EXISTS idx_customer_advances_customer
  ON public.customer_advances(customer_id);

-- 2. customer_credit_notes — synced from CRN file. 1,850 type credit notes
-- from DUA (not advances, per memory reference_dua_dbf_schema.md).
CREATE TABLE IF NOT EXISTS public.customer_credit_notes (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id TEXT REFERENCES public.customers(id),
  team_id     TEXT NOT NULL,
  acc_code    TEXT,
  book        TEXT,
  cn_number   INTEGER,
  cn_date     DATE,
  bill_amount NUMERIC,
  net_amount  NUMERIC,
  reason      TEXT,
  sman_name   TEXT,
  rectvno     INTEGER,
  synced_at   TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_customer_credit_notes_team
  ON public.customer_credit_notes(team_id);
CREATE INDEX IF NOT EXISTS idx_customer_credit_notes_customer
  ON public.customer_credit_notes(customer_id);

-- 3. customer_bills — outstanding / billed invoices synced from ITTR.
-- onConflict target matches drive_sync_service upsert (customer_id,
-- invoice_no, book, team_id).
CREATE TABLE IF NOT EXISTS public.customer_bills (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id     TEXT NOT NULL REFERENCES public.customers(id),
  acc_code        TEXT NOT NULL,
  invoice_no      TEXT NOT NULL,
  book            TEXT DEFAULT '',
  bill_date       DATE,
  bill_amount     NUMERIC DEFAULT 0,
  pending_amount  NUMERIC DEFAULT 0,
  received_amount NUMERIC DEFAULT 0,
  cleared         BOOLEAN DEFAULT false,
  credit_days     INTEGER DEFAULT 0,
  team_id         TEXT NOT NULL,
  synced_at       TIMESTAMPTZ DEFAULT now(),
  sman_name       TEXT DEFAULT '',
  CONSTRAINT customer_bills_cust_inv_book_team_key
    UNIQUE (customer_id, invoice_no, book, team_id)
);
CREATE INDEX IF NOT EXISTS idx_customer_bills_team
  ON public.customer_bills(team_id);
CREATE INDEX IF NOT EXISTS idx_customer_bills_team_invoice
  ON public.customer_bills(team_id, invoice_no);
CREATE INDEX IF NOT EXISTS idx_customer_bills_pending
  ON public.customer_bills(team_id, cleared)
  WHERE cleared = false;

-- 4. customer_billed_items — line items for billed invoices. Populates
-- the "Billed" tab / order-reconciliation view.
CREATE TABLE IF NOT EXISTS public.customer_billed_items (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id TEXT REFERENCES public.customers(id),
  acc_name    TEXT NOT NULL,
  bill_date   DATE,
  invoice_no  TEXT NOT NULL,
  item_name   TEXT NOT NULL,
  packing     TEXT DEFAULT '',
  company     TEXT DEFAULT '',
  quantity    INTEGER DEFAULT 0,
  mrp         NUMERIC DEFAULT 0,
  rate        NUMERIC DEFAULT 0,
  amount      NUMERIC DEFAULT 0,
  team_id     TEXT NOT NULL,
  synced_at   TIMESTAMPTZ DEFAULT now(),
  CONSTRAINT customer_billed_items_invoice_no_item_name_bill_date_team_i_key
    UNIQUE (invoice_no, item_name, bill_date, team_id)
);
CREATE INDEX IF NOT EXISTS idx_customer_billed_items_team
  ON public.customer_billed_items(team_id);
CREATE INDEX IF NOT EXISTS idx_customer_billed_items_invoice
  ON public.customer_billed_items(team_id, invoice_no);

-- 5. customer_receipts — receipt headers synced from RECT file.
CREATE TABLE IF NOT EXISTS public.customer_receipts (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id   TEXT NOT NULL REFERENCES public.customers(id),
  acc_code      TEXT NOT NULL,
  receipt_date  DATE,
  amount        NUMERIC DEFAULT 0,
  bank_name     TEXT DEFAULT '',
  receipt_no    TEXT DEFAULT '',
  cash_yn       BOOLEAN DEFAULT false,
  team_id       TEXT NOT NULL,
  synced_at     TIMESTAMPTZ DEFAULT now(),
  CONSTRAINT customer_receipts_receipt_no_receipt_date_team_id_key
    UNIQUE (receipt_no, receipt_date, team_id)
);
CREATE INDEX IF NOT EXISTS idx_customer_receipts_team
  ON public.customer_receipts(team_id);
CREATE INDEX IF NOT EXISTS idx_customer_receipts_customer
  ON public.customer_receipts(customer_id);

-- 6. customer_receipt_bills — which invoices each receipt settles. NOTE
-- that this table has NO foreign key to customer_receipts or customer_bills
-- in production (confirmed by the live constraints query). That matches
-- the DUA sync pattern: rows arrive ahead of their parent headers in some
-- orderings, so a hard FK would block the sync. Kept FK-less here.
CREATE TABLE IF NOT EXISTS public.customer_receipt_bills (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  receipt_date    DATE,
  receipt_no      TEXT NOT NULL,
  invoice_no      TEXT NOT NULL,
  bill_date       DATE,
  bill_amount     NUMERIC DEFAULT 0,
  paid_amount     NUMERIC DEFAULT 0,
  discount        NUMERIC DEFAULT 0,
  return_amount   NUMERIC DEFAULT 0,
  scheme_amount   NUMERIC DEFAULT 0,
  team_id         TEXT NOT NULL,
  synced_at       TIMESTAMPTZ DEFAULT now(),
  CONSTRAINT customer_receipt_bills_receipt_no_invoice_no_receipt_date_t_key
    UNIQUE (receipt_no, invoice_no, receipt_date, team_id)
);
CREATE INDEX IF NOT EXISTS idx_customer_receipt_bills_team
  ON public.customer_receipt_bills(team_id);
CREATE INDEX IF NOT EXISTS idx_customer_receipt_bills_receipt
  ON public.customer_receipt_bills(team_id, receipt_no);
CREATE INDEX IF NOT EXISTS idx_customer_receipt_bills_invoice
  ON public.customer_receipt_bills(team_id, invoice_no);
