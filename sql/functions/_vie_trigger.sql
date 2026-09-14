CREATE OR REPLACE FUNCTION _vie_trigger.generic_dml_trigger()
    RETURNS TRIGGER
    LANGUAGE plpgsql
AS
$$
DECLARE
    v_new_row_hash          BYTEA;
    v_tree_hash             BYTEA;
    v_placeholder_hash      BYTEA;
    v_old_row_hash          BYTEA;
    l_col_record            RECORD;
    l_fk_info               RECORD;
    l_constraint            RECORD;
    v_has_not_null_value    BOOLEAN;
    v_backing_table_name    TEXT;
    v_insert_sql            TEXT;
    v_pk_values             JSONB;
    v_pk_record             RECORD;
    v_pk_column_array       TEXT[];
    v_columns_with_defaults _vie.column_default_info[];
    l_column_default        TEXT;
    v_view_name             TEXT    := TG_TABLE_NAME;
    v_view_schema           TEXT    := TG_TABLE_SCHEMA;
    v_all_columns           TEXT[]  := '{}';
    v_all_placeholders      TEXT[]  := '{}';
    v_is_insert             BOOLEAN := (TG_OP = 'INSERT');
    v_is_update             BOOLEAN := (TG_OP = 'UPDATE');
    v_is_insert_with_pk     BOOLEAN := false;
BEGIN
    SELECT INTO v_backing_table_name chronoturtle.show_backing_table_name(format('%s.%s', v_view_schema, v_view_name))
    LIMIT 1;
    v_pk_column_array := _vie_constraint.get_pk_columns(v_backing_table_name);

    SELECT array_agg((column_name, column_default)::_vie.column_default_info)
    INTO v_columns_with_defaults
    FROM information_schema.columns
    WHERE table_schema = '_backing'
      AND table_name = v_backing_table_name
      AND column_default IS NOT NULL;

    FOR l_col_record IN
        SELECT column_name
        FROM information_schema.columns
        WHERE table_schema = v_view_schema
          AND table_name = v_view_name
        ORDER BY ordinal_position
        LOOP
            EXECUTE format('SELECT ($1).%I IS NOT NULL', l_col_record.column_name)
                USING NEW
                INTO v_has_not_null_value;

            SELECT column_default INTO l_column_default FROM unnest(v_columns_with_defaults) WHERE column_name = l_col_record.column_name;

            IF v_is_update OR l_col_record.column_name != ANY (v_pk_column_array) OR v_has_not_null_value THEN
                v_all_columns := array_append(v_all_columns, l_col_record.column_name);
                IF l_column_default IS NOT NULL AND NOT v_has_not_null_value THEN
                    v_all_placeholders := array_append(v_all_placeholders, l_column_default);
                ELSE
                    v_all_placeholders := array_append(v_all_placeholders,format('($2).%I', l_col_record.column_name));
                END IF;
            END IF;

            IF v_is_insert AND l_col_record.column_name = ANY (v_pk_column_array) AND v_has_not_null_value THEN
                v_is_insert_with_pk := true;
            END IF;
        END LOOP;

    -- Check all constraints (PRIMARY KEY and UNIQUE) from registry
    FOR l_constraint IN
        SELECT constraint_name, constraint_type, constraint_columns
        FROM _vie.constraint_registry
        WHERE backing_table_name = v_backing_table_name
        LOOP
            PERFORM _vie_trigger.check_for_duplicate_constraint(
                    v_view_schema,
                    v_view_name,
                    l_constraint.constraint_name,
                    l_constraint.constraint_columns,
                    NEW,
                    OLD
                    );
        END LOOP;

    v_placeholder_hash := sha256(convert_to(
            txid_current()::text || extract(epoch from clock_timestamp())::text,
            'UTF8'
                                 ));

    FOR l_fk_info IN
        SELECT * FROM _vie_trigger.get_table_fk_hashes(v_backing_table_name, v_all_columns)
        LOOP
            v_all_columns := v_all_columns || l_fk_info.local_fk_hash_columns;
            v_all_placeholders := array_append(v_all_placeholders,
                                               format('(SELECT _vie_trigger.get_current_row_hash(%L, (%L)::TEXT[], (%L)::TEXT[], $2))',
                                                      l_fk_info.foreign_table, l_fk_info.local_fk_id_columns, l_fk_info.foreign_pk_id_columns));
        END LOOP;

    SELECT format('INSERT INTO _backing.%s (row_hash, %s) VALUES ($1, %s) RETURNING *',
                  v_backing_table_name,
                  array_to_string(v_all_columns, ', '),
                  array_to_string(v_all_placeholders, ', ')
           )
    INTO v_insert_sql;

    EXECUTE v_insert_sql INTO v_pk_record USING v_placeholder_hash, NEW;

    v_new_row_hash := sha256(convert_to((to_jsonb(v_pk_record) - 'row_hash')::text, 'UTF8'));

    IF (SELECT _vie_trigger.row_hash_exists(v_backing_table_name, v_new_row_hash)) THEN
        EXECUTE format('DELETE FROM _backing.%s WHERE row_hash = $1', v_backing_table_name)
            USING v_placeholder_hash;
    ELSE
        EXECUTE format('UPDATE _backing.%s SET row_hash = $1 WHERE row_hash = $2', v_backing_table_name)
            USING v_new_row_hash, v_placeholder_hash;
    END IF;

    v_pk_values := _vie_trigger.get_pk_values(v_pk_column_array, v_pk_record);

    INSERT INTO _vie.tree (table_schema, table_name, original_pks, row_hash)
    VALUES (v_view_schema, v_view_name, v_pk_values, v_new_row_hash)
    ON CONFLICT DO NOTHING;

    SELECT hash
    INTO v_tree_hash
    FROM _vie.tree
    WHERE table_schema = v_view_schema
      AND table_name = v_view_name
      AND original_pks = v_pk_values
      AND row_hash = v_new_row_hash;

    PERFORM _vie_core.auto_commit(v_tree_hash);

    IF v_is_insert_with_pk THEN
        PERFORM _vie_trigger.forward_sequence(v_pk_column_array, v_backing_table_name);
    END IF;

    IF v_is_update THEN
        v_old_row_hash := _vie_trigger.get_current_row_hash(v_backing_table_name, v_pk_column_array, v_pk_column_array, OLD);

        IF v_old_row_hash != v_new_row_hash THEN
            PERFORM _vie_trigger.refresh_referencing_rows(OLD, v_backing_table_name, v_old_row_hash);
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION _vie_trigger.get_table_fk_hashes(
    p_backing_table_name TEXT,
    p_excluded_columns TEXT[] DEFAULT '{}'::TEXT[]
)
    RETURNS TABLE
            (
                foreign_schema        TEXT,
                foreign_table         TEXT,
                local_fk_hash_columns TEXT[],
                local_fk_id_columns   TEXT[],
                foreign_pk_id_columns TEXT[]
            )
    LANGUAGE plpgsql
AS
$$
BEGIN
    RETURN QUERY
        SELECT nsf.nspname::TEXT                                            AS foreign_schema,
               relf.relname::TEXT                                           AS foreign_table,
               ARRAY_AGG(DISTINCT att_local.attname::TEXT)
               FILTER (WHERE att_local.attname <> ALL (p_excluded_columns)) AS local_fk_hash_columns,
               ARRAY_AGG(att_local.attname::TEXT)
               FILTER (WHERE att_foreign.attname <> 'row_hash')             AS local_fk_id_columns,
               ARRAY_AGG(att_foreign.attname::TEXT)
               FILTER (WHERE att_foreign.attname <> 'row_hash')             AS foreign_pk_id_columns
        FROM pg_constraint con
                 JOIN pg_class rel ON rel.oid = con.conrelid
                 JOIN pg_namespace ns ON ns.oid = rel.relnamespace
                 JOIN pg_class relf ON relf.oid = con.confrelid
                 JOIN pg_namespace nsf ON nsf.oid = relf.relnamespace
                 JOIN LATERAL unnest(con.conkey) WITH ORDINALITY ord(colnum, ordinality) ON true
                 JOIN pg_attribute att_local
                      ON att_local.attrelid = con.conrelid AND att_local.attnum = ord.colnum
                 JOIN pg_attribute att_foreign
                      ON att_foreign.attrelid = con.confrelid AND att_foreign.attnum = con.confkey[ord.ordinality]
        WHERE con.contype = 'f'
          AND ns.nspname = '_backing'
          AND rel.relname = p_backing_table_name
        GROUP BY ns.nspname, rel.relname, nsf.nspname, relf.relname;
END;
$$;

CREATE OR REPLACE FUNCTION _vie_trigger.row_hash_exists(p_backing_table_name text, p_new_row_hash bytea)
    RETURNS boolean
    LANGUAGE plpgsql
AS
$$
DECLARE
    v_sql    text;
    v_result boolean;
BEGIN
    v_sql := format(
            'SELECT EXISTS (SELECT 1 FROM _backing.%s WHERE row_hash = $1)',
            p_backing_table_name
             );

    EXECUTE v_sql INTO v_result USING p_new_row_hash;

    RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION _vie_trigger.get_pk_values(p_pk_column_array TEXT[], p_pk_record RECORD)
    RETURNS JSONB
    LANGUAGE plpgsql
AS
$$
DECLARE
    v_pk_value JSONB;
BEGIN
    IF array_length(p_pk_column_array, 1) IS NULL THEN
        RAISE EXCEPTION 'PRIMARY KEY can not be NULL (%)', p_pk_record;
    END IF;

    SELECT jsonb_object_agg(l_col, to_jsonb(p_pk_record) -> l_col)
    INTO v_pk_value
    FROM UNNEST(p_pk_column_array) AS l_col;

    RETURN v_pk_value;
END;
$$;

CREATE OR REPLACE FUNCTION _vie_trigger.get_current_row_hash(
    p_backing_table_name TEXT,
    p_local_column_names TEXT[],
    p_foreign_column_names TEXT[],
    p_record RECORD
)
    RETURNS BYTEA
    LANGUAGE plpgsql
AS
$$
DECLARE
    v_schema             TEXT;
    v_table              TEXT;
    v_row_hash           BYTEA;
    v_pk_where_condition TEXT[] := '{}';
    l_iterator           INT;
    l_col_value          TEXT;
BEGIN
    IF (array_length(p_local_column_names, 1) != array_length(p_foreign_column_names, 1)) THEN
        RAISE EXCEPTION 'local and foreign columns length does not match % | %', p_local_column_names, p_foreign_column_names;
    END IF;

    FOR l_iterator IN 1..array_length(p_local_column_names, 1)
        LOOP
            EXECUTE format('SELECT ($1).%I', p_local_column_names[l_iterator]) INTO l_col_value USING p_record;
            v_pk_where_condition := array_append(v_pk_where_condition, format('%I = %L', p_foreign_column_names[l_iterator], l_col_value));
        END LOOP;

    SELECT schema_name, table_name INTO v_schema, v_table FROM chronoturtle.show_view_name(p_backing_table_name);

    EXECUTE format($sql$
        SELECT row_hash
        FROM _backing.%I
        WHERE %s
          AND %s
    $sql$,
                   p_backing_table_name,
                   array_to_string(v_pk_where_condition, ' AND '),
                   _vie_core.get_where_condition_for_current_branch(v_schema, v_table, p_backing_table_name)
            )
        INTO v_row_hash;

    RETURN v_row_hash;
END;
$$;

CREATE OR REPLACE FUNCTION _vie_trigger.refresh_referencing_rows(
    p_old_record RECORD,
    p_backing_table_name TEXT,
    p_old_row_hash BYTEA
)
    RETURNS VOID
    LANGUAGE plpgsql
AS
$$
DECLARE
    l_ref_fk                 RECORD;
    v_ref_backing_table_name TEXT;
    v_ref_view_schema        TEXT;
    v_ref_view_name          TEXT;
    v_ref_pk_id              TEXT;
    v_select_sql             TEXT;
    v_where_condition        TEXT;
    v_pk_column_name         TEXT;
    v_old_pk_id              TEXT;
    v_ref_pk_column          TEXT;
BEGIN
    SELECT column_name
    INTO v_pk_column_name
    FROM information_schema.key_column_usage
    WHERE constraint_name IN (SELECT _vie_constraint.get_pk_columns(p_backing_table_name))
      AND table_schema = '_backing'
      AND table_name = p_backing_table_name
      AND column_name != 'row_hash'
    LIMIT 1;

    EXECUTE format('SELECT ($1).%I::text', v_pk_column_name) INTO v_old_pk_id USING p_old_record;

    FOR l_ref_fk IN
        SELECT DISTINCT kcu.table_schema           AS ref_backing_schema,
                        kcu.table_name             AS ref_backing_table,
                        kcu.column_name            AS ref_fk_id_column,
                        kcu.column_name || '_hash' AS ref_fk_hash_column
        FROM information_schema.table_constraints AS tc
                 JOIN information_schema.key_column_usage AS kcu
                      ON tc.constraint_name = kcu.constraint_name
                          AND tc.table_schema = kcu.table_schema
                 JOIN information_schema.constraint_column_usage AS ccu
                      ON tc.constraint_name = ccu.constraint_name
        WHERE tc.constraint_type = 'FOREIGN KEY'
          AND ccu.table_schema = '_backing'
          AND ccu.table_name = p_backing_table_name
          AND ccu.column_name = v_pk_column_name
          AND kcu.table_schema = '_backing'
          AND kcu.column_name NOT LIKE '%_hash'
        LOOP
            v_ref_backing_table_name := l_ref_fk.ref_backing_table;

            SELECT schema_name, table_name
            INTO v_ref_view_schema, v_ref_view_name
            FROM chronoturtle.show_view_name(v_ref_backing_table_name);

            SELECT column_name
            INTO v_ref_pk_column
            FROM information_schema.key_column_usage
            WHERE constraint_name IN (SELECT constraint_name
                                      FROM information_schema.table_constraints
                                      WHERE constraint_type = 'PRIMARY KEY'
                                        AND table_schema = '_backing'
                                        AND table_name = v_ref_backing_table_name)
              AND table_schema = '_backing'
              AND table_name = v_ref_backing_table_name
              AND column_name != 'row_hash'
            LIMIT 1;

            v_where_condition := _vie_core.get_where_condition_for_current_branch(
                    v_ref_view_schema,
                    v_ref_view_name,
                    v_ref_backing_table_name
                                 );

            v_select_sql := format(
                    'SELECT %I FROM _backing.%I WHERE %I = %L AND %I = %L::BYTEA AND %s',
                    v_ref_pk_column,
                    v_ref_backing_table_name,
                    l_ref_fk.ref_fk_id_column,
                    v_old_pk_id,
                    l_ref_fk.ref_fk_hash_column,
                    p_old_row_hash,
                    v_where_condition
                            );

            FOR v_ref_pk_id IN EXECUTE v_select_sql
                LOOP
                    EXECUTE format(
                            'UPDATE %I.%I SET %I = %L WHERE %I = %L',
                            v_ref_view_schema,
                            v_ref_view_name,
                            v_ref_pk_column,
                            v_ref_pk_id,
                            v_ref_pk_column,
                            v_ref_pk_id
                            );
                END LOOP;
        END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION _vie_trigger.check_for_duplicate_constraint(
    p_schema TEXT,
    p_table_name TEXT,
    p_constraint_name TEXT,
    p_constraint_columns TEXT[],
    p_new_record RECORD,
    p_old_record RECORD DEFAULT NULL
)
    RETURNS VOID
    LANGUAGE plpgsql
AS
$$
DECLARE
    v_is_insert          BOOLEAN := (p_old_record IS NULL);
    v_where_clause       TEXT;
    l_col_name           TEXT;
    l_new_value          TEXT;
    l_old_value          TEXT;
    v_where_parts        TEXT[]  := '{}';
    v_is_duplicate       BOOLEAN;
    v_values_display     TEXT[]  := '{}';
    v_constraint_changed BOOLEAN := false;
BEGIN
    -- If this is an UPDATE, check if any constraint column changed
    IF v_is_insert = false THEN
        FOREACH l_col_name IN ARRAY p_constraint_columns
            LOOP
                EXECUTE format('SELECT ($1).%I::TEXT', l_col_name) INTO l_new_value USING p_new_record;
                EXECUTE format('SELECT ($1).%I::TEXT', l_col_name) INTO l_old_value USING p_old_record;

                IF l_new_value IS DISTINCT FROM l_old_value THEN
                    v_constraint_changed := true;
                    EXIT;
                END IF;
            END LOOP;

        -- If no constraint column changed, no need to check
        IF NOT v_constraint_changed THEN
            RETURN;
        END IF;
    END IF;

    -- Build WHERE clause for all columns in the constraint
    FOREACH l_col_name IN ARRAY p_constraint_columns
        LOOP
            EXECUTE format('SELECT ($1).%I::TEXT', l_col_name) INTO l_new_value USING p_new_record;
            v_where_parts := array_append(v_where_parts, format('%I::TEXT = %L::TEXT', l_col_name, l_new_value));
            v_values_display := array_append(v_values_display, format('%s = %s', l_col_name, l_new_value));
        END LOOP;

    v_where_clause := array_to_string(v_where_parts, ' AND ');

    -- Check if the combination exists in the view
    EXECUTE format('SELECT EXISTS (SELECT 1 FROM %s.%s WHERE %s)',
                   p_schema,
                   p_table_name,
                   v_where_clause
            )
        INTO v_is_duplicate;

    IF v_is_duplicate THEN
        RAISE EXCEPTION 'duplicate key value violates unique constraint "%" for table %.%: (%)',
            p_constraint_name, p_schema, p_table_name, array_to_string(v_values_display, ', ');
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION _vie_trigger.generic_delete_trigger()
    RETURNS TRIGGER
    LANGUAGE plpgsql AS
$$
DECLARE
    v_tree_hash          BYTEA;
    v_pk_values          JSONB;
    v_pk_column_array    TEXT[];
    v_backing_table_name TEXT;
    v_view_name          TEXT   := TG_TABLE_NAME;
    v_view_schema        TEXT   := TG_TABLE_SCHEMA;
    v_pk_record          RECORD := OLD;
BEGIN
    SELECT INTO v_backing_table_name chronoturtle.show_backing_table_name(format('%s.%s', v_view_schema, v_view_name))
    LIMIT 1;

    v_pk_column_array := _vie_constraint.get_pk_columns(v_backing_table_name);
    v_pk_values := _vie_trigger.get_pk_values(v_pk_column_array, v_pk_record);

    INSERT INTO _vie.tree (table_schema, table_name, original_pks, row_hash)
    VALUES (v_view_schema, v_view_name, v_pk_values, NULL)
    ON CONFLICT DO NOTHING;

    SELECT hash
    INTO v_tree_hash
    FROM _vie.tree
    WHERE table_schema = v_view_schema
      AND table_name = v_view_name
      AND original_pks = v_pk_values
      AND row_hash IS NULL;

    PERFORM _vie_core.auto_commit(v_tree_hash);

    RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION _vie_trigger.forward_sequence(
    p_pk_columns TEXT[],
    p_backing_table_name TEXT
)
    RETURNS VOID
    LANGUAGE plpgsql
AS
$$
DECLARE
    v_serial_sequence TEXT;
    l_pk_column       TEXT;
BEGIN
    FOREACH l_pk_column IN ARRAY p_pk_columns
        LOOP
            SELECT pg_get_serial_sequence(format('_backing.%s', p_backing_table_name), l_pk_column)
            INTO v_serial_sequence;
            IF v_serial_sequence IS NOT NULL THEN
                EXECUTE format('SELECT SETVAL(''%s'', (SELECT COALESCE(MAX(%s)::integer, 1) FROM _backing.%s))',
                               v_serial_sequence, l_pk_column, p_backing_table_name);
            END IF;
            v_serial_sequence := NULL;
        END LOOP;
END;
$$;
