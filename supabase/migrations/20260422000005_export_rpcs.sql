-- Phase A.4 — atomic export-finalize + undo RPCs
-- finalize_export_batch: append written line-item ids, detect fully-exported
-- orders, optionally flip their status to Delivered, and write the audit row
-- in ONE transaction. Guards against the 0-items empty-order false positive.
-- undo_export_batch: super-admin-only restore of previous statuses and
-- removal of the written line-item ids from the per-order tracking array.

CREATE OR REPLACE FUNCTION public.finalize_export_batch(
  p_order_ids TEXT[],
  p_line_item_ids_written TEXT[],
  p_mark_delivered BOOLEAN,
  p_batch_metadata JSONB
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_batch_id UUID;
  v_fully_exported_order_ids TEXT[];
  v_previous_statuses JSONB;
BEGIN
  -- 1. Append written line-item ids to each order's exported_line_item_ids
  --    (deduped). DISTINCT-via-set guards against double-exports.
  UPDATE public.orders o
  SET exported_line_item_ids = (
    SELECT COALESCE(ARRAY_AGG(DISTINCT id_txt), ARRAY[]::TEXT[])
    FROM unnest(o.exported_line_item_ids || p_line_item_ids_written) AS id_txt
  )
  WHERE o.id = ANY(p_order_ids);

  -- 2. Identify fully-exported orders. Guarded against orders with zero
  --    line items: cardinality(empty)=0 equals count(0) and would falsely
  --    mark the order Delivered. The EXISTS check blocks that.
  SELECT ARRAY_AGG(o.id) INTO v_fully_exported_order_ids
  FROM public.orders o
  WHERE o.id = ANY(p_order_ids)
    AND EXISTS (SELECT 1 FROM public.order_items oi WHERE oi.order_id = o.id)
    AND (
      SELECT COUNT(*) FROM public.order_items oi WHERE oi.order_id = o.id
    ) = (
      SELECT COUNT(*) FROM public.order_items oi
      WHERE oi.order_id = o.id
        AND oi.id::TEXT = ANY(o.exported_line_item_ids)
    );

  -- 3. If admin confirmed, flip status to Delivered and capture previous
  --    statuses for undo. Skip orders already Delivered so the previous
  --    status map records a meaningful rollback target.
  IF p_mark_delivered AND v_fully_exported_order_ids IS NOT NULL THEN
    SELECT COALESCE(jsonb_object_agg(o.id, o.status::TEXT), '{}'::JSONB)
      INTO v_previous_statuses
    FROM public.orders o
    WHERE o.id = ANY(v_fully_exported_order_ids)
      AND o.status IS DISTINCT FROM 'Delivered';

    UPDATE public.orders o
    SET status = 'Delivered'
    WHERE o.id = ANY(v_fully_exported_order_ids)
      AND o.status IS DISTINCT FROM 'Delivered';
  END IF;

  -- 4. Write the audit row. Always insert — even on cancel — so the
  --    line-item tracking is captured for the next export's diff.
  INSERT INTO public.export_batches (
    exported_by_user_id, exported_by_name, invoice_date,
    ja_file_name, ma_file_name, ja_invoice_range, ma_invoice_range,
    status_filter, date_range_start, date_range_end,
    order_ids, line_item_ids_written,
    orders_marked_delivered, previous_statuses
  )
  VALUES (
    auth.uid(),
    COALESCE(
      (SELECT full_name FROM public.app_users WHERE id = auth.uid()),
      'unknown'
    ),
    (p_batch_metadata->>'invoice_date')::DATE,
    p_batch_metadata->>'ja_file_name',
    p_batch_metadata->>'ma_file_name',
    p_batch_metadata->>'ja_invoice_range',
    p_batch_metadata->>'ma_invoice_range',
    p_batch_metadata->>'status_filter',
    NULLIF(p_batch_metadata->>'date_range_start', '')::DATE,
    NULLIF(p_batch_metadata->>'date_range_end', '')::DATE,
    p_order_ids,
    p_line_item_ids_written,
    CASE WHEN p_mark_delivered
         THEN COALESCE(v_fully_exported_order_ids, ARRAY[]::TEXT[])
         ELSE ARRAY[]::TEXT[]
    END,
    COALESCE(v_previous_statuses, '{}'::JSONB)
  )
  RETURNING id INTO v_batch_id;

  RETURN v_batch_id;
END;
$$;

-- Lock down who can invoke the RPC at the Postgres level in addition to RLS
-- on the underlying tables.
REVOKE ALL ON FUNCTION public.finalize_export_batch(TEXT[], TEXT[], BOOLEAN, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.finalize_export_batch(TEXT[], TEXT[], BOOLEAN, JSONB) TO authenticated;


CREATE OR REPLACE FUNCTION public.undo_export_batch(p_batch_id UUID)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_batch RECORD;
  v_caller_role TEXT;
  v_order_id TEXT;
  v_prev_status TEXT;
BEGIN
  SELECT role INTO v_caller_role
  FROM public.app_users
  WHERE id = auth.uid();

  IF v_caller_role IS DISTINCT FROM 'super_admin' THEN
    RAISE EXCEPTION 'Only super_admin can undo export batches';
  END IF;

  SELECT * INTO v_batch FROM public.export_batches WHERE id = p_batch_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Batch not found: %', p_batch_id;
  END IF;

  -- 1. Restore previous statuses exactly as captured.
  FOR v_order_id, v_prev_status IN
    SELECT key, value FROM jsonb_each_text(v_batch.previous_statuses)
  LOOP
    UPDATE public.orders
    SET status = v_prev_status::public.order_status
    WHERE id = v_order_id;
  END LOOP;

  -- 2. Remove this batch's written ids from each touched order's tracking.
  --    Keep other batches' tracking intact via set-difference.
  UPDATE public.orders o
  SET exported_line_item_ids = (
    SELECT COALESCE(ARRAY_AGG(id_txt), ARRAY[]::TEXT[])
    FROM unnest(o.exported_line_item_ids) AS id_txt
    WHERE id_txt <> ALL(v_batch.line_item_ids_written)
  )
  WHERE o.id = ANY(v_batch.order_ids);

  -- 3. Soft-clear the batch's undo fields so the row stays for history but
  --    can't be undone twice.
  UPDATE public.export_batches
  SET orders_marked_delivered = ARRAY[]::TEXT[],
      previous_statuses = '{}'::JSONB
  WHERE id = p_batch_id;
END;
$$;

REVOKE ALL ON FUNCTION public.undo_export_batch(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.undo_export_batch(UUID) TO authenticated;
