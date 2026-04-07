# Supabase Database Column Usage Analysis Report

**Generated:** April 1, 2026  
**Purpose:** Identify potentially unused columns in the Supabase database by comparing schema with actual Flutter codebase usage.

## Executive Summary

This report analyzes all database tables and columns in your Supabase instance and cross-references them with every database operation in your Flutter codebase. Columns that are never referenced, selected, inserted, or updated in the code are flagged as potentially unused.

**⚠️ IMPORTANT:** Do NOT drop any columns without careful review. Some columns might be:
- Used by external systems or APIs
- Referenced in database triggers/functions
- Part of legacy data migration processes
- Required for data integrity constraints

## Database Schema vs Code Usage Analysis

### Tables and Columns Overview

#### 1. **app_users** table
**Schema Columns:**
- id ✅ (used in auth, user management)
- email ✅ (used in login, auth)
- password_hash ❌ (never referenced in Flutter code)
- full_name ✅ (used in UI, auth)
- role ✅ (used in permissions, admin panel)
- is_active ✅ (used in user management)
- created_at ❌ (never referenced in Flutter code)
- updated_at ❌ (never referenced in Flutter code)
- team_id ✅ (used extensively for data filtering)
- upi_id ✅ (used in payment/collection features)

**Potentially Unused Columns:**
- `password_hash` - Likely managed by Supabase Auth
- `created_at` - Auto-generated, not used in app logic
- `updated_at` - Auto-generated, not used in app logic

#### 2. **customers** table
**Schema Columns:**
- id ✅ (primary key, used everywhere)
- name ✅ (displayed throughout app)
- address ✅ (used in customer details)
- phone ✅ (used in customer details, delivery)
- type ✅ (used in customer classification)
- beat_id ✅ (used for beat assignment)
- beat ❌ (redundant with beat_name from joins)
- last_order_value ✅ (used in customer analytics)
- last_order_date ✅ (used in customer history)
- created_at ❌ (never referenced)
- updated_at ❌ (never referenced)
- delivery_route ✅ (used in delivery operations)
- team_id ✅ (used for data filtering)
- beat_ja_id ❌ (team-specific beat ID, not used)
- beat_ma_id ❌ (team-specific beat ID, not used)
- outstanding_ja ❌ (legacy outstanding balance)
- outstanding_ma ❌ (legacy outstanding balance)

**Potentially Unused Columns:**
- `beat` - Redundant with beat_name from joins
- `created_at`, `updated_at` - Auto-generated timestamps
- `beat_ja_id`, `beat_ma_id` - Legacy team-specific beat IDs
- `outstanding_ja`, `outstanding_ma` - Replaced by customer_team_profiles

#### 3. **products** table
**Schema Columns:**
- id ✅ (primary key)
- name ✅ (displayed everywhere)
- sku ✅ (used in product identification)
- category ✅ (used for filtering and categorization)
- brand ✅ (displayed in product details)
- unit_price ✅ (core pricing field)
- pack_size ✅ (displayed in product info)
- status ✅ (used for availability filtering)
- stock_qty ✅ (used in inventory management)
- image_url ✅ (used for product images)
- semantic_label ✅ (used in OCR/search)
- created_at ❌ (never referenced)
- updated_at ❌ (never referenced)
- gst_rate ✅ (used in tax calculations)
- step_size ✅ (used in order quantity controls)
- team_id ✅ (used for data filtering)
- subcategory_id ✅ (used in product categorization)

**Potentially Unused Columns:**
- `created_at`, `updated_at` - Auto-generated timestamps

#### 4. **product_categories** table
**Schema Columns:**
- id ✅ (primary key)
- name ✅ (displayed in category filters)
- sort_order ✅ (used for UI ordering)
- is_active ✅ (used for filtering active categories)
- created_at ❌ (never referenced)
- updated_at ❌ (never referenced)
- team_id ✅ (used for data filtering)

**Potentially Unused Columns:**
- `created_at`, `updated_at` - Auto-generated timestamps

#### 5. **product_subcategories** table
**Schema Columns:**
- id ✅ (primary key)
- name ✅ (subcategory name)
- category_id ✅ (foreign key to categories)
- sort_order ✅ (used for ordering)
- team_id ✅ (used for data filtering)
- created_at ❌ (not referenced in dump)
- updated_at ❌ (not referenced in dump)

**Note:** Table appears to be empty or RLS-blocked in current dump.

#### 6. **beats** table
**Schema Columns:**
- id ✅ (primary key)
- beat_name ✅ (displayed throughout app)
- beat_code ✅ (used in beat identification)
- weekdays ✅ (used in scheduling)
- created_at ❌ (never referenced)
- updated_at ❌ (never referenced)
- area ❌ (never referenced in code)
- route ❌ (never referenced in code)
- team_id ✅ (used for data filtering)

**Potentially Unused Columns:**
- `created_at`, `updated_at` - Auto-generated timestamps
- `area`, `route` - Geographic data not used in current app logic

#### 7. **orders** table
**Schema Columns:**
- id ✅ (primary key)
- customer_id ✅ (foreign key)
- customer_name ✅ (denormalized for display)
- beat_name ✅ (denormalized for display)
- order_date ✅ (used in filtering and analytics)
- delivery_date ✅ (used in delivery tracking)
- subtotal ✅ (used in calculations)
- vat ✅ (used in tax calculations)
- grand_total ✅ (displayed throughout app)
- item_count ✅ (used in order summaries)
- total_units ✅ (used in order summaries)
- status ✅ (used extensively in order management)
- notes ✅ (used in order details)
- created_at ❌ (never directly referenced)
- updated_at ❌ (never directly referenced)
- user_id ✅ (used in order tracking)
- delivered_at ❌ (never referenced)
- team_id ✅ (used for data filtering)
- final_bill_no ✅ (used in billing verification)
- actual_billed_amount ✅ (used in billing verification)
- bill_no ❌ (appears to be legacy/duplicate)
- bill_photo_url ✅ (used for bill verification)
- bill_amount ❌ (appears to be legacy)
- verified_by_office ✅ (used in verification workflow)
- verified_by_delivery ✅ (used in verification workflow)
- preliminary_bill_no ✅ (used in preliminary billing)
- preliminary_amount ✅ (used in preliminary billing)

**Potentially Unused Columns:**
- `created_at`, `updated_at` - Auto-generated timestamps
- `delivered_at` - Not referenced in current code
- `bill_no` - Appears to be legacy (replaced by final_bill_no)
- `bill_amount` - Appears to be legacy (replaced by actual_billed_amount)

#### 8. **order_items** table
**Schema Columns:**
- id ✅ (primary key)
- order_id ✅ (foreign key)
- product_id ✅ (foreign key)
- product_name ✅ (denormalized for display)
- sku ✅ (denormalized for display)
- quantity ✅ (core order data)
- unit_price ✅ (core pricing data)
- line_total ✅ (calculated field)
- created_at ❌ (never referenced)
- gst_rate ❌ (present but not used in current code)
- user_id ✅ (used for tracking)

**Potentially Unused Columns:**
- `created_at` - Auto-generated timestamp
- `gst_rate` - GST rate not currently utilized in order calculations

#### 9. **collections** table
**Schema Columns:**
- id ✅ (primary key)
- bill_no ✅ (used in collection tracking)
- customer_id ✅ (foreign key)
- customer_name ✅ (denormalized for display)
- amount_collected ✅ (core collection data)
- balance_remaining ✅ (used in outstanding calculations)
- outstanding_before ✅ (used in balance tracking)
- outstanding_after ✅ (used in balance tracking)
- payment_mode ✅ (used in payment processing)
- cheque_number ✅ (used for cheque payments)
- upi_transaction_id ✅ (used for UPI payments)
- rep_email ✅ (used for tracking)
- collected_by ✅ (user tracking)
- bill_photo_url ✅ (used for bill verification)
- drive_file_id ✅ (used for Google Drive integration)
- notes ✅ (used for additional info)
- team_id ✅ (used for data filtering)
- created_at ✅ (used in date filtering)
- collection_date ✅ (used in date filtering)

**Note:** Table appears empty in current dump but is actively used in code.

#### 10. **visit_logs** table
**Schema Columns:**
- id ✅ (primary key)
- customer_id ✅ (foreign key)
- customer_name ✅ (denormalized)
- beat_id ✅ (foreign key)
- beat_name ✅ (denormalized)
- visit_purpose ✅ (used in visit classification)
- rep_email ✅ (used for tracking)
- user_id ✅ (user tracking)
- team_id ✅ (data filtering)
- created_at ✅ (used in timestamping)
- visit_date ✅ (used in date filtering)
- check_in_time ✅ (used for visit tracking)
- check_out_time ✅ (used for visit tracking)
- latitude ❌ (not currently used in code)
- longitude ❌ (not currently used in code)
- order_placed ✅ (used for visit analytics)
- order_id ✅ (links to orders)
- collection_done ✅ (used for visit analytics)
- collection_id ✅ (links to collections)
- visit_photo_url ✅ (used for photo documentation)
- notes ✅ (used for additional info)

**Potentially Unused Columns:**
- `latitude`, `longitude` - GPS coordinates not currently utilized

#### 11. **user_beats** table
**Schema Columns:**
- id ✅ (primary key)
- user_id ✅ (foreign key)
- beat_id ✅ (foreign key)
- assigned_at ❌ (never referenced in code)

**Potentially Unused Columns:**
- `assigned_at` - Assignment timestamp not used in current logic

#### 12. **app_settings** table
**Schema Columns:**
- id ✅ (primary key)
- latest_version ✅ (used in update checking)
- mandatory_update ✅ (used in update flow)
- apk_download_url ✅ (used for app updates)

#### 13. **app_error_logs** table
**Schema Columns:**
- id ✅ (primary key, implied)
- error_message ✅ (used in error logging)
- order_id ✅ (used for error context)
- team_id ✅ (used for filtering)
- created_at ✅ (implied for timestamping)

**Note:** Used only in error handling, not in main app flow.

#### 14. **customer_team_profiles** table
**Schema Columns:**
- id ✅ (primary key)
- customer_id ✅ (foreign key)
- team_id ✅ (foreign key)
- beat_id ✅ (foreign key)
- beat_name ✅ (denormalized)
- outstanding_balance ✅ (used extensively in collections)

## Summary of Potentially Unused Columns

### High Confidence (Safe to Consider for Removal)
1. **Auto-generated timestamps** (created_at, updated_at) - These are typically managed by Supabase and not needed in app logic
2. **Legacy/duplicate columns** in customers table:
   - `beat_ja_id`, `beat_ma_id` (replaced by customer_team_profiles)
   - `outstanding_ja`, `outstanding_ma` (replaced by customer_team_profiles)
3. **Redundant columns** in orders table:
   - `bill_no` (replaced by final_bill_no)
   - `bill_amount` (replaced by actual_billed_amount)

### Medium Confidence (Review Required)
1. **Geographic data** in beats table:
   - `area`, `route` (may be used for future features)
2. **GPS coordinates** in visit_logs:
   - `latitude`, `longitude` (may be planned for location tracking)
3. **Assignment timestamp** in user_beats:
   - `assigned_at` (may be useful for audit trails)

### Low Confidence (Keep for Now)
1. **Password hash** in app_users - Even if not referenced, may be required for authentication
2. **GST rate** in order_items - May be planned for tax calculations
3. **Delivery timestamp** in orders - May be used in delivery tracking features

## Recommendations

### Phase 1: Safe Cleanup
Consider removing these columns after confirming they're not used elsewhere:
- All `created_at`, `updated_at` columns (except where explicitly needed)
- Legacy outstanding balance columns in customers table
- Duplicate billing columns in orders table

### Phase 2: Cautious Review
Review these columns with your team before removal:
- Geographic columns in beats table
- GPS coordinates in visit_logs table
- Assignment timestamps in user_beats table

### Phase 3: Keep for Future
Keep these columns even if not currently used:
- Authentication-related columns
- Columns that might be part of planned features
- Columns used by external systems or integrations

## Next Steps

1. **Review this report** with your development team
2. **Check external dependencies** (APIs, integrations, analytics)
3. **Test any column removals** in a staging environment first
4. **Create database backups** before any schema changes
5. **Monitor application behavior** after changes

**⚠️ Always test column removals in a development environment before applying to production!**
