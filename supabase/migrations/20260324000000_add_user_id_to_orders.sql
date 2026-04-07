-- Add user_id column to orders table
-- The app code already inserts user_id but the column was missing from the schema

ALTER TABLE public.orders
ADD COLUMN IF NOT EXISTS user_id TEXT;

-- Add index for user_id lookups
CREATE INDEX IF NOT EXISTS idx_orders_user_id ON public.orders(user_id);
