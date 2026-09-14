----------------------------------------------------------------------------------------------------
-- Initialization and Permissions
----------------------------------------------------------------------------------------------------

-- Initialize default branch (this also creates the initial commit)
SELECT chronoturtle.ensure_branch_exists('main');

-- Grant permissions
GRANT USAGE ON SCHEMA chronoturtle TO PUBLIC;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA chronoturtle TO PUBLIC;

-- Revoke direct access to internal schemas
REVOKE ALL ON SCHEMA _chronoturtle_internal FROM PUBLIC;
REVOKE ALL ON SCHEMA _vie FROM PUBLIC;
REVOKE ALL ON SCHEMA _backing FROM PUBLIC;
