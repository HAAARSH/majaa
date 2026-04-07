-- ============================================================
-- PHASE 2 — DATABASE MIGRATION
-- Run this in Supabase SQL Editor STEP BY STEP
-- ============================================================

-- ─── STEP 1: Products table — add new columns ────────────────
alter table products add column if not exists subcategory text;
alter table products add column if not exists mrp numeric default 0;

-- ─── STEP 2: Customer_team_profiles — add new columns FIRST ──
alter table customer_team_profiles add column if not exists team_ja boolean default false;
alter table customer_team_profiles add column if not exists team_ma boolean default false;
alter table customer_team_profiles add column if not exists beat_id_ja uuid;
alter table customer_team_profiles add column if not exists beat_name_ja text default '';
alter table customer_team_profiles add column if not exists outstanding_ja numeric default 0;
alter table customer_team_profiles add column if not exists beat_id_ma uuid;
alter table customer_team_profiles add column if not exists beat_name_ma text default '';
alter table customer_team_profiles add column if not exists outstanding_ma numeric default 0;

-- ─── STEP 3: Drop unique constraint if it exists (old schema) ──
-- The old schema had one row per customer per team with unique(customer_id, team_id)
-- New schema has one row per customer, so we need to handle this
alter table customer_team_profiles drop constraint if exists customer_team_profiles_customer_id_team_id_key;

-- ─── STEP 4: Clear data for reload ──────────────────────────
-- Products: clear order_billed_items first (FK to products)
delete from order_billed_items;
delete from bill_extractions;
delete from item_name_mappings;
-- Clear products
delete from products;

-- Customers: clear dependent data first
delete from customer_team_profiles;
-- DO NOT delete customers yet — orders reference them
-- We'll update customers in place

-- ─── STEP 5: Drop old columns from customer_team_profiles ────
-- Only drop AFTER data is cleared to avoid constraint issues
alter table customer_team_profiles drop column if exists team_id;
alter table customer_team_profiles drop column if exists beat_id;
alter table customer_team_profiles drop column if exists beat_name;
alter table customer_team_profiles drop column if exists outstanding_balance;

-- ─── STEP 6: Add unique constraint for new schema ────────────
-- One profile row per customer (no team_id in unique)
alter table customer_team_profiles add constraint customer_team_profiles_customer_id_key unique (customer_id);

-- ─── DONE! Now upload CSVs via the app or Supabase Dashboard ──
-- Upload order: 1) customers  2) customer_team_profiles  3) products
