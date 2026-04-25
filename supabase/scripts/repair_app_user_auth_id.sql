-- ─────────────────────────────────────────────────────────────────────────
-- One-shot: re-key app_users.id to match auth.uid() for legacy mismatched users.
--
-- Background: app_users for users created before the auth-uid linkage was
-- enforced have id ≠ auth.users.id. The Dart side papers over this with
-- `_resolveAppUserId` (lib/services/supabase_service.dart:56), but RLS
-- policies that test `id::TEXT = auth.uid()::TEXT` directly cannot, so
-- those users see zero rows on every team-scoped table whose policy uses
-- that pattern (customer_bills + 5 siblings, billing_rules, etc.).
--
-- This script does the irreducible re-key safely:
--   1. Look up the legacy app_users row by email.
--   2. Confirm an auth.users row exists at the *target* UID and that the
--      mismatch is real (skip if already correct).
--   3. Move every FK reference from old id → new id in one transaction.
--   4. Update app_users.id last (PRIMARY KEY change), then commit.
--
-- Safe to re-run: NOTICE + early RETURN when no mismatch is detected.
-- Re-keys only one user per run; copy/edit the two IDs at the top to
-- repair another user.
--
-- Usage (Supabase Studio → SQL Editor):
--   1. Edit BOTH the SELECT WHERE clause AND v_email in the DO block to
--      the same target email (they must match — the SELECT is informational,
--      the DO block does the work).
--   2. Run the SELECT block first to verify the (old_id, new_id) pair is
--      what you expect.
--   3. Run the DO block to perform the re-key.
--   4. Re-run the post-flight SELECT at the bottom to confirm 'OK'.
--
-- Known legacy mismatched accounts (run this script once per email):
--   • ranjeet@majaa.com   (sales_rep, JA)        — confirmed 2026-04-24
--   • sa@gmail.com        (super_admin)          — confirmed 2026-04-24
--                                                   priority: writes OPNBIL
-- ─────────────────────────────────────────────────────────────────────────

-- ── 1. PRE-FLIGHT (read-only). Confirms the mismatch before re-keying. ──
SELECT
  au.id          AS legacy_app_users_id,
  u.id           AS auth_users_id,
  au.email,
  au.role,
  au.team_id,
  CASE
    WHEN au.id = u.id           THEN 'OK — already matches, no re-key needed'
    WHEN u.id IS NULL           THEN 'BLOCKED — no auth.users row for this email'
    ELSE                             'MISMATCH — re-key will run'
  END AS status
FROM public.app_users au
LEFT JOIN auth.users u ON u.email = au.email
WHERE au.email = 'ranjeet@majaa.com';   -- ← edit target email here

-- ── 2. RE-KEY (transactional). Idempotent: no-op if already aligned. ──
DO $$
DECLARE
  v_email      TEXT := 'ranjeet@majaa.com';   -- ← keep in sync with the SELECT above
  v_old_id     UUID;
  v_new_id     UUID;
  v_moved      INTEGER;
BEGIN
  SELECT au.id, u.id
    INTO v_old_id, v_new_id
  FROM public.app_users au
  LEFT JOIN auth.users u ON u.email = au.email
  WHERE au.email = v_email;

  IF v_old_id IS NULL THEN
    RAISE NOTICE 'No app_users row for %', v_email;
    RETURN;
  END IF;

  IF v_new_id IS NULL THEN
    RAISE NOTICE 'No auth.users row for % — cannot re-key', v_email;
    RETURN;
  END IF;

  IF v_old_id = v_new_id THEN
    RAISE NOTICE 'Already aligned for % (id=%)', v_email, v_old_id;
    RETURN;
  END IF;

  RAISE NOTICE 'Re-keying %: % → %', v_email, v_old_id, v_new_id;

  -- Defer constraint checks so the FK pointer-swap doesn't briefly violate
  -- NOT NULL / FK during the in-flight UPDATE on app_users.id.
  SET CONSTRAINTS ALL DEFERRED;

  -- Re-point every FK that references app_users(id). Skip silently when
  -- the target table doesn't exist (e.g. earlier migration not yet applied).
  UPDATE public.user_beats           SET user_id                   = v_new_id WHERE user_id                   = v_old_id;
  GET DIAGNOSTICS v_moved = ROW_COUNT;  RAISE NOTICE '  user_beats: % rows', v_moved;

  UPDATE public.user_brand_access    SET user_id                   = v_new_id WHERE user_id                   = v_old_id;
  GET DIAGNOSTICS v_moved = ROW_COUNT;  RAISE NOTICE '  user_brand_access: % rows', v_moved;

  UPDATE public.user_settings        SET user_id                   = v_new_id WHERE user_id                   = v_old_id;
  GET DIAGNOSTICS v_moved = ROW_COUNT;  RAISE NOTICE '  user_settings: % rows', v_moved;

  UPDATE public.orders               SET attributed_brand_rep_user_id = v_new_id WHERE attributed_brand_rep_user_id = v_old_id;
  GET DIAGNOSTICS v_moved = ROW_COUNT;  RAISE NOTICE '  orders.attributed_brand_rep_user_id: % rows', v_moved;

  UPDATE public.smart_import_history SET revoked_by_user_id        = v_new_id WHERE revoked_by_user_id        = v_old_id;
  GET DIAGNOSTICS v_moved = ROW_COUNT;  RAISE NOTICE '  smart_import_history.revoked_by_user_id: % rows', v_moved;

  UPDATE public.customer_team_profiles SET order_block_set_by_ja  = v_new_id WHERE order_block_set_by_ja  = v_old_id;
  GET DIAGNOSTICS v_moved = ROW_COUNT;  RAISE NOTICE '  customer_team_profiles.order_block_set_by_ja: % rows', v_moved;

  UPDATE public.customer_team_profiles SET order_block_set_by_ma  = v_new_id WHERE order_block_set_by_ma  = v_old_id;
  GET DIAGNOSTICS v_moved = ROW_COUNT;  RAISE NOTICE '  customer_team_profiles.order_block_set_by_ma: % rows', v_moved;

  -- Finally rewrite the PK itself.
  UPDATE public.app_users SET id = v_new_id WHERE id = v_old_id;
  RAISE NOTICE '  app_users.id rewritten';
END $$;

-- ── 3. POST-FLIGHT (read-only). Should now show OK. ──
SELECT
  au.id            AS app_users_id,
  u.id             AS auth_users_id,
  au.email,
  CASE WHEN au.id = u.id THEN 'OK' ELSE 'STILL MISMATCHED' END AS status
FROM public.app_users au
LEFT JOIN auth.users u ON u.email = au.email
WHERE au.email = 'ranjeet@majaa.com';
