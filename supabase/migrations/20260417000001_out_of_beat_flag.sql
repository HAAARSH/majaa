-- Out-of-Beat flag for orders and visit_logs.
--
-- Tags orders and visit logs that were created from the Out-of-Beat flow,
-- so managers can distinguish route compliance from walk-in / off-route
-- activity. Both default to false so all existing rows are treated as
-- normal in-beat activity.

ALTER TABLE orders
    ADD COLUMN IF NOT EXISTS is_out_of_beat BOOLEAN NOT NULL DEFAULT FALSE;

ALTER TABLE visit_logs
    ADD COLUMN IF NOT EXISTS is_out_of_beat BOOLEAN NOT NULL DEFAULT FALSE;

-- Partial indexes so reports filtering to OOB rows stay cheap on large tables.
CREATE INDEX IF NOT EXISTS idx_orders_is_out_of_beat
    ON orders (team_id, order_date)
    WHERE is_out_of_beat = TRUE;

CREATE INDEX IF NOT EXISTS idx_visit_logs_is_out_of_beat
    ON visit_logs (team_id, visit_date)
    WHERE is_out_of_beat = TRUE;
