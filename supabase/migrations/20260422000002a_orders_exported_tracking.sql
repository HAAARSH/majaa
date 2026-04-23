-- Phase A.1 — per-order line-item export tracking
-- Adds exported_line_item_ids: the set of order_items.id (cast to TEXT) that
-- have been written into some export CSV. When cardinality matches the order's
-- order_items count, the order is "fully exported" and eligible for Delivered.
-- Stored as TEXT[] (not UUID[]) to match the existing pattern where
-- orders.id is TEXT and mixed-type arrays would complicate the array math.

ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS exported_line_item_ids TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[];

CREATE INDEX IF NOT EXISTS idx_orders_exported_line_item_ids
  ON public.orders USING GIN (exported_line_item_ids);
