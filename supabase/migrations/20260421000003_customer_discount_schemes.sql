-- customer_discount_schemes — per-customer × brand × item-group pricing rules.
-- Source: CSDS{yy}.DBF via CSDS{yy}.csv (dua_export_all.py step 15).
--
-- Empirically verified from Y206 ITTR06 (58,596 billed lines): cascade is
-- MULTIPLICATIVE, applied D1 → D2 → D3 → D4 → D5 in that order on the
-- running line total. SCHEMEPER creates free-goods as separate line items
-- (e.g. 5 paid + 1 free = 6 shipped, one line charged, one free).
--
-- Pricing function (app-side):
--   taxable = rate × qty × (1-D1/100) × (1-D2/100) × (1-D3/100) × (1-D4/100) × (1-D5/100)
--   tax     = taxable × (VATPER + SATPER + CESSPER)/100    [TAXONMRP='N']
--   free_qty = round(paid_qty × SCHEMEPER/100)
--
-- Match order (first match wins):
--   1. (acc_code, company, item_group)  — most specific
--   2. (acc_code, company, '')          — company-wide for customer
--   3. (acc_code, '', '')               — customer-wide (rare)
--
-- Wipe-per-team-on-sync: DUA treats CSDS as authoritative current state
-- (rules removed in DUA must disappear here). Gate on ≥1 matched row.
--
-- 2026-04-21. Apply before enabling Tier 4 CSDS-aware pricing.

create table if not exists public.customer_discount_schemes (
  id uuid primary key default gen_random_uuid(),
  customer_id text not null references public.customers(id) on delete cascade,
  team_id text not null check (team_id in ('JA','MA')),
  acc_code text not null,
  cust_group text,
  company text not null default '',
  item_group text not null default '',
  scheme_per numeric(6,3) not null default 0,
  disc_per numeric(6,3) not null default 0,
  disc_per_3 numeric(6,3) not null default 0,
  disc_per_5 numeric(6,3) not null default 0,
  vat_per_override numeric(6,3),
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

create unique index if not exists customer_discount_schemes_unique_key
  on public.customer_discount_schemes (team_id, customer_id, company, item_group);

create index if not exists customer_discount_schemes_lookup_idx
  on public.customer_discount_schemes (customer_id, team_id, company, item_group);

alter table public.customer_discount_schemes enable row level security;
create policy "cds_select_authenticated"
  on public.customer_discount_schemes for select
  to authenticated using (true);
create policy "cds_insert_authenticated"
  on public.customer_discount_schemes for insert
  to authenticated with check (true);
create policy "cds_update_authenticated"
  on public.customer_discount_schemes for update
  to authenticated using (true) with check (true);
create policy "cds_delete_authenticated"
  on public.customer_discount_schemes for delete
  to authenticated using (true);
