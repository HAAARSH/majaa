-- ============================================================
-- FMCG Orders App – User Beats Association
-- Links each app_user to their assigned beats
-- Also extends beats table with area and route fields
-- ============================================================

-- ─── 1. EXTEND BEATS TABLE WITH AREA & ROUTE ─────────────────

ALTER TABLE public.beats
ADD COLUMN IF NOT EXISTS area TEXT NOT NULL DEFAULT '',
ADD COLUMN IF NOT EXISTS route TEXT NOT NULL DEFAULT '';

-- ─── 2. USER_BEATS JUNCTION TABLE ────────────────────────────

CREATE TABLE IF NOT EXISTS public.user_beats (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES public.app_users(id) ON DELETE CASCADE,
    beat_id TEXT NOT NULL REFERENCES public.beats(id) ON DELETE CASCADE,
    assigned_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (user_id, beat_id)
);

-- ─── 3. INDEXES ──────────────────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_user_beats_user_id ON public.user_beats(user_id);
CREATE INDEX IF NOT EXISTS idx_user_beats_beat_id ON public.user_beats(beat_id);

-- ─── 4. ENABLE RLS ───────────────────────────────────────────

ALTER TABLE public.user_beats ENABLE ROW LEVEL SECURITY;

-- ─── 5. RLS POLICIES ─────────────────────────────────────────

DROP POLICY IF EXISTS "public_read_user_beats" ON public.user_beats;
CREATE POLICY "public_read_user_beats" ON public.user_beats
    FOR SELECT TO public USING (true);

DROP POLICY IF EXISTS "public_write_user_beats" ON public.user_beats;
CREATE POLICY "public_write_user_beats" ON public.user_beats
    FOR ALL TO public USING (true) WITH CHECK (true);

-- ─── 6. SEED: UPDATE BEATS WITH AREA & ROUTE ─────────────────

DO $$
BEGIN
    UPDATE public.beats SET area = 'North Zone', route = 'Route A' WHERE beat_code = 'BT-A';
    UPDATE public.beats SET area = 'South Zone', route = 'Route B' WHERE beat_code = 'BT-B';
    UPDATE public.beats SET area = 'East Zone',  route = 'Route C' WHERE beat_code = 'BT-C';
    UPDATE public.beats SET area = 'West Zone',  route = 'Route D' WHERE beat_code = 'BT-D';
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'Beat area/route update skipped: %', SQLERRM;
END $$;

-- ─── 7. SEED: ASSIGN BEATS TO USERS ──────────────────────────

DO $$
DECLARE
    v_james_id  UUID;
    v_admin_id  UUID;
    v_priya_id  UUID;
    v_ravi_id   UUID;
    v_beat1_id  TEXT;
    v_beat2_id  TEXT;
    v_beat3_id  TEXT;
    v_beat4_id  TEXT;
BEGIN
    -- Fetch user IDs
    SELECT id INTO v_james_id FROM public.app_users WHERE email = 'james.okonkwo@fmcgorders.com' LIMIT 1;
    SELECT id INTO v_admin_id FROM public.app_users WHERE email = 'admin@fmcgorders.com' LIMIT 1;
    SELECT id INTO v_priya_id FROM public.app_users WHERE email = 'priya.sharma@fmcgorders.com' LIMIT 1;
    SELECT id INTO v_ravi_id  FROM public.app_users WHERE email = 'ravi.kumar@fmcgorders.com' LIMIT 1;

    -- Fetch beat IDs (ordered by beat_code)
    SELECT id INTO v_beat1_id FROM public.beats ORDER BY beat_code LIMIT 1 OFFSET 0;
    SELECT id INTO v_beat2_id FROM public.beats ORDER BY beat_code LIMIT 1 OFFSET 1;
    SELECT id INTO v_beat3_id FROM public.beats ORDER BY beat_code LIMIT 1 OFFSET 2;
    SELECT id INTO v_beat4_id FROM public.beats ORDER BY beat_code LIMIT 1 OFFSET 3;

    -- Assign beats to James (beats 1 & 2)
    IF v_james_id IS NOT NULL AND v_beat1_id IS NOT NULL THEN
        INSERT INTO public.user_beats (user_id, beat_id)
        VALUES (v_james_id, v_beat1_id)
        ON CONFLICT (user_id, beat_id) DO NOTHING;
    END IF;

    IF v_james_id IS NOT NULL AND v_beat2_id IS NOT NULL THEN
        INSERT INTO public.user_beats (user_id, beat_id)
        VALUES (v_james_id, v_beat2_id)
        ON CONFLICT (user_id, beat_id) DO NOTHING;
    END IF;

    -- Assign all beats to Admin
    IF v_admin_id IS NOT NULL AND v_beat1_id IS NOT NULL THEN
        INSERT INTO public.user_beats (user_id, beat_id)
        VALUES (v_admin_id, v_beat1_id)
        ON CONFLICT (user_id, beat_id) DO NOTHING;
    END IF;
    IF v_admin_id IS NOT NULL AND v_beat2_id IS NOT NULL THEN
        INSERT INTO public.user_beats (user_id, beat_id)
        VALUES (v_admin_id, v_beat2_id)
        ON CONFLICT (user_id, beat_id) DO NOTHING;
    END IF;
    IF v_admin_id IS NOT NULL AND v_beat3_id IS NOT NULL THEN
        INSERT INTO public.user_beats (user_id, beat_id)
        VALUES (v_admin_id, v_beat3_id)
        ON CONFLICT (user_id, beat_id) DO NOTHING;
    END IF;
    IF v_admin_id IS NOT NULL AND v_beat4_id IS NOT NULL THEN
        INSERT INTO public.user_beats (user_id, beat_id)
        VALUES (v_admin_id, v_beat4_id)
        ON CONFLICT (user_id, beat_id) DO NOTHING;
    END IF;

    -- Assign beats 3 to Priya
    IF v_priya_id IS NOT NULL AND v_beat3_id IS NOT NULL THEN
        INSERT INTO public.user_beats (user_id, beat_id)
        VALUES (v_priya_id, v_beat3_id)
        ON CONFLICT (user_id, beat_id) DO NOTHING;
    END IF;

    -- Assign beat 4 to Ravi
    IF v_ravi_id IS NOT NULL AND v_beat4_id IS NOT NULL THEN
        INSERT INTO public.user_beats (user_id, beat_id)
        VALUES (v_ravi_id, v_beat4_id)
        ON CONFLICT (user_id, beat_id) DO NOTHING;
    END IF;

EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'User beats seed failed: %', SQLERRM;
END $$;
