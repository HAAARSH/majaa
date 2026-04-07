-- ============================================================
-- MAJAA Sales — Supabase Database Cleanup Queries
-- Generated: 2026-03-30
-- Run these in the Supabase SQL Editor (Dashboard > SQL Editor)
-- Read all comments carefully before executing.
-- Execute section by section, not all at once.
-- ============================================================


-- ============================================================
-- SECTION 1: CRITICAL — Hash plaintext passwords
-- ISSUE-01: password_hash column stores plaintext passwords.
-- This requires pgcrypto extension.
-- Option A: Use Supabase's built-in auth instead of this table
--           for credential management (RECOMMENDED).
-- Option B: Hash them in-place with bcrypt via pgcrypto.
--
-- Run this only after confirming your app reads hashes correctly.
-- ============================================================

-- Enable pgcrypto if not already enabled
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Hash all plaintext passwords with bcrypt (cost factor 10)
-- WARNING: After running this, your app must use crypt() to verify,
--          e.g.: SELECT * FROM app_users WHERE email=$1 AND password_hash = crypt($2, password_hash);
UPDATE app_users SET password_hash = crypt(password_hash, gen_salt('bf', 10))
WHERE id IN (
  '857e1d6f-7698-4e35-9a60-e9abbde6098c',  -- james.okonkwo
  '5c8225c2-f57e-4d47-9c13-2a4b43deeeb1',  -- adi
  'c2daf66d-816c-4411-8c87-cb961bb60cb4',  -- ranjeet
  'd02c75fc-f645-4a2b-8a3c-b2faf207d56b',  -- ajay
  '48371a54-1cb3-42ac-bc0f-7e27b49a3f60',  -- harsh (super_admin)
  'cdc4c4e5-1201-48c8-99e4-e81d1c9e20fd'   -- vijay
);


-- ============================================================
-- SECTION 2: HIGH — Fix broken app update URL
-- ISSUE-16: apk_download_url is a placeholder. mandatory_update=true
-- means all users are forced to update to a broken URL.
-- Replace the URL below with the real APK download link,
-- OR set mandatory_update=false until the APK is uploaded.
-- ============================================================

-- Option A: Disable mandatory update until real APK URL is ready
UPDATE app_settings
SET mandatory_update = false
WHERE id = 1
  AND apk_download_url LIKE '%REPLACE_ME_LATER%';

-- Option B: Set real APK URL (replace the URL below with actual value)
-- UPDATE app_settings
-- SET apk_download_url = 'https://drive.google.com/uc?export=download&id=YOUR_REAL_FILE_ID',
--     mandatory_update = true
-- WHERE id = 1;


-- ============================================================
-- SECTION 3: HIGH — Investigate orphaned order user_id
-- ISSUE-03: All 5 orders and 11 order_items reference user_id
-- '958f9ea4-c98f-41ee-b533-fb54b1323f8f' which does not exist
-- in app_users. This may be a deleted test user or a Supabase Auth UID.
--
-- Step 1: Check if this UUID exists in Supabase auth.users
-- (Run in Dashboard > SQL Editor with service_role or check Auth UI)
-- ============================================================

-- Diagnostic: count orders with missing user reference
SELECT COUNT(*) as orphaned_order_count
FROM orders o
WHERE NOT EXISTS (
  SELECT 1 FROM app_users u WHERE u.id = o.user_id
);

-- If the missing user was a real deleted user, reassign to super_admin (Harsh)
-- ONLY run this after confirming the user is truly gone and you want to reassign:
-- UPDATE orders
-- SET user_id = '48371a54-1cb3-42ac-bc0f-7e27b49a3f60'  -- Harsh (super_admin)
-- WHERE user_id = '958f9ea4-c98f-41ee-b533-fb54b1323f8f';
--
-- UPDATE order_items
-- SET user_id = '48371a54-1cb3-42ac-bc0f-7e27b49a3f60'
-- WHERE user_id = '958f9ea4-c98f-41ee-b533-fb54b1323f8f';


-- ============================================================
-- SECTION 4: HIGH — Fix duplicate phone numbers on customers
-- ISSUE-19: c008 and c009 share the same phone number (formatting differs)
-- +919045000051 vs +91 9045000051
-- Verify which is correct and update the wrong one.
-- ============================================================

-- Diagnostic: show the duplicate
SELECT id, name, phone FROM customers
WHERE phone IN ('+919045000051', '+91 9045000051');

-- Fix: Normalize to consistent format and correct the duplicate.
-- Replace c008 phone with the real number (update value as appropriate):
-- UPDATE customers
-- SET phone = '+91 XXXXX XXXXX'  -- real number for Quick Pick Superstore
-- WHERE id = 'c008';


-- ============================================================
-- SECTION 5: MEDIUM — Populate beat_ja_id for all customers
-- ISSUE-04: beat_ja_id is NULL for all 13 customers.
-- The beat_id field contains the correct beat.
-- Migrate beat_id -> beat_ja_id for all JA team customers.
-- ============================================================

UPDATE customers
SET beat_ja_id = beat_id
WHERE team_id = 'JA'
  AND beat_ja_id IS NULL
  AND beat_id IS NOT NULL;

-- Verify
SELECT id, name, beat_id, beat_ja_id FROM customers WHERE team_id = 'JA';


-- ============================================================
-- SECTION 6: MEDIUM — Fix empty category on products
-- ISSUE-10: Products p003, p004, p005, p006 have category = ''.
-- All are NUTTY brand nuts, so category should be 'Nutty'.
-- ============================================================

UPDATE products
SET category = 'Nutty'
WHERE id IN ('p003', 'p004', 'p005', 'p006')
  AND team_id = 'JA'
  AND (category = '' OR category IS NULL);

-- Verify
SELECT id, name, category FROM products WHERE team_id = 'JA';


-- ============================================================
-- SECTION 7: MEDIUM — Copy gst_rate to order_items
-- ISSUE-09: order_items.gst_rate is NULL for all 11 items.
-- Backfill from the products table.
-- ============================================================

UPDATE order_items oi
SET gst_rate = p.gst_rate
FROM products p
WHERE oi.product_id = p.id
  AND oi.gst_rate IS NULL;

-- Verify
SELECT id, order_id, product_id, gst_rate FROM order_items;


-- ============================================================
-- SECTION 8: MEDIUM — Fix delivered_at for Delivered orders
-- ISSUE-08: delivered_at is NULL even for status='Delivered' orders.
-- Backfill using updated_at as an approximation of delivery time.
-- ============================================================

UPDATE orders
SET delivered_at = updated_at
WHERE status = 'Delivered'
  AND delivered_at IS NULL
  AND team_id = 'JA';

-- Verify
SELECT id, status, delivered_at, updated_at FROM orders;


-- ============================================================
-- SECTION 9: MEDIUM — Add missing user_beats for unassigned users
-- ISSUE-17: Users 48371a54 (Harsh/super_admin), 5c8225c2 (Aditiya),
--           cdc4c4e5 (Vijay/delivery_rep) have no beat assignments.
-- Assign beats as needed. Examples below — adjust to actual requirements.
-- ============================================================

-- Assign Harsh (super_admin) to all beats for visibility
INSERT INTO user_beats (id, user_id, beat_id, assigned_at)
SELECT
  gen_random_uuid(),
  '48371a54-1cb3-42ac-bc0f-7e27b49a3f60',
  id,
  now()
FROM beats
WHERE team_id = 'JA'
  AND id NOT IN (
    SELECT beat_id FROM user_beats
    WHERE user_id = '48371a54-1cb3-42ac-bc0f-7e27b49a3f60'
  );

-- Assign Aditiya (sales_rep) to bt-a (Hanuman Chowk) — adjust as needed
INSERT INTO user_beats (id, user_id, beat_id, assigned_at)
VALUES (gen_random_uuid(), '5c8225c2-f57e-4d47-9c13-2a4b43deeeb1', 'bt-a', now())
ON CONFLICT DO NOTHING;

-- Assign Vijay (delivery_rep) to all beats for delivery access
INSERT INTO user_beats (id, user_id, beat_id, assigned_at)
SELECT
  gen_random_uuid(),
  'cdc4c4e5-1201-48c8-99e4-e81d1c9e20fd',
  id,
  now()
FROM beats
WHERE team_id = 'JA'
  AND id NOT IN (
    SELECT beat_id FROM user_beats
    WHERE user_id = 'cdc4c4e5-1201-48c8-99e4-e81d1c9e20fd'
  );


-- ============================================================
-- SECTION 10: LOW — Fix weekday casing and typo in beats
-- ISSUE-13: Inconsistent case and typo "THRUSDAY"
-- ============================================================

-- Fix bt-b: 'sunday' -> 'Sunday'
UPDATE beats
SET weekdays = ARRAY['Wednesday', 'Sunday']
WHERE id = 'bt-b' AND team_id = 'JA';

-- Fix bt-c: normalize 'friday' -> 'Friday'
UPDATE beats
SET weekdays = ARRAY['Wednesday', 'Saturday', 'Friday', 'Sunday']
WHERE id = 'bt-c' AND team_id = 'JA';

-- Fix bt-e: 'THRUSDAY' -> 'Thursday' (fix typo and normalize case)
UPDATE beats
SET weekdays = ARRAY['Thursday']
WHERE id = 'bt-e' AND team_id = 'JA';

-- Verify
SELECT id, beat_name, weekdays FROM beats WHERE team_id = 'JA';


-- ============================================================
-- SECTION 11: LOW — Fix stale beat name for bt-c
-- ISSUE-14: bt-c has placeholder name 'Beat C – East'.
-- Update to real location name (replace with actual area name).
-- ============================================================

-- Replace 'Clement Town 2nd' with the real name for this beat:
UPDATE beats
SET beat_name = 'Clement Town 2nd'  -- CHANGE THIS to the real name
WHERE id = 'bt-c' AND team_id = 'JA'
  AND beat_name = 'Beat C – East';

-- NOTE: After fixing beat names, also update the denormalized `beat` text
-- on customers (ISSUE-15):

UPDATE customers
SET beat = 'Hanuman Chowk'
WHERE beat_id = 'bt-a' AND team_id = 'JA';

UPDATE customers
SET beat = 'Prem Nagar'
WHERE beat_id = 'bt-b' AND team_id = 'JA';

UPDATE customers
SET beat = 'Kargi'
WHERE beat_id = 'bt-d' AND team_id = 'JA';

-- Update bt-c customers after you have fixed the bt-c beat_name above
-- UPDATE customers SET beat = 'YOUR_BT_C_REAL_NAME' WHERE beat_id = 'bt-c' AND team_id = 'JA';


-- ============================================================
-- SECTION 12: DIAGNOSTIC — Check referential integrity
-- Run these as read-only checks to confirm no other orphans.
-- ============================================================

-- Products with subcategory_id not in product_subcategories
SELECT p.id, p.name, p.subcategory_id
FROM products p
WHERE p.subcategory_id IS NOT NULL
  AND NOT EXISTS (
    SELECT 1 FROM product_subcategories ps WHERE ps.id = p.subcategory_id
  );

-- Customers with beat_id not in beats
SELECT c.id, c.name, c.beat_id
FROM customers c
WHERE c.beat_id IS NOT NULL
  AND NOT EXISTS (
    SELECT 1 FROM beats b WHERE b.id = c.beat_id
  );

-- Orders with customer_id not in customers
SELECT o.id, o.customer_id
FROM orders o
WHERE NOT EXISTS (
  SELECT 1 FROM customers c WHERE c.id = o.customer_id
);

-- Order items with order_id not in orders
SELECT oi.id, oi.order_id
FROM order_items oi
WHERE NOT EXISTS (
  SELECT 1 FROM orders o WHERE o.id = oi.order_id
);

-- Order items with product_id not in products
SELECT oi.id, oi.product_id
FROM order_items oi
WHERE NOT EXISTS (
  SELECT 1 FROM products p WHERE p.id = oi.product_id
);

-- user_beats with user_id not in app_users
SELECT ub.id, ub.user_id
FROM user_beats ub
WHERE NOT EXISTS (
  SELECT 1 FROM app_users u WHERE u.id = ub.user_id
);

-- user_beats with beat_id not in beats
SELECT ub.id, ub.beat_id
FROM user_beats ub
WHERE NOT EXISTS (
  SELECT 1 FROM beats b WHERE b.id = ub.beat_id
);

-- Team IDs other than JA or MA
SELECT 'app_users' as tbl, id, team_id FROM app_users WHERE team_id NOT IN ('JA','MA')
UNION ALL
SELECT 'customers', id, team_id FROM customers WHERE team_id NOT IN ('JA','MA')
UNION ALL
SELECT 'products', id, team_id FROM products WHERE team_id NOT IN ('JA','MA')
UNION ALL
SELECT 'beats', id, team_id FROM beats WHERE team_id NOT IN ('JA','MA')
UNION ALL
SELECT 'orders', id, team_id FROM orders WHERE team_id NOT IN ('JA','MA');

-- Negative prices or amounts
SELECT id, name, unit_price FROM products WHERE unit_price < 0;
SELECT id, subtotal, vat, grand_total FROM orders WHERE subtotal < 0 OR vat < 0 OR grand_total < 0;
SELECT id, quantity, unit_price, line_total FROM order_items WHERE quantity < 0 OR unit_price < 0 OR line_total < 0;


-- ============================================================
-- END OF CLEANUP QUERIES
-- ============================================================
