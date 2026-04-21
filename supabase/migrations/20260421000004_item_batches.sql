-- item_batches — batch-level MRP, mfg date, expiry per item.
-- Source: ITBNO{yy}.DBF via ITBNO{yy}.csv (dua_export_all.py step 14).
--
-- Enables: near-expiry badges on product screen, FEFO picking hints,
-- batch-wise MRP override when DUA raises prices mid-year.
--
-- Upsert-only, no wipe. Batches are historical — a batch is only
-- "removed" when all of it is sold, in which case keeping the row
-- provides traceability.
--
-- 2026-04-21. Apply before enabling near-expiry UI.

create table if not exists public.item_batches (
  id uuid primary key default gen_random_uuid(),
  team_id text not null check (team_id in ('JA','MA')),
  company text not null,
  item_name text not null,
  packing text not null default '',
  batch_no text not null,
  mfg_date date,
  expiry date,
  mrp numeric(10,2) not null default 0,
  rate_no integer,
  bill_no text,
  bill_date date,
  ac_name text,
  recd_date date,
  of_case_qty integer,
  of_quantity numeric(12,2),
  od_case_qty integer,
  od_quantity numeric(12,2),
  cf_case_qty integer,
  cf_quantity numeric(12,2),
  cd_case_qty integer,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

create unique index if not exists item_batches_unique_key
  on public.item_batches (team_id, company, item_name, packing, batch_no);

create index if not exists item_batches_expiry_idx
  on public.item_batches (team_id, expiry)
  where expiry is not null;

alter table public.item_batches enable row level security;
create policy "item_batches_select_authenticated"
  on public.item_batches for select
  to authenticated using (true);
create policy "item_batches_insert_authenticated"
  on public.item_batches for insert
  to authenticated with check (true);
create policy "item_batches_update_authenticated"
  on public.item_batches for update
  to authenticated using (true) with check (true);
create policy "item_batches_delete_authenticated"
  on public.item_batches for delete
  to authenticated using (true);
