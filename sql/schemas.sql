-- Create schemas (without IF NOT EXISTS for extension compatibility)
CREATE SCHEMA _chronoturtle_internal;
CREATE SCHEMA _vie;
CREATE SCHEMA _vie_constraint;
CREATE SCHEMA _vie_core;
CREATE SCHEMA _vie_migration;
CREATE SCHEMA _vie_trigger;
CREATE SCHEMA _backing;

COMMENT ON SCHEMA chronoturtle IS 'Public API for chronoturtle version control';
COMMENT ON SCHEMA _chronoturtle_internal IS 'Internal functions - do not use directly';
COMMENT ON SCHEMA _vie IS 'Version control metadata tables (tree, commit, branch, etc.)';
COMMENT ON SCHEMA _vie_constraint IS 'Functions to manage constraints';
COMMENT ON SCHEMA _vie_core IS 'Core utility functions for VIE operations (auto_commit, backing table naming, where conditions)';
COMMENT ON SCHEMA _vie_migration IS 'Migration functions for converting regular tables to VIE tables';
COMMENT ON SCHEMA _vie_trigger IS 'Trigger functions for handling DML operations (INSERT, UPDATE, DELETE) on VIE views';
COMMENT ON SCHEMA _backing IS 'Backing tables for vie versioned tables';

-- Set search path for the extension
SET search_path TO chronoturtle, _chronoturtle_internal, _vie, _backing, public;
