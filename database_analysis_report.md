# MAJAA Sales — Supabase Database Analysis Report
**Generated:** 2026-03-30
**Project:** https://ctrmpwmnnvvsciqouqyo.supabase.co
**Access Level:** anon key (public RLS policies)

---

## 1. Table Inventory

| Table | Status | Rows | Notes |
|---|---|---|---|
| app_users | OK | 6 | All team_id = JA |
| customers | OK | 13 | All team_id = JA |
| products | OK | 6 | All team_id = JA |
| product_categories | OK | 7 | All team_id = JA |
| product_subcategories | EMPTY/RLS-BLOCKED | 0 | Empty array returned; likely RLS blocks anon or table is genuinely empty |
| beats | OK | 6 | All team_id = JA |
| orders | OK | 5 | All team_id = JA |
| order_items | OK | 11 | No team_id column |
| collections | EMPTY/RLS-BLOCKED | 0 | Empty array returned |
| visit_logs | EMPTY/RLS-BLOCKED | 0 | Empty array returned |
| user_beats | OK | 12 | No team_id column |
| app_settings | OK | 1 | Single config row |
| app_versions | EMPTY/RLS-BLOCKED | 0 | Empty array returned |

**Total accessible rows: 61**

---

## 2. Column Inventory Per Table

### app_users
`id, email, password_hash, full_name, role, is_active, created_at, updated_at, team_id, upi_id`

### customers
`id, name, address, phone, type, beat_id, beat, last_order_value, last_order_date, created_at, updated_at, delivery_route, team_id, beat_ja_id, beat_ma_id, outstanding_ja, outstanding_ma`

### products
`id, name, sku, category, brand, unit_price, pack_size, status, stock_qty, image_url, semantic_label, created_at, updated_at, gst_rate, step_size, team_id, subcategory_id`

### product_categories
`id, name, sort_order, is_active, created_at, updated_at, team_id`

### product_subcategories
*(not accessible — 0 rows returned)*

### beats
`id, beat_name, beat_code, weekdays, created_at, area, route, team_id`

### orders
`id, customer_id, customer_name, beat_name, order_date, delivery_date, subtotal, vat, grand_total, item_count, total_units, status, notes, created_at, updated_at, user_id, delivered_at, team_id, final_bill_no, actual_billed_amount, bill_no, bill_photo_url, bill_amount, verified_by_office, verified_by_delivery`

### order_items
`id, order_id, product_id, product_name, sku, quantity, unit_price, line_total, created_at, gst_rate, user_id`

### collections
*(not accessible — 0 rows returned)*

### visit_logs
*(not accessible — 0 rows returned)*

### user_beats
`id, user_id, beat_id, assigned_at`

### app_settings
`id, latest_version, mandatory_update, apk_download_url`

### app_versions
*(not accessible — 0 rows returned)*

---

## 3. Issue Analysis

### ISSUE-01: Plaintext Passwords in app_users (CRITICAL SECURITY)
The `password_hash` column stores **plaintext passwords**, not hashed values.

| user_id | email | password_hash |
|---|---|---|
| 857e1d6f | james.okonkwo@fmcgorders.com | FMCGDemo@2026 |
| 5c8225c2 | adi@gmail.com | adi |
| c2daf66d | ranjeet@majaa.com | ran |
| d02c75fc | ajaychana@gmail.com | ajay@2026 |
| 48371a54 | sa@gmail.com | sa@2026 |
| cdc4c4e5 | vijay@majaa.com | vijay@ddn |

**Risk:** These are exposed to anyone with the anon key, which is embedded in the client app and discoverable. Any user of the app can read all passwords. Must be hashed with bcrypt/argon2 immediately.

---

### ISSUE-02: Missing MA Team Data (No 'MA' team records anywhere)
Every single record in every table has `team_id = 'JA'`. There are **zero MA team records** for:
- customers
- products
- beats
- orders
- product_categories

This is either expected (app not yet onboarded for MA) or a data ingestion failure.

---

### ISSUE-03: orders.user_id References a Non-Existent app_users ID (Orphaned FK)
All 5 orders reference `user_id = '958f9ea4-c98f-41ee-b533-fb54b1323f8f'`. This UUID does **not exist** in the `app_users` table.

**Affected orders:** ORD-536669, ORD-584427, ORD-259769, ORD-202684, ORD-725798
**Also affected:** All 11 order_items have the same invalid `user_id`.

This suggests orders were placed by a user who has since been deleted, or there is a test/seed user not present in the app_users table. The orders are effectively orphaned from a user perspective.

---

### ISSUE-04: customers.beat_ja_id and beat_ma_id are NULL for All Records
The app schema requires `beat_ja_id` and `beat_ma_id` on customers for multi-team beat assignment. All 13 customers have `beat_ja_id = null` and `beat_ma_id = null`. The `beat_id` column (legacy?) is populated, but the new columns are not.

**Affected customers:** c001–c013 (all 13)

---

### ISSUE-05: customers.outstanding_ja and outstanding_ma are Zero for All
All 13 customers show `outstanding_ja = 0` and `outstanding_ma = 0`. While this may be correct if no collections have been tracked, if collections data exists (table is RLS-blocked), these figures are unsynced with real data.

---

### ISSUE-06: All orders Missing bill_no, bill_amount, bill_photo_url
The orders table has the billing columns (`bill_no`, `bill_photo_url`, `bill_amount`) but they are NULL for all 5 orders, including 3 orders with status = 'Delivered'. Delivered orders should have bill data.

| order_id | status | bill_no | bill_amount | bill_photo_url |
|---|---|---|---|---|
| ORD-536669 | Delivered | NULL | NULL | NULL |
| ORD-584427 | Delivered | NULL | NULL | NULL |
| ORD-202684 | Delivered | NULL | NULL | NULL |

Also: `final_bill_no` and `actual_billed_amount` are NULL for all records.

---

### ISSUE-07: Delivered Orders Not Verified (verified_by_delivery = false)
All 5 orders have `verified_by_delivery = false` and `verified_by_office = false`, including 3 that have `status = 'Delivered'`. Status appears to be updated manually but the verification flags are never set.

| order_id | status | verified_by_delivery | verified_by_office |
|---|---|---|---|
| ORD-536669 | Delivered | false | false |
| ORD-584427 | Delivered | false | false |
| ORD-202684 | Delivered | false | false |

---

### ISSUE-08: Delivered Orders Missing delivered_at Timestamp
All 3 delivered orders have `delivered_at = null`. This field should be auto-set when status changes to Delivered.

---

### ISSUE-09: order_items.gst_rate is NULL for All Items
All 11 order_items have `gst_rate = null`. The products table has `gst_rate = 0.05` for all products, but this value is not being copied to order_items at order creation time. This means VAT calculations at line-item level are not preserved.

---

### ISSUE-10: Products with Empty category Field (4 out of 6)
Products p003–p006 have `category = ''` (empty string) instead of a proper category name.

| product_id | name | category |
|---|---|---|
| p003 | NG WALNUTS KERNEL 200GM | "" (empty) |
| p004 | NG BRAZIL NUTS 150GM | "" (empty) |
| p005 | NG MACADAMIA NUTS 100GM | "" (empty) |
| p006 | NG PINE NUT 100GM | "" (empty) |

p001 and p002 correctly have `category = 'Nutty'`.

---

### ISSUE-11: products.subcategory_id is NULL for All Products
All 6 products have `subcategory_id = null`. The product_subcategories table appears empty or RLS-blocked, so subcategory classification is not in use at all.

---

### ISSUE-12: products.image_url is Empty String for All Products
All 6 products have `image_url = ''`. No product images have been uploaded.

---

### ISSUE-13: Inconsistent Weekday Casing in beats
The `weekdays` array values use inconsistent casing across beats:

| beat_id | beat_name | weekdays |
|---|---|---|
| bt-b | Prem Nagar | ["Wednesday", "sunday"] — 'sunday' lowercase |
| bt-c | Beat C – East | ["Wednesday", "Saturday", "friday", "Sunday"] — 'friday' lowercase |
| bt-e | Raipur | ["THRUSDAY"] — ALL CAPS, and **MISSPELLED** (should be THURSDAY) |

---

### ISSUE-14: beat bt-c Has Stale/Placeholder Name
Beat `bt-c` has `beat_name = 'Beat C – East'`, which looks like a placeholder from initial seeding. All other beats have real location names (Hanuman Chowk, Prem Nagar, Kargi, Raipur, Clement Town 1st).

---

### ISSUE-15: customers.beat Field is Stale/Denormalized and Inconsistent
The `beat` column on customers is a denormalized text copy of the beat name. Some values reference old naming:
- `beat = 'Beat A – North'` but the actual beat bt-a has `beat_name = 'Hanuman Chowk'`
- `beat = 'Beat B – South'` but actual bt-b has `beat_name = 'Prem Nagar'`
- `beat = 'Beat D – West'` but actual bt-d has `beat_name = 'Kargi'`
- `beat = 'Beat C – East'` matches bt-c (which itself has placeholder name)

All 13 customers have stale beat name text in the `beat` column.

---

### ISSUE-16: app_settings apk_download_url is Placeholder
`apk_download_url = 'https://drive.google.com/uc?export=download&id=REPLACE_ME_LATER'` — this is an unfilled placeholder. The update system is pointing to a non-functional URL, but `mandatory_update = true` which means users will be prompted to update and sent to a broken link.

---

### ISSUE-17: user_beats Missing for Several Users
- User `48371a54` (Harsh / super_admin) — NO beat assignments
- User `5c8225c2` (Aditiya / sales_rep) — NO beat assignments
- User `cdc4c4e5` (Vijay Sahni / delivery_rep) — NO beat assignments

These users cannot see any customers or place any orders in the current beat-gated UI.

---

### ISSUE-18: No MA Team Users
All 6 users in app_users have `team_id = 'JA'`. There are no users for team 'MA'.

---

### ISSUE-19: Customer c008 and c009 Have Same Phone Number
- c008 Quick Pick Superstore: `+919045000051`
- c009 East End Grocers: `+91 9045000051`

These are the same number (formatting differs) assigned to two different customers. This may cause issues if phone is used as a contact or identifier.

---

### ISSUE-20: Only Beat C Customers Have Recent Orders (Narrow Coverage)
All 5 orders are for customers c008 and c009, both in beat bt-c. Customers in beats bt-a, bt-b, bt-d, bt-e, bt-f have no recent orders in the database. This may indicate the app was only tested with beat-c data, or data for other beats is in a separate auth-gated area.

---

### ISSUE-21: ORD-536669 Line Total Mismatch
Order ORD-536669 has:
- `subtotal = 2060.00` in orders table
- Actual line items: 770.00 (p002 x2) + 1290.00 (p004 x2) = **2060.00** ✓ (this one is correct)

All order subtotals verified against order_items — no arithmetic errors found.

---

### ISSUE-22: product_categories Have No Products Linked (Beverages, Snacks, Dairy, Personal Care, Household, Asta)
The product_categories table has 7 categories. Only 'Nutty' has any products (p001, p002 via the text `category` field). Categories Beverages, Snacks, Dairy, Personal Care, Household, and Asta have zero products. This is not a referential integrity issue (products use a text `category` field, not a FK), but it means these categories are dead data.

---

## 4. Summary of Issue Counts

| Severity | Count | Issues |
|---|---|---|
| CRITICAL | 1 | Plaintext passwords (ISSUE-01) |
| HIGH | 3 | Orphaned user_id on all orders (ISSUE-03), Broken update URL with mandatory=true (ISSUE-16), Duplicate phone on customers (ISSUE-19) |
| MEDIUM | 8 | Missing bill data on delivered orders (ISSUE-06, 07, 08), Missing beat_ja_id/beat_ma_id (ISSUE-04), Empty category on 4 products (ISSUE-10), NULL gst_rate on all order_items (ISSUE-09), No MA team data (ISSUE-02, 18), Missing user beat assignments (ISSUE-17) |
| LOW | 8 | Zero outstanding values (ISSUE-05), NULL subcategory_id (ISSUE-11), Empty image_url (ISSUE-12), Weekday casing/typo (ISSUE-13), Stale beat name bt-c (ISSUE-14), Stale denormalized beat text in customers (ISSUE-15), Empty categories (ISSUE-22), Orders only in bt-c (ISSUE-20) |

---

## 5. RLS / Access Notes

The following tables returned empty arrays `[]` which may mean either genuinely empty or blocked by Row Level Security for the anon role:
- `product_subcategories` — likely empty (no subcategory setup done)
- `collections` — likely RLS-blocked (financial data, expected to require auth)
- `visit_logs` — likely RLS-blocked (requires auth)
- `app_versions` — likely empty or RLS-blocked

To confirm, these tables should be queried with a service role key or via the Supabase dashboard.
