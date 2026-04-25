-- Extend the supabase_realtime publication with the remaining tables
-- subscribed by majaa_desktop's RealtimeService (see
-- lib/services/realtime_service.dart). Follow-up to migration
-- 20260424000007 which covered orders/order_items/customers/products.

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'beats'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.beats;
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'app_users'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.app_users;
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'user_beats'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.user_beats;
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'user_brand_access'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.user_brand_access;
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'export_batches'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.export_batches;
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'app_error_logs'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.app_error_logs;
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'visit_logs'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.visit_logs;
  END IF;
END $$;
