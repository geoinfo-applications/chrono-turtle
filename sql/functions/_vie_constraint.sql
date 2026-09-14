CREATE OR REPLACE FUNCTION _vie_constraint.get_constraints(p_table_name TEXT)
    RETURNS SETOF information_schema.table_constraints
    LANGUAGE plpgsql
AS
$$
DECLARE
    v_schema             TEXT;
    v_table              TEXT;
    v_backing_table_name TEXT;
BEGIN
    SELECT schema_name, table_name INTO v_schema, v_table FROM _chronoturtle_internal.get_schema_and_table_name(p_table_name);
    v_backing_table_name := _vie_core.get_backing_table_name(v_schema, v_table);

    RETURN QUERY
        SELECT *
        FROM information_schema.table_constraints
        WHERE table_schema = '_backing'
          AND table_name = v_backing_table_name;
END;
$$;

CREATE OR REPLACE FUNCTION _vie_constraint.add_unique_constraint(
    p_table_name TEXT,
    VARIADIC columns TEXT[]
)
    RETURNS TEXT
    LANGUAGE plpgsql
AS
$$
DECLARE
    v_schema             TEXT;
    v_table              TEXT;
    v_backing_table_name TEXT;
    v_constraint_name    TEXT;
BEGIN
    SELECT schema_name, table_name INTO v_schema, v_table FROM _chronoturtle_internal.get_schema_and_table_name(p_table_name);
    v_backing_table_name := _vie_core.get_backing_table_name(v_schema, v_table);

    v_constraint_name := format('%s_key', array_to_string(columns, '_'));
    EXECUTE format('ALTER TABLE _backing.%s ADD CONSTRAINT %s UNIQUE(%s)', v_backing_table_name, v_constraint_name, array_to_string(columns, ', '));
    INSERT INTO _vie.constraint_registry (backing_table_name, constraint_name, constraint_type, constraint_columns)
    VALUES (v_backing_table_name, v_constraint_name, 'UNIQUE', columns);

    RETURN v_constraint_name;
END;
$$;

CREATE OR REPLACE FUNCTION _vie_constraint.drop_unique_constraint(
    p_table_name TEXT,
    p_constraint_name TEXT
)
    RETURNS VOID
    LANGUAGE plpgsql
AS
$$
DECLARE
    v_schema             TEXT;
    v_table              TEXT;
    v_backing_table_name TEXT;
    v_has_constraint     BOOLEAN;
BEGIN
    SELECT schema_name, table_name INTO v_schema, v_table FROM _chronoturtle_internal.get_schema_and_table_name(p_table_name);
    v_backing_table_name := _vie_core.get_backing_table_name(v_schema, v_table);

    SELECT INTO v_has_constraint EXISTS(SELECT 1
                                        FROM _vie.constraint_registry
                                        WHERE constraint_name = p_constraint_name
                                          AND backing_table_name = v_backing_table_name
                                          AND constraint_type = 'UNIQUE');

    IF NOT v_has_constraint THEN
        RAISE EXCEPTION 'There is no UNIQUE constraint with the name % for any VIE table', p_constraint_name;
    END IF;

    EXECUTE format('ALTER TABLE _backing.%I DROP CONSTRAINT %s', v_backing_table_name, p_constraint_name);
    DELETE
    FROM _vie.constraint_registry
    WHERE constraint_name = p_constraint_name AND backing_table_name = v_backing_table_name AND constraint_type = 'UNIQUE';
END;
$$;

CREATE OR REPLACE FUNCTION _vie_constraint.store_table_constraints_in_registry(
    p_backing_table_name text
)
    RETURNS void AS
$$
DECLARE
    v_schema             TEXT := '_backing';
    l_constraint_name    TEXT;
    l_constraint_columns TEXT[];
    v_col_list           TEXT;
BEGIN
    -- Handle UNIQUE constraints
    FOR l_constraint_name IN
        SELECT DISTINCT constraint_name
        FROM information_schema.table_constraints
        WHERE table_schema = v_schema
          AND table_name = p_backing_table_name
          AND constraint_type = 'UNIQUE'
        LOOP
            IF (SELECT EXISTS (SELECT 1
                               FROM information_schema.key_column_usage
                               WHERE constraint_name = l_constraint_name
                                 AND key_column_usage.column_name = 'row_hash')) THEN
                CONTINUE;
            END IF;

            SELECT array_agg(column_name ORDER BY ordinal_position)
            INTO l_constraint_columns
            FROM information_schema.key_column_usage
            WHERE constraint_name = l_constraint_name;

            -- Store in registry instead of creating constraint
            INSERT INTO _vie.constraint_registry (backing_table_name, constraint_name, constraint_type, constraint_columns)
            VALUES (p_backing_table_name, l_constraint_name, 'UNIQUE', l_constraint_columns);

            -- Drop the constraint from backing table
            EXECUTE format('ALTER TABLE %I.%I DROP CONSTRAINT %s', v_schema, p_backing_table_name, l_constraint_name);
        END LOOP;

    -- Handle PRIMARY KEY constraints
    FOR l_constraint_name IN
        SELECT DISTINCT constraint_name
        FROM information_schema.table_constraints
        WHERE table_schema = v_schema
          AND table_name = p_backing_table_name
          AND constraint_type = 'PRIMARY KEY'
        LOOP
            SELECT array_agg(column_name ORDER BY ordinal_position)
            INTO l_constraint_columns
            FROM information_schema.key_column_usage
            WHERE constraint_name = l_constraint_name;

            IF l_constraint_name IS NULL OR array_length(l_constraint_columns, 1) IS NULL THEN
                RAISE EXCEPTION 'Table _backing.% must have one PK constraint', p_backing_table_name;
            END IF;

            -- Store in registry
            INSERT INTO _vie.constraint_registry (backing_table_name, constraint_name, constraint_type, constraint_columns)
            VALUES (p_backing_table_name, l_constraint_name, 'PRIMARY KEY', l_constraint_columns);

            -- Drop the old PK constraint from backing table
            EXECUTE format('ALTER TABLE %I.%I DROP CONSTRAINT IF EXISTS %I', v_schema, p_backing_table_name, l_constraint_name);

            -- Recreate PK with row_hash appended
            v_col_list := array_to_string(ARRAY(SELECT format('%I', unnest(l_constraint_columns))), ', ');
            EXECUTE format('ALTER TABLE %I.%I ADD PRIMARY KEY (%s, row_hash)', v_schema, p_backing_table_name, v_col_list);
        END LOOP;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION _vie_constraint.create_fks_on_backing_table(p_backing_table_name TEXT)
    RETURNS VOID
    LANGUAGE plpgsql
AS
$$
DECLARE
    l_fk RECORD;
BEGIN
    FOR l_fk IN
        SELECT * FROM temp_migrate_fks WHERE backing_table = p_backing_table_name
        LOOP
            EXECUTE format(
                    'ALTER TABLE _backing.%I ADD CONSTRAINT %I FOREIGN KEY (%s, %I) REFERENCES _backing.%I(%s, row_hash)',
                    p_backing_table_name,
                    l_fk.constraint_name,
                    array_to_string(l_fk.local_columns, ', '),
                    _vie_core.get_backing_table_name(l_fk.foreign_table_schema, l_fk.foreign_table_name) || '_hash',
                    (SELECT _vie_core.get_backing_table_name(l_fk.foreign_table_schema, l_fk.foreign_table_name)),
                    array_to_string(l_fk.foreign_columns, ', ')
                    );
        END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION _vie_constraint.drop_and_store_fks(p_backing_table_name TEXT)
    RETURNS VOID
    LANGUAGE plpgsql
AS
$$
DECLARE
    l_fk RECORD;
BEGIN
    FOR l_fk IN
        SELECT array_agg(DISTINCT kcu.column_name) AS local_columns,
               array_agg(DISTINCT ccu.column_name) AS foreign_columns,
               ccu.table_schema                    AS foreign_table_schema,
               ccu.table_name                      AS foreign_table_name,
               tc.constraint_name                  AS constraint_name
        FROM information_schema.table_constraints AS tc
                 JOIN information_schema.key_column_usage AS kcu
                      ON tc.constraint_name = kcu.constraint_name
                          AND tc.table_schema = kcu.table_schema
                 JOIN information_schema.constraint_column_usage AS ccu
                      ON tc.constraint_name = ccu.constraint_name
        WHERE tc.constraint_type = 'FOREIGN KEY'
          AND tc.table_schema = '_backing'
          AND tc.table_name = p_backing_table_name
        GROUP BY tc.constraint_name, ccu.table_schema, ccu.table_name
        LOOP
            EXECUTE format('ALTER TABLE _backing.%I ADD COLUMN IF NOT EXISTS %I BYTEA',
                           p_backing_table_name,
                           _vie_core.get_backing_table_name(l_fk.foreign_table_schema, l_fk.foreign_table_name) || '_hash');
            EXECUTE format('ALTER TABLE _backing.%I DROP CONSTRAINT IF EXISTS %I', p_backing_table_name, l_fk.constraint_name);

            INSERT INTO temp_migrate_fks(backing_table, local_columns, foreign_columns, foreign_table_schema, foreign_table_name,
                                         constraint_name)
            VALUES (p_backing_table_name, l_fk.local_columns, l_fk.foreign_columns, l_fk.foreign_table_schema, l_fk.foreign_table_name,
                    l_fk.constraint_name);
        END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION _vie_constraint.get_pk_columns(p_backing_table_name TEXT)
    RETURNS TEXT[]
    LANGUAGE plpgsql
AS
$$
DECLARE
    v_constraint_columns TEXT[];
BEGIN
    SELECT constraint_columns
    INTO v_constraint_columns
    FROM _vie.constraint_registry
    WHERE constraint_type = 'PRIMARY KEY'
      AND backing_table_name = p_backing_table_name;

    RETURN v_constraint_columns;
END;
$$;
