-- Test 00: Extension initialization
-- Tests basic extension installation and schema creation

CREATE EXTENSION chronoturtle;

-- Verify schemas exist
SELECT schema_name FROM information_schema.schemata
WHERE schema_name IN ('chronoturtle', '_vie', '_backing', '_chronoturtle_internal', '_vie_constraint', '_vie_cor', '_vie_migration', '_vie_trigger')
ORDER BY schema_name;

-- Verify _vie tables exist
SELECT table_name FROM information_schema.tables
WHERE table_schema = '_vie'
ORDER BY table_name;

-- Check _vie.branch table and columns
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = '_vie' AND table_name = 'branch'
ORDER BY ordinal_position;

-- Check _vie.commit table and columns
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = '_vie' AND table_name = 'commit'
ORDER BY ordinal_position;

-- Check _vie.tree table and columns
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = '_vie' AND table_name = 'tree'
ORDER BY ordinal_position;

-- Check _vie.commit_tree table and columns
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = '_vie' AND table_name = 'commit_tree'
ORDER BY ordinal_position;

-- Check _vie.table_registry table and columns
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = '_vie' AND table_name = 'table_registry'
ORDER BY ordinal_position;

-- Check _vie.constraint_registry table and columns
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = '_vie' AND table_name = 'constraint_registry'
ORDER BY ordinal_position;

-- Verify default branch exists
SELECT name FROM _vie.branch WHERE name = 'main';
