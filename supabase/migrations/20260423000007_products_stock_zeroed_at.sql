-- ─────────────────────────────────────────────────────────────────────────
-- products.stock_zeroed_at — 2-day grace window after stock hits zero
--
-- Business goal: rep shouldn't lose the ability to place an order the
-- moment a product's stock dips to zero in DUA. Two days of grace gives
-- the office time to trigger a re-stock / CSV refresh before the product
-- disappears from the rep's list.
--
-- Mechanics:
--   * New column stock_zeroed_at records WHEN stock first hit zero.
--   * A BEFORE UPDATE trigger on products maintains it automatically:
--       - old.stock_qty > 0  AND  new.stock_qty <= 0  →  set to now()
--       - new.stock_qty > 0                           →  clear to NULL
--       - else (stays at zero)                        →  keep existing
--   * Client filters: always visible; billable when stock_qty > 0 OR
--     now() - stock_zeroed_at < 2 days.
--
-- Works transparently for both:
--   • Admin edits in admin_products_tab (UPDATE).
--   • Drive sync (ITMRP) which UPSERTs the whole row — ON CONFLICT
--     fires UPDATE path, trigger still runs.
--
-- Trigger is SECURITY DEFINER because the sync service updates via
-- service_role; keeping the trigger independent of caller avoids
-- "permission denied" edge cases.
-- ─────────────────────────────────────────────────────────────────────────

-- 1. Add column.
ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS stock_zeroed_at TIMESTAMPTZ;

COMMENT ON COLUMN public.products.stock_zeroed_at IS
  'Set when stock_qty transitions from >0 to <=0. Cleared when stock goes positive again. Powers the 2-day grace window in the rep product list.';

-- 2. Index for the rep-side filter (stock_qty <= 0 AND stock_zeroed_at recent).
CREATE INDEX IF NOT EXISTS idx_products_stock_zeroed_at
  ON public.products(stock_zeroed_at)
  WHERE stock_zeroed_at IS NOT NULL;

-- 3. Trigger function — fills/clears stock_zeroed_at on every UPDATE.
-- Separate function so it can be reused if we add a stock_history table
-- later.
CREATE OR REPLACE FUNCTION public.fn_maintain_stock_zeroed_at()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Stock transitioned from positive to zero-or-negative → stamp now().
  IF COALESCE(OLD.stock_qty, 0) > 0 AND COALESCE(NEW.stock_qty, 0) <= 0 THEN
    NEW.stock_zeroed_at := now();
    RETURN NEW;
  END IF;

  -- Stock is positive now → clear the marker regardless of prior state.
  IF COALESCE(NEW.stock_qty, 0) > 0 THEN
    NEW.stock_zeroed_at := NULL;
    RETURN NEW;
  END IF;

  -- Both old and new are zero/negative → leave existing value alone so
  -- the grace window continues from when it first zeroed.
  RETURN NEW;
END;
$$;

-- 4. Attach trigger. DROP-then-CREATE is idempotent + captures any
-- function-signature changes on re-run.
DROP TRIGGER IF EXISTS trg_products_stock_zeroed_at ON public.products;
CREATE TRIGGER trg_products_stock_zeroed_at
  BEFORE UPDATE OF stock_qty ON public.products
  FOR EACH ROW
  EXECUTE FUNCTION public.fn_maintain_stock_zeroed_at();

-- 5. Also stamp on INSERT when the row lands already at zero — covers
-- brand-new products being synced in at zero stock. A separate trigger
-- so the UPDATE-only trigger above stays simple.
CREATE OR REPLACE FUNCTION public.fn_stamp_stock_zeroed_at_on_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF COALESCE(NEW.stock_qty, 0) <= 0 AND NEW.stock_zeroed_at IS NULL THEN
    NEW.stock_zeroed_at := now();
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_products_stock_zeroed_at_insert ON public.products;
CREATE TRIGGER trg_products_stock_zeroed_at_insert
  BEFORE INSERT ON public.products
  FOR EACH ROW
  EXECUTE FUNCTION public.fn_stamp_stock_zeroed_at_on_insert();

-- 6. One-time backfill: every product currently at zero gets a
-- stock_zeroed_at = now() so the grace window starts from the moment
-- this migration runs. If the office later raises stock for a product,
-- the UPDATE trigger clears it correctly.
UPDATE public.products
SET stock_zeroed_at = now()
WHERE stock_qty <= 0 AND stock_zeroed_at IS NULL;
