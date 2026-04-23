-- Phase A.2 — audit / undo log for admin export runs
-- Every "Export" click inserts one row here. order_ids / line_item_ids_written
-- are TEXT[] because orders.id is TEXT and order_items.id is UUID-cast-to-TEXT
-- (we store all ids uniformly as TEXT so array unions/diffs are type-clean).

CREATE TABLE IF NOT EXISTS public.export_batches (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  exported_by_user_id UUID,
  exported_by_name TEXT NOT NULL,
  exported_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  invoice_date DATE NOT NULL,
  ja_file_name TEXT,
  ma_file_name TEXT,
  ja_invoice_range TEXT,
  ma_invoice_range TEXT,
  status_filter TEXT,
  date_range_start DATE,
  date_range_end DATE,
  order_ids TEXT[] NOT NULL,
  line_item_ids_written TEXT[] NOT NULL,
  orders_marked_delivered TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
  previous_statuses JSONB NOT NULL DEFAULT '{}'::JSONB
);

CREATE INDEX IF NOT EXISTS idx_export_batches_exported_at
  ON public.export_batches (exported_at DESC);

ALTER TABLE public.export_batches ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admins read export batches" ON public.export_batches;
CREATE POLICY "Admins read export batches"
  ON public.export_batches FOR SELECT
  USING (
    (SELECT role FROM public.app_users WHERE id = auth.uid()) IN ('admin', 'super_admin')
  );

DROP POLICY IF EXISTS "Admins write export batches" ON public.export_batches;
CREATE POLICY "Admins write export batches"
  ON public.export_batches FOR INSERT
  WITH CHECK (
    (SELECT role FROM public.app_users WHERE id = auth.uid()) IN ('admin', 'super_admin')
  );

DROP POLICY IF EXISTS "Super admins update export batches" ON public.export_batches;
CREATE POLICY "Super admins update export batches"
  ON public.export_batches FOR UPDATE
  USING (
    (SELECT role FROM public.app_users WHERE id = auth.uid()) = 'super_admin'
  )
  WITH CHECK (
    (SELECT role FROM public.app_users WHERE id = auth.uid()) = 'super_admin'
  );
