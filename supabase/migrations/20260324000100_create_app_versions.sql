-- Create app_versions table for OTA update tracking
-- Used by deploy_update.py to register new app releases

CREATE TABLE IF NOT EXISTS public.app_versions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    version_code INTEGER NOT NULL UNIQUE,
    version_name TEXT NOT NULL,
    download_url TEXT NOT NULL,
    is_mandatory BOOLEAN NOT NULL DEFAULT false,
    release_notes TEXT,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

ALTER TABLE public.app_versions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "public_read_app_versions" ON public.app_versions;
CREATE POLICY "public_read_app_versions" ON public.app_versions
    FOR SELECT TO public USING (true);
