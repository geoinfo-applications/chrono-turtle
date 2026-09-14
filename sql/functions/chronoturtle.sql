----------------------------------------------------------------------------------------------------
-- SCHEMA: chronoturtle (Public API)
----------------------------------------------------------------------------------------------------

-- Set commit author for current session
CREATE OR REPLACE FUNCTION chronoturtle.set_commit_author(author_name TEXT)
    RETURNS VOID AS $$
BEGIN
    PERFORM set_config('vie.commit_author', author_name, false);
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION chronoturtle.set_commit_author IS 'Set the commit author for the current session';

CREATE OR REPLACE FUNCTION chronoturtle.get_current_branch()
    RETURNS TEXT AS
$$
BEGIN
    RETURN COALESCE(current_setting('vie.current_branch', true), 'main');
END;

$$ LANGUAGE plpgsql STABLE;
CREATE OR REPLACE FUNCTION chronoturtle.set_current_branch(branch_name TEXT, parent_branch_name TEXT DEFAULT 'main')
    RETURNS VOID AS
$$
BEGIN
    PERFORM chronoturtle.ensure_branch_exists(branch_name, parent_branch_name);
    PERFORM set_config('vie.current_branch', branch_name, false);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION chronoturtle.ensure_branch_exists(branch_name TEXT DEFAULT NULL, parent_branch_name TEXT DEFAULT 'main')
    RETURNS VOID
    LANGUAGE plpgsql
AS
$$
DECLARE
    v_target_branch       TEXT;
    v_initial_commit_hash BYTEA;
BEGIN
    v_target_branch := COALESCE(branch_name, chronoturtle.get_current_branch());

    IF NOT EXISTS (SELECT 1 FROM _vie.branch WHERE name = v_target_branch) THEN
        IF EXISTS (SELECT 1 FROM _vie.branch WHERE name = parent_branch_name) THEN
            INSERT INTO _vie.branch (name, head_commit_hash)
            VALUES (v_target_branch, (SELECT head_commit_hash FROM _vie.branch WHERE name = parent_branch_name));
        ELSE
            v_initial_commit_hash := sha256(
                    ('INITIAL|' || v_target_branch || '|' ||
                     COALESCE(current_setting('vie.commit_author', true), current_user::text) || '|' ||
                     extract(epoch from now())::text)::bytea
                                     );

            INSERT INTO _vie.commit (hash, parent_hash, author, message)
            VALUES (v_initial_commit_hash,
                    NULL,
                    COALESCE(current_setting('vie.commit_author', true), current_user::text),
                    'Initial commit');

            INSERT INTO _vie.branch (name, head_commit_hash)
            VALUES (v_target_branch, v_initial_commit_hash);
        END IF;
    END IF;
END;
$$;

COMMENT ON FUNCTION chronoturtle.ensure_branch_exists IS 'Ensure branch exists and initialize if needed';

CREATE OR REPLACE FUNCTION chronoturtle.show_backing_table_name(
    p_table_name TEXT
)
    RETURNS TEXT
    LANGUAGE plpgsql
AS
$$
DECLARE
    v_schema             TEXT;
    v_table              TEXT;
    v_backing_table_name TEXT;
BEGIN
    SELECT schema_name, table_name INTO v_schema, v_table FROM _chronoturtle_internal.get_schema_and_table_name(p_table_name);

    SELECT backing_table_name
    INTO v_backing_table_name
    FROM _vie.table_registry
    WHERE view_schema = v_schema
      AND view_name = v_table;

    IF v_backing_table_name IS NULL THEN
        RAISE EXCEPTION 'No backing table found for %.%', v_schema, v_table;
    END IF;

    RETURN v_backing_table_name;
END;
$$;

COMMENT ON FUNCTION chronoturtle.show_backing_table_name IS 'Show the backing table name for a VIE table';

CREATE OR REPLACE FUNCTION chronoturtle.show_view_name(
    p_backing_table_name TEXT
)
    RETURNS TABLE
            (
                schema_name TEXT,
                table_name  TEXT
            )
    LANGUAGE plpgsql
AS
$$
DECLARE
    v_schema TEXT;
    v_table  TEXT;
BEGIN
    SELECT view_schema, view_name
    INTO v_schema, v_table
    FROM _vie.table_registry
    WHERE backing_table_name = p_backing_table_name;

    IF v_schema IS NULL OR v_table IS NULL THEN
        RAISE EXCEPTION 'No view found for backing table: %', p_backing_table_name;
    END IF;

    RETURN QUERY SELECT v_schema, v_table;
END;
$$;


CREATE OR REPLACE FUNCTION chronoturtle.migrate_to_vie(
    VARIADIC p_table_names TEXT[]
)
    RETURNS VOID
    LANGUAGE plpgsql
AS
$$
DECLARE
    l_table_name           TEXT;
    l_schema               TEXT;
    l_table                TEXT;
    l_dest_table_name      TEXT;
    l_backing_table_name   TEXT;
    v_sorted_table_names   TEXT[] := _vie_migration.sort_tables_by_dependencies(VARIADIC p_table_names);
    v_reversed_table_names TEXT[] := _chronoturtle_internal.array_reverse(v_sorted_table_names);
BEGIN
    CREATE TEMP TABLE IF NOT EXISTS temp_migrate_fks
    (
        backing_table        TEXT,
        local_columns        TEXT[],
        foreign_columns      TEXT[],
        foreign_table_schema TEXT,
        foreign_table_name   TEXT,
        constraint_name      TEXT
    ) ON COMMIT DROP;

    FOREACH l_table_name IN ARRAY v_sorted_table_names
        LOOP
            SELECT schema_name, table_name INTO l_schema, l_table FROM _chronoturtle_internal.get_schema_and_table_name(l_table_name);

            PERFORM _vie_migration.assert_table_is_convertable_to_vie(l_schema, l_table);
            SELECT _vie_migration.move_data_to_temp_table(l_schema, l_table) INTO l_dest_table_name;
            SELECT _vie_migration.rename_to_backing_table_name(l_schema, l_table) INTO l_backing_table_name;
            PERFORM _vie_migration.assert_backing_table_exists(l_backing_table_name, l_schema, l_table);

            INSERT INTO _vie.table_registry (backing_table_name, view_name, view_schema)
            VALUES (l_backing_table_name, l_table, l_schema)
            ON CONFLICT DO NOTHING;

            EXECUTE format('ALTER TABLE _backing.%I ADD COLUMN row_hash BYTEA', l_backing_table_name);
            PERFORM _vie_constraint.drop_and_store_fks(l_backing_table_name);
        END LOOP;

    FOREACH l_table_name IN ARRAY v_reversed_table_names
        LOOP
            SELECT schema_name, table_name INTO l_schema, l_table FROM _chronoturtle_internal.get_schema_and_table_name(l_table_name);
            SELECT chronoturtle.show_backing_table_name(l_table_name) INTO l_backing_table_name;

            PERFORM _vie_constraint.store_table_constraints_in_registry(l_backing_table_name);
        END LOOP;

    FOREACH l_table_name IN ARRAY p_table_names
        LOOP
            SELECT schema_name, table_name INTO l_schema, l_table FROM _chronoturtle_internal.get_schema_and_table_name(l_table_name);
            SELECT chronoturtle.show_backing_table_name(l_table_name) INTO l_backing_table_name;

            PERFORM _vie_migration.create_view(l_backing_table_name, l_schema, l_table);
            PERFORM _vie_constraint.create_fks_on_backing_table(l_backing_table_name);
        END LOOP;

    FOREACH l_table_name IN ARRAY v_reversed_table_names
        LOOP
            PERFORM _vie_migration.move_data_from_temp_to_backing_table(l_table_name);
        END LOOP;
END;
$$;

COMMENT ON FUNCTION chronoturtle.migrate_to_vie(p_table_names TEXT[]) IS 'Convert existing tables into a VIE (versioned) tables';

CREATE OR REPLACE FUNCTION chronoturtle.drop_vie_table(
    p_table_name TEXT,
    p_remove_data BOOLEAN DEFAULT FALSE
)
    RETURNS VOID
    LANGUAGE plpgsql
AS
$$
DECLARE
    v_schema             TEXT;
    v_table              TEXT;
    v_backing_table_name TEXT;
BEGIN
    SELECT schema_name, table_name INTO v_schema, v_table FROM _chronoturtle_internal.get_schema_and_table_name(p_table_name);
    SELECT INTO v_backing_table_name chronoturtle.show_backing_table_name(p_table_name) LIMIT 1;

    DELETE FROM _vie.table_registry WHERE backing_table_name = v_backing_table_name;
    DELETE FROM _vie.constraint_registry WHERE backing_table_name = v_backing_table_name;

    EXECUTE format('DROP VIEW IF EXISTS %I.%I', v_schema, v_table);

    IF p_remove_data THEN
        EXECUTE format('DROP TABLE IF EXISTS _backing.%I CASCADE', v_backing_table_name);
    ELSE
        EXECUTE format('ALTER TABLE _backing.%I SET SCHEMA %I', v_backing_table_name, v_schema);
        EXECUTE format('ALTER TABLE %I.%I RENAME TO %I', v_schema, v_backing_table_name, v_table);
    END IF;
END;
$$;

COMMENT ON FUNCTION chronoturtle.drop_vie_table IS 'Drop a VIE table and backing table';

CREATE OR REPLACE FUNCTION chronoturtle.migrate_schemas_to_vie(
    VARIADIC p_schemas TEXT[]
)
    RETURNS VOID
    LANGUAGE plpgsql
AS
$$
DECLARE
    v_table_names TEXT[];
BEGIN
    SELECT DISTINCT array_agg(table_schema || '.' || table_name)
    INTO v_table_names
    FROM information_schema.tables
    WHERE table_type = 'BASE TABLE'
      AND table_schema = ANY (p_schemas);

    PERFORM chronoturtle.migrate_to_vie(VARIADIC v_table_names);
END;
$$;

COMMENT ON FUNCTION chronoturtle.migrate_schemas_to_vie(p_schemas TEXT[]) IS 'Convert tables inside given schemas into a VIE (versioned) tables';

CREATE OR REPLACE FUNCTION chronoturtle.get_constraints(p_table_name TEXT)
    RETURNS SETOF information_schema.table_constraints
    LANGUAGE plpgsql
AS
$$
BEGIN
    RETURN QUERY SELECT * FROM _vie_constraint.get_constraints(p_table_name);
END;
$$;

COMMENT ON FUNCTION chronoturtle.get_constraints(p_table_name TEXT) IS 'Returns constraints for the backing table of the given view name';

CREATE OR REPLACE FUNCTION chronoturtle.add_unique_constraint(
    p_table_name TEXT,
    VARIADIC columns TEXT[]
)
    RETURNS TEXT
    LANGUAGE plpgsql
AS
$$
BEGIN
    RETURN _vie_constraint.add_unique_constraint(p_table_name, VARIADIC columns);
END;
$$;

COMMENT ON FUNCTION chronoturtle.add_unique_constraint(p_table_name TEXT, VARIADIC columns TEXT[]) IS 'Adds unique constraint for the given table and columns';

CREATE OR REPLACE FUNCTION chronoturtle.drop_unique_constraint(p_table_name TEXT, p_constraint_name TEXT)
    RETURNS VOID
    LANGUAGE plpgsql
AS
$$
BEGIN
    PERFORM _vie_constraint.drop_unique_constraint(p_table_name, p_constraint_name);
END;
$$;

COMMENT ON FUNCTION chronoturtle.drop_unique_constraint(p_table_name TEXT, p_constraint_name TEXT) IS 'Drops the unique constraint for a vie table';
