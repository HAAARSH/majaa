-- Phase A.3 — per-customer brand → billing-team routing memory
-- Used by Feature 2's Organic India picker to remember last choice.
-- customer_id matches customers.id (TEXT); brand_name is a free-form label
-- that the export flow matches against products.category (Organic India today).

CREATE TABLE IF NOT EXISTS public.customer_brand_routing (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id TEXT NOT NULL REFERENCES public.customers(id) ON DELETE CASCADE,
  brand_name TEXT NOT NULL,
  billing_team_id TEXT NOT NULL CHECK (billing_team_id IN ('JA', 'MA')),
  set_by_user_id UUID,
  set_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (customer_id, brand_name)
);

CREATE INDEX IF NOT EXISTS idx_customer_brand_routing_lookup
  ON public.customer_brand_routing (customer_id, brand_name);

ALTER TABLE public.customer_brand_routing ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admins manage routing" ON public.customer_brand_routing;
CREATE POLICY "Admins manage routing"
  ON public.customer_brand_routing FOR ALL
  USING (
    (SELECT role FROM public.app_users WHERE id = auth.uid()) IN ('admin', 'super_admin')
  )
  WITH CHECK (
    (SELECT role FROM public.app_users WHERE id = auth.uid()) IN ('admin', 'super_admin')
  );
