-- opening_bills — prior-year bills carried forward as line items.
-- Source: OPUBL{yy}.DBF via OPUBL{yy}.csv (dua_export_all.py step 12).
--
-- DUA's native AREAWISE OUTSTANDING report draws its prior-year bill rows
-- from OPUBL. Without this table, carry-forward bills (e.g. DEHRA GEN's
-- "ZBY-1" dated 2023-12-29 for Rs 470) show up in the app's outstanding
-- PDF with no bill detail, confusing the rep.
--
-- Upsert-only, no wipe: OPUBL shrinks monotonically as prior-year bills
-- are eventually cleared, so we never want to rebuild from scratch.
--
-- 2026-04-21. Apply via Supabase SQL editor.

create table if not exists public.opening_bills (
  id uuid primary key default gen_random_uuid(),
  customer_id text not null references public.customers(id) on delete cascade,
  team_id text not null check (team_id in ('JA','MA')),
  acc_code text not null,
  book text not null default '',
  bill_no text not null,
  bill_date date,
  bill_amount numeric(12,2) not null default 0,
  recd_amount numeric(12,2) not null default 0,
  cleared text not null default '',
  imptype text,
  sno integer,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

-- One row per (team, customer, book, bill_no) — matches the OPUBL key.
create unique index if not exists opening_bills_unique_key
  on public.opening_bills (team_id, customer_id, book, bill_no);

-- Lookup by customer (for outstanding PDF render) and by team (for bulk ops).
create index if not exists opening_bills_customer_idx
  on public.opening_bills (customer_id, team_id);
create index if not exists opening_bills_team_idx
  on public.opening_bills (team_id);

-- RLS: readable by authenticated users (same model as customer_bills).
alter table public.opening_bills enable row level security;
create policy "opening_bills_select_authenticated"
  on public.opening_bills for select
  to authenticated using (true);
create policy "opening_bills_insert_authenticated"
  on public.opening_bills for insert
  to authenticated with check (true);
create policy "opening_bills_update_authenticated"
  on public.opening_bills for update
  to authenticated using (true) with check (true);
create policy "opening_bills_delete_authenticated"
  on public.opening_bills for delete
  to authenticated using (true);
