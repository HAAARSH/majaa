-- bill_books — bill book definitions (SELF / BK / G / INV / CN).
-- Source: IBOOK{yy}.DBF via IBOOK{yy}.csv (dua_export_all.py step 16).
--
-- Tiny reference table. Each company has 5-20 bill books. Used to label
-- bill numbers correctly on the Outstanding PDF ("INV-466", "BK-263") and
-- to distinguish GST-registered vs bill-of-supply vs cash-memo books when
-- computing tax.
--
-- Replace-on-sync (gated on ≥1 row): tiny and deterministic.
--
-- 2026-04-21. Apply any time — low priority.

create table if not exists public.bill_books (
  id uuid primary key default gen_random_uuid(),
  team_id text not null check (team_id in ('JA','MA')),
  book text not null,
  book_type text,
  reg_unreg text,
  serv_inv_yn text,
  gst_book_yn text,
  memo_type text,
  plain_yn text,
  performa text,
  comp_name text,
  comp_add1 text,
  comp_tin text,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

create unique index if not exists bill_books_unique_key
  on public.bill_books (team_id, book);

alter table public.bill_books enable row level security;
create policy "bill_books_select_authenticated"
  on public.bill_books for select
  to authenticated using (true);
create policy "bill_books_insert_authenticated"
  on public.bill_books for insert
  to authenticated with check (true);
create policy "bill_books_update_authenticated"
  on public.bill_books for update
  to authenticated using (true) with check (true);
create policy "bill_books_delete_authenticated"
  on public.bill_books for delete
  to authenticated using (true);
