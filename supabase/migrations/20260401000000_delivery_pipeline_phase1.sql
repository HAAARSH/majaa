-- ============================================================
-- Phase 1: Delivery & Admin Verification Pipeline Schema Updates
-- Creates app_error_logs, updates orders table, adds RPC function
-- ============================================================

-- ─── 1. CREATE app_error_logs TABLE ─────────────────────────────────

CREATE TABLE IF NOT EXISTS app_error_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    error_message TEXT NOT NULL,
    order_id TEXT, -- References orders.id but nullable for general errors
    team_id TEXT DEFAULT 'JA',
    error_type TEXT DEFAULT 'background_processing',
    resolved BOOLEAN DEFAULT FALSE,
    resolved_at TIMESTAMPTZ,
    resolved_by TEXT -- auth.users UUID who resolved it
);

-- ─── 2. ENABLE RLS ON app_error_logs ───────────────────────────────

ALTER TABLE app_error_logs ENABLE ROW LEVEL SECURITY;

-- Policy: Authenticated users can insert and read their team's errors
CREATE POLICY "app_error_logs_authenticated_access" ON app_error_logs
    FOR ALL
    USING (auth.role() = 'authenticated')
    WITH CHECK (auth.role() = 'authenticated');

-- ─── 3. UPDATE orders TABLE - ADD MISSING COLUMNS ───────────────────────

-- Add columns if they don't exist (using IF NOT EXISTS pattern)
DO $$
BEGIN
    -- Check and add bill_photo_url
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                   WHERE table_name = 'orders' AND column_name = 'bill_photo_url') THEN
        ALTER TABLE orders ADD COLUMN bill_photo_url TEXT;
    END IF;

    -- Check and add billed_no
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                   WHERE table_name = 'orders' AND column_name = 'billed_no') THEN
        ALTER TABLE orders ADD COLUMN billed_no TEXT;
    END IF;

    -- Check and add invoice_amount
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                   WHERE table_name = 'orders' AND column_name = 'invoice_amount') THEN
        ALTER TABLE orders ADD COLUMN invoice_amount NUMERIC(10,2);
    END IF;

    -- Add new status 'Pending Verification' to order_status enum if not exists
    IF NOT EXISTS (SELECT 1 FROM pg_enum 
                   WHERE enumtypid = (SELECT oid FROM pg_type WHERE typname = 'order_status')
                   AND enumlabel = 'Pending Verification') THEN
        ALTER TYPE order_status ADD VALUE 'Pending Verification';
    END IF;

    -- Add new status 'Verified' to order_status enum if not exists
    IF NOT EXISTS (SELECT 1 FROM pg_enum 
                   WHERE enumtypid = (SELECT oid FROM pg_type WHERE typname = 'order_status')
                   AND enumlabel = 'Verified') THEN
        ALTER TYPE order_status ADD VALUE 'Verified';
    END IF;
END $$;

-- ─── 4. CREATE RPC FUNCTION: verify_order_and_update_balance ─────────────

CREATE OR REPLACE FUNCTION verify_order_and_update_balance(
    p_order_id TEXT,
    p_invoice_amount NUMERIC
)
RETURNS TABLE(
    success BOOLEAN,
    message TEXT,
    updated_balance NUMERIC
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_customer_id TEXT;
    v_team_id TEXT;
    v_current_balance NUMERIC;
    v_new_balance NUMERIC;
BEGIN
    -- Start transaction
    -- Get order details and lock the row
    SELECT o.customer_id, o.team_id
    INTO v_customer_id, v_team_id
    FROM orders o
    WHERE o.id = p_order_id
    FOR UPDATE;
    
    IF v_customer_id IS NULL THEN
        RETURN QUERY SELECT FALSE, 'Order not found', NULL::NUMERIC;
        RETURN;
    END IF;
    
    -- Get current customer balance
    SELECT ctp.outstanding_balance
    INTO v_current_balance
    FROM customer_team_profiles ctp
    WHERE ctp.customer_id = v_customer_id AND ctp.team_id = v_team_id
    FOR UPDATE;
    
    IF v_current_balance IS NULL THEN
        RETURN QUERY SELECT FALSE, 'Customer team profile not found', NULL::NUMERIC;
        RETURN;
    END IF;
    
    -- Calculate new balance
    v_new_balance := v_current_balance + p_invoice_amount;
    
    -- Update order status
    UPDATE orders
    SET 
        status = 'Verified',
        invoice_amount = p_invoice_amount,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_order_id;
    
    -- Update customer balance
    UPDATE customer_team_profiles
    SET 
        outstanding_balance = v_new_balance,
        updated_at = CURRENT_TIMESTAMP
    WHERE customer_id = v_customer_id AND team_id = v_team_id;
    
    -- Return success
    RETURN QUERY SELECT TRUE, 'Order verified and balance updated', v_new_balance;
    RETURN;
    
EXCEPTION
    WHEN OTHERS THEN
        -- Log the error for debugging
        INSERT INTO app_error_logs(error_message, order_id, team_id, error_type)
        VALUES (SQLERRM, p_order_id, v_team_id, 'balance_update_rpc');
        
        RETURN QUERY SELECT FALSE, 'Database error: ' || SQLERRM, NULL::NUMERIC;
        RETURN;
END;
$$;

-- ─── 5. GRANT EXECUTE PERMISSION ON RPC FUNCTION ─────────────────────────

GRANT EXECUTE ON FUNCTION verify_order_and_update_balance TO authenticated;

-- ─── 6. CREATE INDEXES FOR PERFORMANCE ─────────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_app_error_logs_order_id ON app_error_logs(order_id);
CREATE INDEX IF NOT EXISTS idx_app_error_logs_team_id ON app_error_logs(team_id);
CREATE INDEX IF NOT EXISTS idx_app_error_logs_resolved ON app_error_logs(resolved);
CREATE INDEX IF NOT EXISTS idx_app_error_logs_created_at ON app_error_logs(created_at DESC);

-- ─── 7. ADD INDEXES FOR ORDERS TABLE NEW COLUMNS ─────────────────────────

CREATE INDEX IF NOT EXISTS idx_orders_bill_photo_url ON orders(bill_photo_url);

-- Note: Index for Pending Verification status will be created in a separate migration
-- after the enum values are fully committed to avoid "unsafe use of new value" error

-- ============================================================
-- END OF PHASE 1 MIGRATION
-- ============================================================
