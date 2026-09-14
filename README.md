# ChronoTurtle

Git-like version control for PostgreSQL tables, written as a pure SQL extension.

![ChronoTurtle logo](./chronoturtle.png)

> **Status: unmaintained.** GEOINFO Applications AG built ChronoTurtle as a feasibility study and decided not to
> use it. It is published as-is, without support, and is not developed further.

## Overview

ChronoTurtle turns ordinary tables into *VIE tables* (Versioned Immutable Entities). Migrating a table replaces it
with a view of the same name and moves the data into an append-only backing table in the `_backing` schema. Every
`INSERT`, `UPDATE` and `DELETE` on the view is stored as an immutable row version and recorded in a commit on the
session's current branch. The view always shows the state of the current branch.

### What works

- Converting existing tables, or all tables of a schema, into VIE tables. Foreign keys between them are kept, and the
  migration order is resolved automatically.
- `INSERT`, `UPDATE` and `DELETE` through the view. Each transaction that changes data creates one commit on the
  current branch.
- Branches: create a branch from another one and switch the session to it. Changes on one branch are invisible on
  the others.
- A commit author per session.
- Unique constraints on VIE tables, enforced within the current branch.
- Converting a VIE table back into a plain table.

### What is missing

- No merge, rebase or cherry-pick between branches.
- No log, diff, revert or checkout of an older commit. History is only reachable by querying the `_vie` tables.
- No way to delete or rename a branch.
- No column changes on a VIE table and no `TRUNCATE` (see [Limitations](#limitations)).
- Nothing ever removes old row versions or commits; backing tables only grow.
- Only version 0.1.0 exists. There are no upgrade scripts.
- Tested on PostgreSQL 16 only.
- Table and schema names that need quoting for reasons other than being a reserved word, such as mixed case or
  spaces, are not supported: migrating such a table fails.

## Quick Start

### Installation

Requirements:

- PostgreSQL 16. Other versions are untested.
- The PostgreSQL server development files, which provide `pg_config` (`postgresql-server-dev-16` on Debian and Ubuntu).

ChronoTurtle is plain SQL and PL/pgSQL and needs no other extension. PostGIS is only used by the test suite.

```bash
make
sudo make install
```

`make install` uses the first `pg_config` on the `PATH`. To install into a specific PostgreSQL installation:

```bash
sudo make install PG_CONFIG=/usr/lib/postgresql/16/bin/pg_config
```

### Enable in Database

```sql
CREATE EXTENSION chronoturtle;

-- Add chronoturtle to search path
SET search_path TO chronoturtle, public;
```

### Basic Example

```sql
-- Create and migrate a table
CREATE TABLE public.user (
    id SERIAL PRIMARY KEY,
    username TEXT NOT NULL,
    email TEXT NOT NULL
);

INSERT INTO public.user (username, email) VALUES ('alice', 'alice@example.com');

-- Convert to VIE table
SELECT migrate_to_vie('public.user');

-- Set commit author
SELECT set_commit_author('bob@example.com');

-- Make changes - automatically versioned
UPDATE public.user SET email = 'alice@example.org' WHERE username = 'alice';

-- View backing table structure
SELECT show_backing_table_name('public.user');  -- Returns: public__user

-- The backing table keeps every row version
SELECT * FROM _backing.public__user;
-- Columns: id, username, email, row_hash (BYTEA)

-- View shows only current branch data
SELECT * FROM public.user;
-- Returns: 1 | alice | alice@example.org

-- Create and switch branches
SELECT set_current_branch('feature/test', 'main');
INSERT INTO public.user (username, email) VALUES ('bob', 'bob@example.com');

-- Switch back to main
SELECT set_current_branch('main');
SELECT * FROM public.user;  -- Bob not visible on main branch

-- View version control metadata
SELECT * FROM _vie.branch;
SELECT * FROM _vie.commit ORDER BY created_at DESC LIMIT 5;
```

## Schemas

- **`chronoturtle`**: Public API functions (user-facing)
- **`_vie`**: Version control metadata (commits, branches, trees)
- **`_vie_core`**: Core utility functions for VIE operations (auto-commit, backing table naming)
- **`_vie_constraint`**: Functions that manage constraints on backing tables
- **`_vie_migration`**: Migration functions for converting tables to VIE
- **`_vie_trigger`**: Trigger functions for handling DML operations on VIE views
- **`_backing`**: Physical storage for versioned data (naming: `schema__table`)
- **`_chronoturtle_internal`**: Internal helper functions

## API Functions

Table names are always passed as `'schema.table'`, unquoted.

### Migration and Management

**`migrate_to_vie(VARIADIC p_table_names TEXT[])`**

Convert existing tables to VIE tables. Automatically sorts tables by foreign key dependencies.

```sql
-- Single table
SELECT migrate_to_vie('public.user');

-- Multiple tables with FK relationships (order doesn't matter)
SELECT migrate_to_vie('public.city', 'public.country');
-- Automatically sorted: country first, then city
```

**`migrate_schemas_to_vie(VARIADIC p_schemas TEXT[])`**

Convert all tables in the specified schemas to VIE tables. Automatically discovers and sorts tables.

```sql
-- Migrate entire schema
SELECT migrate_schemas_to_vie('public');

-- Migrate multiple schemas
SELECT migrate_schemas_to_vie('public', 'auth');
```

**`drop_vie_table(p_table_name TEXT, p_remove_data BOOLEAN DEFAULT FALSE)`**

Turn a VIE table back into a plain table. By default the backing table is moved back under the original name. It
still contains every stored row version of all branches, plus the `row_hash` column and one hash column per foreign
key. With `p_remove_data => true` the backing table is dropped and the data is gone.

```sql
SELECT drop_vie_table('public.user');        -- keep the data
SELECT drop_vie_table('public.user', true);  -- drop the data
```

**`show_backing_table_name(p_table_name TEXT)`**

Returns the backing table name for a VIE table.

```sql
SELECT show_backing_table_name('public.user');  -- Returns: 'public__user'
```

**`show_view_name(p_backing_table_name TEXT)`**

Returns the view schema and name for a backing table.

```sql
SELECT * FROM show_view_name('public__user');  -- Returns: schema_name='public', table_name='user'
```

### Constraints

**`add_unique_constraint(p_table_name TEXT, VARIADIC columns TEXT[])`**

Add a unique constraint over one or more columns and return its name (`<column>_<column>_key`). It is checked
against the rows visible on the current branch.

```sql
SELECT add_unique_constraint('public.user', 'email');  -- Returns: 'email_key'
```

**`drop_unique_constraint(p_table_name TEXT, p_constraint_name TEXT)`**

```sql
SELECT drop_unique_constraint('public.user', 'email_key');
```

**`get_constraints(p_table_name TEXT)`**

Returns the constraints of the backing table as rows of `information_schema.table_constraints`.

```sql
SELECT constraint_name, constraint_type FROM get_constraints('public.user');
```

### Branch Management

**`set_current_branch(branch_name TEXT, parent_branch_name TEXT DEFAULT 'main')`**

Switch the session to a branch. If the branch does not exist, it is created from the head of `parent_branch_name`.

```sql
SELECT set_current_branch('feature/test');
```

**`get_current_branch()`**

Get the current branch name. A new session starts on `main`.

```sql
SELECT get_current_branch();  -- Returns: 'main'
```

**`ensure_branch_exists(branch_name TEXT DEFAULT NULL, parent_branch_name TEXT DEFAULT 'main')`**

Create a branch if it doesn't exist, without switching to it. Without `branch_name` it uses the current branch. If
`parent_branch_name` does not exist either, the branch starts with an empty initial commit.

```sql
SELECT ensure_branch_exists('feature/new');
```

### Session Management

**`set_commit_author(author_name TEXT)`**

Set the commit author for the current session. Without it, commits use the session's `application_name`, or the
database user.

```sql
SELECT set_commit_author('alice@example.com');
```

## Limitations

**Column modifications are not supported.** The only way is to convert back, change the table and convert again,
which discards the version history:

1. `SELECT drop_vie_table('schema.table_name');` The table comes back with every stored row version of all
   branches and the hash columns.
2. Recreate the table with the new structure and copy in the rows you want to keep.
3. `SELECT migrate_to_vie('schema.table_name');`

**TRUNCATE is not supported on VIE views.** Views do not support TRUNCATE operations. Use DELETE instead:

```sql
-- This will NOT work:
TRUNCATE public.user;  -- ERROR: cannot truncate a view

-- Use this instead:
DELETE FROM public.user;
```

## Testing

### Run Tests

The suite only needs Docker:

```bash
test/run-in-docker.sh
```

It builds `test/db/Dockerfile` (PostgreSQL 16 with PostGIS), installs the extension into a throwaway container and runs
`make installcheck` there. On failure it prints `test/regression.diffs`.

### Test Files

- `test/sql/00_init.sql` - Extension initialization
- `test/sql/01_api_functions.sql` - API functions, branches, constraints and converting back
- `test/sql/02_vie_migration_and_dml.sql` - Migrating a multi-schema model with PostGIS columns, then DML on it
- `test/sql/03_rows_across_tables.sql` - Equal keys and equal content in different VIE tables
- `test/sql/04_reserved_names.sql` - Tables named after reserved SQL words

## License

ChronoTurtle is released under the [PostgreSQL License](LICENSE).

The logo `chronoturtle.png` was generated with ChatGPT (GPT-4o) and is not covered by this license.
