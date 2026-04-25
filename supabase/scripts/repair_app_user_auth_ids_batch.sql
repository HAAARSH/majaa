-- ─────────────────────────────────────────────────────────────────────────
-- One-shot BATCH: re-key app_users.id to match auth.uid() for legacy
-- mismatched users (where app_users.id ≠ auth.users.id, even though emails
-- match). Verified 2026-04-24: only ranjeet@majaa.com is mismatched in
-- this database. Other emails left in `target_emails` are no-ops.
--
-- ALGORITHM (per email)
--   1. INSERT a new app_users row with id = auth.users.id, copying every
--      column from the legacy row.
--   2. UPDATE every FK that references app_users(id) from old_id → new_id.
--      Both rows exist at this point so the FK is satisfied at every step.
--   3. UPDATE every SOFT-reference column — no declared FK but still
--      holds an app_users.id. Preserves historical "who did this" audit
--      data (orders.user_id, export_batches, billing_rules audit, etc.)
--      across the re-key. Without this the old UUID stays in those rows
--      pointing at nobody.
--   4. DELETE the legacy app_users row. ON DELETE CASCADE FKs (user_beats
--      etc.) are already empty for the old id at this point, so the
--      cascade is a no-op.
--   5. Wrap everything per-email in a savepoint so a single bad row
--      doesn't roll back the whole batch.
--
-- Note: the original script attempted SET CONSTRAINTS ALL DEFERRED + an
-- in-place PK rewrite. That fails with FK violations because the FK
-- declarations on user_beats / user_brand_access / user_settings are NOT
-- DEFERRABLE — DEFERRED is silently ignored, and the FK is checked
-- immediately on the FK-side UPDATE.
--
-- Usage (Supabase Studio → SQL Editor or `supabase db query`):
--   1. Run the PRE-FLIGHT SELECT.
--   2. Run the DO block.
--   3. Run the POST-FLIGHT SELECT — every row should show 'OK'.
-- ─────────────────────────────────────────────────────────────────────────


-- ── 1. PRE-FLIGHT (read-only) ──────────────────────────────────────────
SELECT
  au.email,
  au.id          AS legacy_app_users_id,
  u.id           AS auth_users_id,
  au.role,
  au.team_id,
  CASE
    WHEN au.id = u.id THEN 'OK — already matches'
    WHEN u.id IS NULL THEN 'BLOCKED — no auth.users row'
    ELSE                   'MISMATCH — re-key will run'
  END AS status
FROM public.app_users au
LEFT JOIN auth.users u ON u.email = au.email
WHERE au.email = ANY(ARRAY[
  'ranjeet@majaa.com'
]);


-- ── 2. RE-KEY (per-email savepoint, insert-then-rewire-then-delete) ────
DO $$
DECLARE
  target_emails TEXT[] := ARRAY[
    'ranjeet@majaa.com'   -- only known mismatched user as of 2026-04-24
  ];
  v_email   TEXT;
  v_old_id  UUID;
  v_new_id  UUID;
  v_moved   INTEGER;
BEGIN
  FOREACH v_email IN ARRAY target_emails LOOP
    SELECT au.id, u.id INTO v_old_id, v_new_id
    FROM public.app_users au
    LEFT JOIN auth.users u ON u.email = au.email
    WHERE au.email = v_email;

    IF v_old_id IS NULL THEN
      RAISE NOTICE '[%] no app_users row — skipping', v_email; CONTINUE;
    END IF;
    IF v_new_id IS NULL THEN
      RAISE NOTICE '[%] no auth.users row — skipping', v_email; CONTINUE;
    END IF;
    IF v_old_id = v_new_id THEN
      RAISE NOTICE '[%] already aligned — skipping', v_email; CONTINUE;
    END IF;

    BEGIN  -- savepoint per email
      RAISE NOTICE '[%] re-keying: % → %', v_email, v_old_id, v_new_id;

      -- Step 0: free up the email by appending a sentinel suffix on the
      -- legacy row. Required because app_users.email has a UNIQUE
      -- constraint, so we can't have both old and new rows holding the
      -- same email at the same time.
      UPDATE public.app_users
        SET email = email || '__legacy_' || v_old_id::TEXT
      WHERE id = v_old_id;

      -- Step 1: clone the legacy row under the new id, restoring the
      -- original email. Column list mirrors public.app_users in prod as
      -- of 2026-04-24 (verified via information_schema). password_hash
      -- was declared in the original migration but dropped from prod.
      INSERT INTO public.app_users (
        id, email, full_name, role, is_active,
        created_at, updated_at, team_id, upi_id, hero_image_url,
        app_version, app_version_at
      )
      SELECT
        v_new_id, v_email, full_name, role, is_active,
        created_at, NOW(), team_id, upi_id, hero_image_url,
        app_version, app_version_at
      FROM public.app_users
      WHERE id = v_old_id;

      -- Step 2: re-point every FK. Both ids now exist so each UPDATE is
      -- FK-valid at every intermediate state.
      UPDATE public.user_beats               SET user_id                      = v_new_id WHERE user_id                      = v_old_id;
      GET DIAGNOSTICS v_moved = ROW_COUNT;  RAISE NOTICE '  user_beats: %', v_moved;

      UPDATE public.user_brand_access        SET user_id                      = v_new_id WHERE user_id                      = v_old_id;
      GET DIAGNOSTICS v_moved = ROW_COUNT;  RAISE NOTICE '  user_brand_access: %', v_moved;

      UPDATE public.user_settings            SET user_id                      = v_new_id WHERE user_id                      = v_old_id;
      GET DIAGNOSTICS v_moved = ROW_COUNT;  RAISE NOTICE '  user_settings: %', v_moved;

      UPDATE public.orders                   SET attributed_brand_rep_user_id = v_new_id WHERE attributed_brand_rep_user_id = v_old_id;
      GET DIAGNOSTICS v_moved = ROW_COUNT;  RAISE NOTICE '  orders.attributed_brand_rep_user_id: %', v_moved;

      UPDATE public.smart_import_history     SET revoked_by_user_id           = v_new_id WHERE revoked_by_user_id           = v_old_id;
      GET DIAGNOSTICS v_moved = ROW_COUNT;  RAISE NOTICE '  smart_import_history.revoked_by_user_id: %', v_moved;

      UPDATE public.customer_team_profiles   SET order_block_set_by_ja        = v_new_id WHERE order_block_set_by_ja        = v_old_id;
      GET DIAGNOSTICS v_moved = ROW_COUNT;  RAISE NOTICE '  customer_team_profiles.order_block_set_by_ja: %', v_moved;

      UPDATE public.customer_team_profiles   SET order_block_set_by_ma        = v_new_id WHERE order_block_set_by_ma        = v_old_id;
      GET DIAGNOSTICS v_moved = ROW_COUNT;  RAISE NOTICE '  customer_team_profiles.order_block_set_by_ma: %', v_moved;

      -- Step 3: soft-reference columns (no declared FK but hold
      -- app_users.id values). Keeping these in sync preserves the
      -- historical "who did this" linkage across the re-key. None of
      -- these have a FK constraint so the DELETE below would succeed
      -- without this block, but the rows would then show a stale UUID
      -- that no longer resolves in app_users.
      UPDATE public.orders                   SET user_id              = v_new_id WHERE user_id              = v_old_id;
      GET DIAGNOSTICS v_moved = ROW_COUNT;  RAISE NOTICE '  orders.user_id: %', v_moved;

      UPDATE public.order_items              SET user_id              = v_new_id WHERE user_id              = v_old_id;
      GET DIAGNOSTICS v_moved = ROW_COUNT;  RAISE NOTICE '  order_items.user_id: %', v_moved;

      UPDATE public.export_batches           SET exported_by_user_id  = v_new_id WHERE exported_by_user_id  = v_old_id;
      GET DIAGNOSTICS v_moved = ROW_COUNT;  RAISE NOTICE '  export_batches.exported_by_user_id: %', v_moved;

      UPDATE public.customer_brand_routing   SET set_by_user_id       = v_new_id WHERE set_by_user_id       = v_old_id;
      GET DIAGNOSTICS v_moved = ROW_COUNT;  RAISE NOTICE '  customer_brand_routing.set_by_user_id: %', v_moved;

      UPDATE public.billing_rules            SET last_edited_by_user_id = v_new_id WHERE last_edited_by_user_id = v_old_id;
      GET DIAGNOSTICS v_moved = ROW_COUNT;  RAISE NOTICE '  billing_rules.last_edited_by_user_id: %', v_moved;

      UPDATE public.billing_rules_audit_log  SET changed_by_user_id   = v_new_id WHERE changed_by_user_id   = v_old_id;
      GET DIAGNOSTICS v_moved = ROW_COUNT;  RAISE NOTICE '  billing_rules_audit_log.changed_by_user_id: %', v_moved;

      UPDATE public.smart_import_history     SET imported_by_user_id  = v_new_id WHERE imported_by_user_id  = v_old_id;
      GET DIAGNOSTICS v_moved = ROW_COUNT;  RAISE NOTICE '  smart_import_history.imported_by_user_id: %', v_moved;

      UPDATE public.product_alias_learning   SET created_by_user_id   = v_new_id WHERE created_by_user_id   = v_old_id;
      GET DIAGNOSTICS v_moved = ROW_COUNT;  RAISE NOTICE '  product_alias_learning.created_by_user_id: %', v_moved;

      UPDATE public.customer_alias_learning  SET created_by_user_id   = v_new_id WHERE created_by_user_id   = v_old_id;
      GET DIAGNOSTICS v_moved = ROW_COUNT;  RAISE NOTICE '  customer_alias_learning.created_by_user_id: %', v_moved;

      -- Step 4: drop the now-orphan legacy row.
      DELETE FROM public.app_users WHERE id = v_old_id;
      RAISE NOTICE '  [%] legacy row deleted ✓', v_email;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING '[%] re-key failed: % — rolled back this email only', v_email, SQLERRM;
    END;
  END LOOP;
END $$;


-- ── 3. POST-FLIGHT (read-only) — every row should now show 'OK' ────────
SELECT
  au.email,
  au.id          AS app_users_id,
  u.id           AS auth_users_id,
  CASE WHEN au.id = u.id THEN 'OK' ELSE 'STILL MISMATCHED' END AS status
FROM public.app_users au
LEFT JOIN auth.users u ON u.email = au.email
WHERE au.email = ANY(ARRAY[
  'ranjeet@majaa.com'
]);
