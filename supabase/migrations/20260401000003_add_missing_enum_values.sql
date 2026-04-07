-- Add missing status values to order_status enum.
-- Required for: delivery rep "Returned" button + admin "Flag for Review" button.
ALTER TYPE order_status ADD VALUE IF NOT EXISTS 'Returned';
ALTER TYPE order_status ADD VALUE IF NOT EXISTS 'Flagged';
