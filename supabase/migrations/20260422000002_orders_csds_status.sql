-- Per-order CSDS audit flag. Lets admin answer "why did this order come
-- out at this price" without re-running the cascade.
--
-- Values written by the order-create path:
--   flag_off       — CsdsPricing.enabled was false for this team; no cascade.
--   no_brand       — product.category/company was empty, so no rule match possible.
--   no_rule        — brand known but customer has no CSDS row for that brand.
--   rule_matched   — cascade applied from a CSDS rule (no free-goods).
--   scheme_matched — rule matched AND produced free_qty > 0 on at least one line.
--
-- Filled per-order (not per-line) as a cheap "what happened" marker. For
-- per-line breakdown the caller can still join order_items on csds_disc_per*.
--
-- 2026-04-22.

alter table public.orders
  add column if not exists csds_status text;

comment on column public.orders.csds_status is
  'CSDS cascade outcome for the whole order: flag_off / no_brand / no_rule / rule_matched / scheme_matched. Null for legacy rows.';

create index if not exists orders_csds_status_idx
  on public.orders (csds_status);
