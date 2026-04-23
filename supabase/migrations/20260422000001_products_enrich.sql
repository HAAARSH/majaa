-- products table enrichment from ITEM07/11.DBF (ITEM master).
-- Source: ITEM{yy}.csv (dua_export_all.py).
--
-- Blocker for CSDS item-group matching. Without item_group + company
-- on the products row, CsdsPricing.priceFor() can only apply company-wide
-- rules (CSDS row with item_group='').
--
-- Match strategy on sync: lower(trim(name)) → update columns in place.
-- No wipe; ITEM master only adds metadata, never deletes products.
--
-- 2026-04-22. Apply before enabling CsdsPricing per-team.

alter table public.products
  add column if not exists company text,
  add column if not exists item_group text,
  add column if not exists hsn text,
  add column if not exists packqty int,
  add column if not exists vat_per numeric(6,3),
  add column if not exists sat_per numeric(6,3),
  add column if not exists cst_per numeric(6,3),
  add column if not exists cess_per numeric(6,3),
  add column if not exists tax_on_mrp text;

-- Lookup index for CsdsPricing rule match (customer + company + item_group).
create index if not exists products_company_item_group_idx
  on public.products (team_id, company, item_group);
