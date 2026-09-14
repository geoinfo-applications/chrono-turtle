-- =========================================================
-- Test 01: API functions
-- =========================================================

-- Set search path to include chronoturtle schema
SET search_path TO chronoturtle, public;

CREATE SCHEMA animal;
CREATE SCHEMA human;

-- =========================================================
-- VIE
-- =========================================================
-- throws if the table does not exist
SELECT migrate_to_vie('animal.dog');

-- setup table
CREATE TABLE human.dog_owner
(
    id    SERIAL PRIMARY KEY,
    birth DATE NOT NULL,
    name  TEXT NOT NULL
);
CREATE TABLE animal.dog
(
    id           SERIAL PRIMARY KEY,
    birth        DATE NOT NULL,
    name         TEXT NOT NULL,
    race         TEXT NOT NULL,
    dog_owner_id INT  NOT NULL REFERENCES human.dog_owner (id)
);

-- throws without schema
SELECT migrate_to_vie('dog');

-- throws because there is not backing table
SELECT show_backing_table_name('animal.dog');

-- migrates
SELECT migrate_to_vie('human.dog_owner', 'animal.dog');

-- shows the backing table name
SELECT show_backing_table_name('animal.dog');
SELECT show_backing_table_name('human.dog_owner');

-- shows the view name
SELECT show_view_name(show_backing_table_name('animal.dog'));
SELECT show_view_name(show_backing_table_name('human.dog_owner'));

-- check view
SELECT COUNT(*)
FROM pg_class c
         JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'v'
  AND n.nspname IN ('human', 'animal')
  AND c.relname IN ('dog', 'dog_owner');

SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'animal'
  AND table_name = 'dog'
ORDER BY ordinal_position;

SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'human'
  AND table_name = 'dog_owner'
ORDER BY ordinal_position;

-- check backing tables
SELECT COUNT(*)
FROM pg_class c
         JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'r'
  AND n.nspname = '_backing'
  AND c.relname IN (show_backing_table_name('animal.dog'), show_backing_table_name('human.dog_owner'));

SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = '_backing'
  AND table_name = show_backing_table_name('animal.dog')
ORDER BY ordinal_position;

SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = '_backing'
  AND table_name = show_backing_table_name('human.dog_owner')
ORDER BY ordinal_position;

-- =========================================================
-- Author
-- =========================================================
SELECT set_commit_author('bob@example.com');

-- =========================================================
-- Branch
-- =========================================================
SELECT get_current_branch();
SELECT set_current_branch('feature/test1');
SELECT get_current_branch();
SELECT ensure_branch_exists('feature/test2');
SELECT get_current_branch();

-- Verify branches exist
SELECT array_agg(name ORDER BY name) AS branches_with_same_hash
FROM _vie.branch
GROUP BY head_commit_hash
ORDER BY 1;

-- Check creating from parent hash
BEGIN;
INSERT INTO public.dog_owner(id, birth, name)
VALUES (1, DATE('1990-11-21 09:31'), 'Jimmy');
INSERT INTO public.dog(id, birth, name, race, dog_owner_id)
VALUES (2, DATE('2025-11-21 09:31'), 'Henry', 'Corgy', 1);
END;

SELECT array_agg(name ORDER BY name) AS branches_with_same_hash
FROM _vie.branch
GROUP BY head_commit_hash
ORDER BY 1;

SELECT set_current_branch('feature/test3', 'feature/test1');

SELECT array_agg(name ORDER BY name) AS branches_with_same_hash
FROM _vie.branch
GROUP BY head_commit_hash
ORDER BY 1;

-- =========================================================
-- Migrate to VIE by schema
-- =========================================================
-- setup table
CREATE TABLE human.cat_owner
(
    id    SERIAL PRIMARY KEY,
    birth DATE NOT NULL,
    name  TEXT NOT NULL
);
CREATE TABLE animal.cat
(
    id           SERIAL PRIMARY KEY,
    birth        DATE    NOT NULL,
    name         TEXT    NOT NULL,
    race         TEXT    NOT NULL,
    lives_left   INTEGER NOT NULL DEFAULT 7,
    cat_owner_id INT     NOT NULL REFERENCES human.cat_owner (id)
);

-- migrates
SELECT migrate_schemas_to_vie('human', 'animal');

-- shows the backing table name
SELECT show_backing_table_name('animal.cat');
SELECT show_backing_table_name('human.cat_owner');

-- shows the view name
SELECT show_view_name(show_backing_table_name('animal.cat'));
SELECT show_view_name(show_backing_table_name('human.cat_owner'));

-- check view
SELECT COUNT(*)
FROM pg_class c
         JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'v'
  AND n.nspname IN ('human', 'animal')
  AND c.relname IN ('cat', 'cat_owner');

SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'animal'
  AND table_name = 'cat'
ORDER BY ordinal_position;

SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'human'
  AND table_name = 'cat_owner'
ORDER BY ordinal_position;

-- check backing tables
SELECT COUNT(*)
FROM pg_class c
         JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'r'
  AND n.nspname = '_backing'
  AND c.relname IN (show_backing_table_name('animal.cat'), show_backing_table_name('human.cat_owner'));

SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = '_backing'
  AND table_name = show_backing_table_name('animal.cat')
ORDER BY ordinal_position;

SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = '_backing'
  AND table_name = show_backing_table_name('human.cat_owner')
ORDER BY ordinal_position;

-- =========================================================
-- Check and modify constraints
-- =========================================================
SELECT * FROM get_constraints('animal.cat') WHERE constraint_type IN ('PRIMARY KEY', 'UNIQUE', 'FOREIGN KEY');
SELECT * FROM _vie.constraint_registry;
SELECT add_unique_constraint('animal.cat', 'name', 'race');
SELECT * FROM get_constraints('animal.cat') WHERE constraint_type IN ('PRIMARY KEY', 'UNIQUE', 'FOREIGN KEY');
SELECT * FROM _vie.constraint_registry;
SELECT drop_unique_constraint('animal.cat', 'name_race_key');
SELECT * FROM get_constraints('animal.cat') WHERE constraint_type IN ('PRIMARY KEY', 'UNIQUE', 'FOREIGN KEY');
SELECT * FROM _vie.constraint_registry;

-- =========================================================
-- Drop VIE
-- =========================================================
SELECT drop_vie_table('animal.dog', true);
SELECT drop_vie_table('human.dog_owner', true);
SELECT drop_vie_table('animal.cat', false);
SELECT drop_vie_table('human.cat_owner', false);

SELECT *
FROM animal.dog;
SELECT *
FROM human.dog_owner;
SELECT *
FROM animal.cat;
SELECT *
FROM human.cat_owner;

SELECT COUNT(*)
FROM pg_class c
         JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'r'
  AND n.nspname = '_backing'
  AND c.relname IN (show_backing_table_name('animal.dog'), show_backing_table_name('human.dog_owner'), show_backing_table_name('animal.cat'),
                    show_backing_table_name('human.cat_owner'));
