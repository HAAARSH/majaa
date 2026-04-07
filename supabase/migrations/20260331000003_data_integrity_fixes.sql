-- ─────────────────────────────────────────────────────────────────────────────
-- Data Integrity Fixes — Run against production Supabase dashboard (SQL editor)
-- ISSUE reference: database_analysis_report.md
-- ─────────────────────────────────────────────────────────────────────────────

-- ══════════════════════════════════════════════════════════════
-- ISSUE-01: Remove plaintext passwords (CRITICAL)
-- Supabase Auth handles passwords. This column is dangerous.
-- ══════════════════════════════════════════════════════════════
-- Option A: Wipe the column values (safest, keeps column for possible future use)
UPDATE app_users SET password_hash = NULL;
-- Option B: Drop the column entirely (recommended)
-- ALTER TABLE app_users DROP COLUMN IF EXISTS password_hash;

-- ══════════════════════════════════════════════════════════════
-- ISSUE-03: Fix orphaned user_id on all orders
-- The user '958f9ea4-c98f-41ee-b533-fb54b1323f8f' no longer exists in app_users.
-- Two options:
--   A) NULL it out (safe — user_id is nullable)
--   B) Re-point to an existing admin user
-- Using Option A here:
-- ══════════════════════════════════════════════════════════════
UPDATE orders
  SET user_id = NULL
  WHERE user_id = '958f9ea4-c98f-41ee-b533-fb54b1323f8f'::UUID
    AND NOT EXISTS (SELECT 1 FROM auth.users WHERE id = '958f9ea4-c98f-41ee-b533-fb54b1323f8f'::UUID);

UPDATE order_items
  SET user_id = NULL
  WHERE user_id = '958f9ea4-c98f-41ee-b533-fb54b1323f8f'::UUID
    AND NOT EXISTS (SELECT 1 FROM auth.users WHERE id = '958f9ea4-c98f-41ee-b533-fb54b1323f8f'::UUID);

-- ══════════════════════════════════════════════════════════════
-- ISSUE-04: Populate beat_ja_id from beat_id for JA team customers
-- All 13 customers have team_id='JA' and beat_id set but beat_ja_id=NULL
-- ══════════════════════════════════════════════════════════════
UPDATE customers
  SET beat_ja_id = beat_id
  WHERE team_id = 'JA'
    AND beat_id IS NOT NULL
    AND beat_ja_id IS NULL;

-- ══════════════════════════════════════════════════════════════
-- ISSUE-09: Backfill gst_rate on order_items from products table
-- All 11 order_items have gst_rate=NULL
-- ══════════════════════════════════════════════════════════════
UPDATE order_items oi
  SET gst_rate = p.gst_rate
  FROM products p
  WHERE oi.product_id = p.id
    AND oi.gst_rate IS NULL;

-- Fallback: set default 5% for items whose product_id is NULL/deleted
UPDATE order_items
  SET gst_rate = 0.05
  WHERE gst_rate IS NULL;

-- ══════════════════════════════════════════════════════════════
-- ISSUE-10: Fix empty category on 4 products (p003-p006)
-- These are nut products — assign to the existing 'Nutty' category
-- ══════════════════════════════════════════════════════════════
UPDATE products
  SET category = 'Nutty'
  WHERE category = ''
    AND team_id = 'JA';

-- ══════════════════════════════════════════════════════════════
-- ISSUE-13: Fix beat weekday casing and misspelling
-- ══════════════════════════════════════════════════════════════
-- Fix 'sunday' → 'Sunday' in bt-b
UPDATE beats
  SET weekdays = ARRAY['Wednesday', 'Sunday']
  WHERE id = 'bt-b';

-- Fix 'friday' → 'Friday' in bt-c
UPDATE beats
  SET weekdays = ARRAY['Wednesday', 'Saturday', 'Friday', 'Sunday']
  WHERE id = 'bt-c';

-- Fix 'THRUSDAY' → 'Thursday' in bt-e
UPDATE beats
  SET weekdays = ARRAY['Thursday']
  WHERE id = 'bt-e';

-- ══════════════════════════════════════════════════════════════
-- ISSUE-14: Fix placeholder beat name for bt-c
-- ══════════════════════════════════════════════════════════════
-- UPDATE beats SET beat_name = 'YOUR_REAL_BEAT_NAME' WHERE id = 'bt-c';
-- (Commented out — requires real business name from the team)

-- ══════════════════════════════════════════════════════════════
-- ISSUE-15: Sync denormalized customers.beat column from actual beat names
-- ══════════════════════════════════════════════════════════════
UPDATE customers c
  SET beat = b.beat_name
  FROM beats b
  WHERE c.beat_id = b.id
    AND c.beat != b.beat_name;

-- ══════════════════════════════════════════════════════════════
-- ISSUE-16: Fix mandatory update URL placeholder
-- Replace with real APK URL before running this
-- ══════════════════════════════════════════════════════════════
-- UPDATE app_settings
--   SET apk_download_url = 'https://drive.google.com/uc?export=download&id=YOUR_REAL_FILE_ID',
--       mandatory_update = false
--   WHERE id = 1;

-- ══════════════════════════════════════════════════════════════
-- ISSUE-19: Normalize duplicate phone number on c009
-- c008 and c009 have same phone — manually verify with team which is correct
-- ══════════════════════════════════════════════════════════════
-- UPDATE customers SET phone = 'CORRECT_NUMBER' WHERE id = 'c009';

-- ══════════════════════════════════════════════════════════════
-- VERIFY: After running, check counts
-- ══════════════════════════════════════════════════════════════
SELECT 'app_users with non-null password_hash' AS check, COUNT(*) FROM app_users WHERE password_hash IS NOT NULL
UNION ALL
SELECT 'orders with orphaned user_id', COUNT(*) FROM orders WHERE user_id = '958f9ea4-c98f-41ee-b533-fb54b1323f8f'::UUID
UNION ALL
SELECT 'customers with null beat_ja_id (JA team)', COUNT(*) FROM customers WHERE team_id='JA' AND beat_id IS NOT NULL AND beat_ja_id IS NULL
UNION ALL
SELECT 'order_items with null gst_rate', COUNT(*) FROM order_items WHERE gst_rate IS NULL
UNION ALL
SELECT 'products with empty category', COUNT(*) FROM products WHERE category = '';
