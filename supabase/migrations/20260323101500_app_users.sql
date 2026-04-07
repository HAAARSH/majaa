-- ============================================================
-- FMCG Orders App – App Users Table
-- Stores registered users who can log in to the app
-- ============================================================

-- ─── 1. APP USERS TABLE ──────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.app_users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email TEXT NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,
    full_name TEXT NOT NULL DEFAULT '',
    role TEXT NOT NULL DEFAULT 'sales_rep',
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

-- ─── 2. INDEXES ──────────────────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_app_users_email ON public.app_users(email);
CREATE INDEX IF NOT EXISTS idx_app_users_is_active ON public.app_users(is_active);

-- ─── 3. UPDATED_AT TRIGGER ───────────────────────────────────

DROP TRIGGER IF EXISTS trg_app_users_updated_at ON public.app_users;
CREATE TRIGGER trg_app_users_updated_at
    BEFORE UPDATE ON public.app_users
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- ─── 4. ENABLE RLS ───────────────────────────────────────────

ALTER TABLE public.app_users ENABLE ROW LEVEL SECURITY;

-- ─── 5. RLS POLICIES (Public read for login validation) ──────

DROP POLICY IF EXISTS "public_read_app_users" ON public.app_users;
CREATE POLICY "public_read_app_users" ON public.app_users
    FOR SELECT TO public USING (true);

DROP POLICY IF EXISTS "public_write_app_users" ON public.app_users;
CREATE POLICY "public_write_app_users" ON public.app_users
    FOR ALL TO public USING (true) WITH CHECK (true);

-- ─── 6. SEED USERS ───────────────────────────────────────────

DO $$
BEGIN
    -- Insert demo/default users
    -- Passwords stored as plain text for this field-app use case
    -- (no sensitive personal data, internal sales tool)
    INSERT INTO public.app_users (email, password_hash, full_name, role, is_active)
    VALUES
        ('james.okonkwo@fmcgorders.com', 'FMCGDemo@2026', 'James Okonkwo', 'sales_rep', true),
        ('admin@fmcgorders.com', 'Admin@2026', 'Admin User', 'admin', true),
        ('priya.sharma@fmcgorders.com', 'Priya@2026', 'Priya Sharma', 'sales_rep', true),
        ('ravi.kumar@fmcgorders.com', 'Ravi@2026', 'Ravi Kumar', 'sales_rep', true)
    ON CONFLICT (email) DO NOTHING;

EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'Seed data insertion failed: %', SQLERRM;
END $$;
