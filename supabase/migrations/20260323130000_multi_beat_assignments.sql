-- ============================================================
-- FMCG Orders App – Multi-Beat Assignments
-- Ensures every user can be tagged to multiple beats
-- Adds additional beat assignments for demo users
-- ============================================================

-- ─── Assign additional beats to all demo users ───────────────

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

    -- Fetch beat IDs ordered by beat_code
    SELECT id INTO v_beat1_id FROM public.beats ORDER BY beat_code LIMIT 1 OFFSET 0;
    SELECT id INTO v_beat2_id FROM public.beats ORDER BY beat_code LIMIT 1 OFFSET 1;
    SELECT id INTO v_beat3_id FROM public.beats ORDER BY beat_code LIMIT 1 OFFSET 2;
    SELECT id INTO v_beat4_id FROM public.beats ORDER BY beat_code LIMIT 1 OFFSET 3;

    -- James: beats 1, 2, 3 (was only 1 & 2)
    IF v_james_id IS NOT NULL AND v_beat3_id IS NOT NULL THEN
        INSERT INTO public.user_beats (user_id, beat_id)
        VALUES (v_james_id, v_beat3_id)
        ON CONFLICT (user_id, beat_id) DO NOTHING;
    END IF;

    -- Priya: beats 2, 3, 4 (was only beat 3)
    IF v_priya_id IS NOT NULL AND v_beat2_id IS NOT NULL THEN
        INSERT INTO public.user_beats (user_id, beat_id)
        VALUES (v_priya_id, v_beat2_id)
        ON CONFLICT (user_id, beat_id) DO NOTHING;
    END IF;
    IF v_priya_id IS NOT NULL AND v_beat4_id IS NOT NULL THEN
        INSERT INTO public.user_beats (user_id, beat_id)
        VALUES (v_priya_id, v_beat4_id)
        ON CONFLICT (user_id, beat_id) DO NOTHING;
    END IF;

    -- Ravi: beats 1, 3, 4 (was only beat 4)
    IF v_ravi_id IS NOT NULL AND v_beat1_id IS NOT NULL THEN
        INSERT INTO public.user_beats (user_id, beat_id)
        VALUES (v_ravi_id, v_beat1_id)
        ON CONFLICT (user_id, beat_id) DO NOTHING;
    END IF;
    IF v_ravi_id IS NOT NULL AND v_beat3_id IS NOT NULL THEN
        INSERT INTO public.user_beats (user_id, beat_id)
        VALUES (v_ravi_id, v_beat3_id)
        ON CONFLICT (user_id, beat_id) DO NOTHING;
    END IF;

EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'Multi-beat assignment seed failed: %', SQLERRM;
END $$;
