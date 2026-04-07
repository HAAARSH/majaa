-- Migration: Brand Access Control Per Salesman
-- Run this in Supabase SQL Editor (Dashboard → SQL Editor → New Query)

create table if not exists user_brand_access (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references app_users(id) on delete cascade,
  team_id text not null,
  brand text not null,  -- matches product_categories.name
  is_enabled boolean default true,
  created_at timestamptz default now(),
  unique(user_id, team_id, brand)
);

-- Enable RLS
alter table user_brand_access enable row level security;

-- Allow authenticated users to read/write
create policy "Authenticated users can manage brand access"
  on user_brand_access for all
  using (auth.role() = 'authenticated')
  with check (auth.role() = 'authenticated');
