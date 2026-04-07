-- Fix RLS on customer_team_profiles (unified schema)
-- The table was recreated with team_ja/team_ma columns but RLS policies were lost.

-- Ensure RLS is enabled
ALTER TABLE customer_team_profiles ENABLE ROW LEVEL SECURITY;

-- Drop old policies if they exist
DROP POLICY IF EXISTS "ctp_authenticated_access" ON customer_team_profiles;
DROP POLICY IF EXISTS "ctp_select" ON customer_team_profiles;
DROP POLICY IF EXISTS "ctp_insert" ON customer_team_profiles;
DROP POLICY IF EXISTS "ctp_update" ON customer_team_profiles;
DROP POLICY IF EXISTS "ctp_delete" ON customer_team_profiles;

-- Create a permissive policy for all authenticated users
CREATE POLICY "ctp_authenticated_access" ON customer_team_profiles
  FOR ALL
  USING (auth.role() = 'authenticated')
  WITH CHECK (auth.role() = 'authenticated');
