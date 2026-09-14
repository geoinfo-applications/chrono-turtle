CREATE OR REPLACE FUNCTION _vie_migration.assert_table_is_convertable_to_vie(
    p_schema_name TEXT,
    p_table_name TEXT
)
    RETURNS VOID
    LANGUAGE plpgsql
AS
$$
BEGIN
    IF NOT EXISTS (SELECT 1
                   FROM information_schema.tables
                   WHERE table_schema = p_schema_name
                     AND table_name = p_table_name) THEN
        RAISE EXCEPTION 'Table %.% does not exist', p_schema_name, p_table_name;
    END IF;

    IF EXISTS (SELECT 1 FROM _vie.table_registry WHERE view_schema = p_schema_name AND view_name = p_table_name) THEN
        RAISE EXCEPTION 'Table %.% is already a VIE table', p_schema_name, p_table_name;
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION _vie_migration.move_data_to_temp_table(
    p_schema_name TEXT,
    p_table_name TEXT
)
    RETURNS TEXT
    LANGUAGE plpgsql
AS
$$
DECLARE
    v_dest_table_name TEXT;
BEGIN
    SELECT _vie_migration.get_temp_data_table_name(p_schema_name, p_table_name) INTO v_dest_table_name;
    EXECUTE format('CREATE TABLE IF NOT EXISTS _backing.%s (LIKE %s.%s INCLUDING ALL)', v_dest_table_name, p_schema_name, p_table_name);
    EXECUTE format('INSERT INTO _backing.%s SELECT * FROM %s.%s', v_dest_table_name, p_schema_name, p_table_name);
    EXECUTE format('TRUNCATE TABLE %s.%s CASCADE', p_schema_name, p_table_name);
    RETURN v_dest_table_name;
END;
$$;

CREATE OR REPLACE FUNCTION _vie_migration.get_temp_data_table_name(
    p_schema_name TEXT,
    p_table_name TEXT
)
    RETURNS TEXT
    LANGUAGE plpgsql
AS
$$
BEGIN
    RETURN format('temp_%s_%s', p_schema_name, p_table_name);
END;
$$;

CREATE OR REPLACE FUNCTION _vie_migration.rename_to_backing_table_name(
    p_schema_name TEXT,
    p_table_name TEXT
)
    RETURNS TEXT
    LANGUAGE plpgsql
AS
$$
DECLARE
    v_backing_table_name TEXT;
BEGIN
    v_backing_table_name := _vie_core.get_backing_table_name(p_schema_name, p_table_name);
    EXECUTE format('ALTER TABLE %s.%s SET SCHEMA _backing', p_schema_name, p_table_name);
    EXECUTE format('ALTER TABLE _backing.%s RENAME TO %s', p_table_name, v_backing_table_name);
    RETURN v_backing_table_name;
END;
$$;

CREATE OR REPLACE FUNCTION _vie_migration.assert_backing_table_exists(
    p_backing_table_name TEXT,
    p_schema_name TEXT,
    p_table_name TEXT
)
    RETURNS VOID
    LANGUAGE plpgsql
AS
$$
DECLARE
    v_exists BOOLEAN;
BEGIN
    SELECT EXISTS (SELECT 1
                   FROM information_schema.tables
                   WHERE table_schema = '_backing'
                     AND table_name = p_backing_table_name)
    INTO v_exists;
    IF NOT v_exists THEN
        RAISE EXCEPTION 'Backing table _backing.% does not exist for %.%', p_backing_table_name, p_schema_name, p_table_name;
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION _vie_migration.create_view(
    p_backing_table_name TEXT,
    p_view_schema TEXT,
    p_view_name TEXT
)
    RETURNS VOID
    LANGUAGE plpgsql
AS
$$
DECLARE
    v_view_columns TEXT[] := '{}';
BEGIN
    SELECT array_agg(column_name ORDER BY ordinal_position)
    INTO v_view_columns
    FROM information_schema.columns
    WHERE table_schema = '_backing'
      AND table_name = _vie_migration.get_temp_data_table_name(p_view_schema, p_view_name);

    IF v_view_columns IS NULL THEN
        RAISE EXCEPTION 'No columns found for _backing.%', p_backing_table_name;
    END IF;

    EXECUTE format($view$
            CREATE OR REPLACE VIEW %I.%I AS
            SELECT %s
            FROM _backing.%s
            WHERE %s
        $view$,
                   p_view_schema, p_view_name,
                   array_to_string(v_view_columns, ', '),
                   p_backing_table_name,
                   _vie_core.get_where_condition_for_current_branch(p_view_schema, p_view_name, p_backing_table_name)
            );

    EXECUTE format($trig$
            CREATE TRIGGER %I
            INSTEAD OF INSERT OR UPDATE ON %I.%I
            FOR EACH ROW EXECUTE FUNCTION _vie_trigger.generic_dml_trigger()
        $trig$, p_view_name || '_instead_of_insert_or_update', p_view_schema, p_view_name);

    EXECUTE format($trig$
            CREATE TRIGGER %I
            INSTEAD OF DELETE ON %I.%I
            FOR EACH ROW EXECUTE FUNCTION _vie_trigger.generic_delete_trigger()
        $trig$, p_view_name || '_instead_of_delete', p_view_schema, p_view_name);
END;
$$;

CREATE OR REPLACE FUNCTION _vie_migration.move_data_from_temp_to_backing_table(p_table_name TEXT)
    RETURNS VOID
    LANGUAGE plpgsql
AS
$$
DECLARE
    v_schema          TEXT;
    v_table           TEXT;
    v_dest_table_name TEXT;
    v_insert_cols     TEXT;
    v_exists          BOOLEAN;
BEGIN
    SELECT schema_name, table_name INTO v_schema, v_table FROM _chronoturtle_internal.get_schema_and_table_name(p_table_name);
    SELECT _vie_migration.get_temp_data_table_name(v_schema, v_table) INTO v_dest_table_name;
    SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = '_backing' AND table_name = v_dest_table_name) INTO v_exists;

    IF v_exists THEN
        SELECT array_to_string(array_agg(format('%I', column_name) ORDER BY ordinal_position), ', ')
        INTO v_insert_cols
        FROM information_schema.columns
        WHERE table_schema = '_backing'
          AND table_name = v_dest_table_name;

        IF v_insert_cols IS NOT NULL THEN
            EXECUTE format(
                    'INSERT INTO %s (%s) SELECT %s FROM _backing.%s ON CONFLICT DO NOTHING',
                    p_table_name,
                    v_insert_cols,
                    v_insert_cols,
                    v_dest_table_name
                    );
        END IF;
    END IF;

    EXECUTE format('DROP TABLE _backing.%s', v_dest_table_name);
END;
$$;

CREATE OR REPLACE FUNCTION _vie_migration.sort_tables_by_dependencies(VARIADIC p_table_names TEXT[])
    RETURNS TEXT[]
    LANGUAGE plpgsql
AS
$$
DECLARE
    v_sorted_tables    TEXT[]  := '{}';
    v_remaining_tables TEXT[]  := p_table_names;
    l_current_table    TEXT;
    l_has_dependency   BOOLEAN;
    l_made_progress    BOOLEAN := TRUE;
    l_iteration_count  INT     := 0;
    v_max_iterations   INT     := 1000;
BEGIN
    -- Keep iterating until all tables are sorted
    WHILE array_length(v_remaining_tables, 1) > 0 AND l_made_progress AND l_iteration_count < v_max_iterations
        LOOP
            l_made_progress := FALSE;
            l_iteration_count := l_iteration_count + 1;

            -- Check each remaining table
            FOR i IN 1..array_length(v_remaining_tables, 1)
                LOOP
                    l_current_table := v_remaining_tables[i];
                    l_has_dependency := FALSE;

                    -- Check if any remaining table has FK dependencies on l_current_table
                    SELECT EXISTS (SELECT 1
                                   FROM information_schema.table_constraints tc
                                            JOIN information_schema.constraint_column_usage ccu
                                                 ON tc.constraint_name = ccu.constraint_name
                                                     AND tc.constraint_schema = ccu.constraint_schema
                                   WHERE tc.constraint_type = 'FOREIGN KEY'
                                     AND (tc.table_schema || '.' || tc.table_name) = ANY (v_remaining_tables)
                                     AND tc.table_schema || '.' || tc.table_name != l_current_table
                                     AND ccu.table_schema || '.' || ccu.table_name = l_current_table)
                    INTO l_has_dependency;

                    -- If no other tables depend on this one, add to sorted list
                    IF NOT l_has_dependency THEN
                        v_sorted_tables := array_append(v_sorted_tables, l_current_table);
                        v_remaining_tables := array_remove(v_remaining_tables, l_current_table);
                        l_made_progress := TRUE;
                        EXIT; -- Start over with updated v_remaining_tables
                    END IF;
                END LOOP;
        END LOOP;

    -- Handle circular dependencies or orphaned tables
    IF array_length(v_remaining_tables, 1) > 0 THEN
        -- Append remaining tables (they likely have circular dependencies)
        v_sorted_tables := v_sorted_tables || v_remaining_tables;
    END IF;

    RETURN v_sorted_tables;
END;
$$;
