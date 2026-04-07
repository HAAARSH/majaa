-- Migration: Stock Visibility Control Per Salesman
-- Run this in Supabase SQL Editor (Dashboard → SQL Editor → New Query)

create table if not exists user_settings (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references app_users(id) on delete cascade unique,
  show_stock boolean default true,
  created_at timestamptz default now()
);

-- Enable RLS
alter table user_settings enable row level security;

-- Allow authenticated users to read/write
create policy "Authenticated users can manage user settings"
  on user_settings for all
  using (auth.role() = 'authenticated')
  with check (auth.role() = 'authenticated');
