-- customer_ledger — full general ledger, every D/C transaction.
-- Source: LEDGER{yy}.DBF via LEDGER{yy}.csv (dua_export_all.py step 11).
--
-- Authoritative transaction source. Enables:
--   * Statement-of-Account screen (chronological running balance)
--   * Live-computed closing balance, independent of stale BILLED_COLLECTED
--   * Ledger-vs-OPNBIL reconciliation warning at ₹1 tolerance
--
-- Upsert-only, no wipe. Keyed on (team, acc_code, date, book, bill_no, sno)
-- — sno added as tiebreaker because LEDGER has multiple same-key rows (e.g.
-- discount + bank credit on the same bill on the same date).
--
-- 2026-04-21. Apply via Supabase SQL editor when ready to enable SOA UI.

create table if not exists public.customer_ledger (
  id uuid primary key default gen_random_uuid(),
  customer_id text not null references public.customers(id) on delete cascade,
  team_id text not null check (team_id in ('JA','MA')),
  acc_code text not null,
  entry_date date not null,
  pass_date date,
  book text not null default '',
  bill_no text not null default '',
  type text not null check (type in ('D','C')),
  amount numeric(12,2) not null,
  narration text,
  voutype text,
  sno integer,
  created_at timestamptz default now()
);

-- Deterministic row identity. LEDGER can have multiple same-day same-bill
-- entries (e.g. discount vs payment) so include sno.
create unique index if not exists customer_ledger_unique_key
  on public.customer_ledger (team_id, customer_id, entry_date, book, bill_no, type, sno);

create index if not exists customer_ledger_customer_date_idx
  on public.customer_ledger (customer_id, team_id, entry_date desc);
create index if not exists customer_ledger_team_date_idx
  on public.customer_ledger (team_id, entry_date desc);

alter table public.customer_ledger enable row level security;
create policy "customer_ledger_select_authenticated"
  on public.customer_ledger for select
  to authenticated using (true);
create policy "customer_ledger_insert_authenticated"
  on public.customer_ledger for insert
  to authenticated with check (true);
create policy "customer_ledger_update_authenticated"
  on public.customer_ledger for update
  to authenticated using (true) with check (true);
create policy "customer_ledger_delete_authenticated"
  on public.customer_ledger for delete
  to authenticated using (true);
