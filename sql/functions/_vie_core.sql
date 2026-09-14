CREATE OR REPLACE FUNCTION _vie_core.get_backing_table_name(
    p_schema_name TEXT,
    p_table_name TEXT
)
    RETURNS TEXT
    LANGUAGE plpgsql
AS
$$
BEGIN
    RETURN CASE
               WHEN p_schema_name = '_backing' THEN p_table_name
               ELSE p_schema_name || '__' || p_table_name END;
END;
$$;

CREATE OR REPLACE FUNCTION _vie_core.auto_commit(p_tree_hash_to_add BYTEA)
    RETURNS VOID
    LANGUAGE plpgsql
AS
$$
DECLARE
    v_current_branch    TEXT;
    v_parent_commit     BYTEA;
    v_current_tx_commit BYTEA;
    v_new_commit_hash   BYTEA;
    v_commit_author     TEXT;
    v_is_first_change   BOOLEAN;
BEGIN
    v_current_branch := chronoturtle.get_current_branch();
    PERFORM chronoturtle.ensure_branch_exists(v_current_branch);

    v_current_tx_commit := CASE
                               WHEN coalesce(current_setting('vie.current_tx_commit', true), '') = '' THEN NULL
                               ELSE decode(current_setting('vie.current_tx_commit', true), 'hex')
        END;

    v_is_first_change := (v_current_tx_commit IS NULL);

    v_commit_author := COALESCE(
            current_setting('vie.commit_author', true),
            current_setting('application_name', true),
            current_user::text
                       );

    IF v_is_first_change THEN
        SELECT head_commit_hash
        INTO v_parent_commit
        FROM _vie.branch
        WHERE name = v_current_branch;

        v_new_commit_hash := sha256(convert_to(
                array_to_string(array [
                                    COALESCE(v_parent_commit::text, ''),
                                    v_commit_author,
                                    'Auto-commit',
                                    extract(epoch from now())::text
                                    ], E'\x1F'),
                'UTF8'
                                    ));

        INSERT INTO _vie.commit (hash, parent_hash, author, message)
        VALUES (v_new_commit_hash, v_parent_commit, v_commit_author, 'Auto-commit');

        UPDATE _vie.branch
        SET head_commit_hash = v_new_commit_hash,
            updated_at       = NOW()
        WHERE name = v_current_branch;

        PERFORM set_config('vie.current_tx_commit', encode(v_new_commit_hash, 'hex'), true);
    ELSE
        v_new_commit_hash := v_current_tx_commit;
    END IF;

    INSERT INTO _vie.commit_tree (commit_hash, tree_hash)
    VALUES (v_new_commit_hash, p_tree_hash_to_add)
    ON CONFLICT DO NOTHING;

END;
$$;

CREATE OR REPLACE FUNCTION _vie_core.get_where_condition_for_current_branch(
    p_schema TEXT,
    p_table TEXT,
    p_backing_table_name TEXT
)
    RETURNS TEXT
    LANGUAGE plpgsql
AS
$func$
DECLARE
    v_pk_columns TEXT[];
BEGIN
    SELECT _vie_constraint.get_pk_columns(p_backing_table_name) INTO v_pk_columns;

    RETURN format(
            $$row_hash IN (
    WITH RECURSIVE commit_history AS (
        SELECT hash, parent_hash, 0 AS depth
        FROM _vie.commit
        JOIN _vie.branch ON hash = head_commit_hash
        WHERE name = chronoturtle.get_current_branch()

        UNION ALL

        SELECT c.hash, c.parent_hash, h.depth + 1
        FROM _vie.commit c
        JOIN commit_history h ON c.hash = h.parent_hash
    )
    SELECT DISTINCT ON (original_pks) row_hash
    FROM commit_history
    JOIN _vie.commit_tree ON hash = commit_hash
    JOIN _vie.tree ON tree_hash = _vie.tree.hash
    WHERE table_schema = %L
      AND table_name = %L
      AND original_pks IN (
        SELECT jsonb_object_agg(col, to_jsonb(data) -> col)
           FROM _backing.%I AS data, UNNEST(%L::TEXT[]) AS col
           GROUP BY %s)
    ORDER BY original_pks, commit_history.depth ASC
)$$,
            p_schema,
            p_table,
            p_backing_table_name,
            v_pk_columns,
            array_to_string(v_pk_columns, ',')
           );
END;
$func$;
