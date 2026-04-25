-- ─────────────────────────────────────────────────────────────────────────
-- Per-user login PIN. Lets a rep re-mint a Supabase JWT after the cached
-- one expires by entering a 4-digit PIN; the device combines that PIN with
-- the password kept in flutter_secure_storage to call signInWithPassword.
--
-- Strict isolation from the existing admin PIN (PinService, default 0903,
-- gates destructive ops). Different storage, different RPCs, different UI.
--
-- Resolves users with the same id-or-email fallback used in
-- 20260424000005_fix_billing_rls_email_fallback.sql so legacy auth-uid-
-- mismatched users (sa@gmail.com, ranjeet@majaa.com) work end-to-end.
--
-- Additive only: two nullable columns + three RPCs. No existing column,
-- policy, or trigger is modified.
-- ─────────────────────────────────────────────────────────────────────────

ALTER TABLE public.app_users ADD COLUMN IF NOT EXISTS login_pin_hash TEXT;
ALTER TABLE public.app_users ADD COLUMN IF NOT EXISTS login_pin_set_at TIMESTAMPTZ;

CREATE EXTENSION IF NOT EXISTS pgcrypto;


-- ═════════════════════════════════════════════════════════════════════════
-- set_login_pin(p_pin) — authenticated. Hashes server-side via bcrypt and
-- writes to the caller's app_users row.
-- ═════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.set_login_pin(p_pin TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
-- 'extensions' is needed so unqualified crypt() / gen_salt() resolve on
-- Supabase, where pgcrypto lives in the extensions schema.
SET search_path = public, extensions
AS $$
BEGIN
  IF p_pin !~ '^[0-9]{4}$' THEN
    RAISE EXCEPTION 'PIN must be exactly 4 digits';
  END IF;

  UPDATE public.app_users
     SET login_pin_hash   = crypt(p_pin, gen_salt('bf')),
         login_pin_set_at = now()
   WHERE id::TEXT = auth.uid()::TEXT
      OR email   = (auth.jwt() ->> 'email');

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No app_users row for current session';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.set_login_pin(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_login_pin(TEXT) TO authenticated;


-- ═════════════════════════════════════════════════════════════════════════
-- verify_login_pin(p_email, p_pin) — anon-callable. Returns BOOLEAN.
-- FALSE for nonexistent email or unset PIN — no information leak.
-- ═════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.verify_login_pin(p_email TEXT, p_pin TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
-- 'extensions' so unqualified crypt() resolves on Supabase.
SET search_path = public, extensions
AS $$
DECLARE
  v_hash TEXT;
BEGIN
  SELECT login_pin_hash INTO v_hash
    FROM public.app_users
   WHERE lower(email) = lower(trim(p_email))
     AND is_active = TRUE
   LIMIT 1;

  IF v_hash IS NULL THEN
    RETURN FALSE;
  END IF;

  RETURN v_hash = crypt(p_pin, v_hash);
END;
$$;

REVOKE ALL ON FUNCTION public.verify_login_pin(TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.verify_login_pin(TEXT, TEXT) TO anon, authenticated;


-- ═════════════════════════════════════════════════════════════════════════
-- has_login_pin(p_email) — anon-callable. Used by the splash to decide
-- between PIN dialog vs password screen when the JWT can't refresh.
-- ═════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.has_login_pin(p_email TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM public.app_users
     WHERE lower(email) = lower(trim(p_email))
       AND is_active = TRUE
       AND login_pin_hash IS NOT NULL
  );
END;
$$;

REVOKE ALL ON FUNCTION public.has_login_pin(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.has_login_pin(TEXT) TO anon, authenticated;
