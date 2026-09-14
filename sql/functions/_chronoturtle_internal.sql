----------------------------------------------------------------------------------------------------
-- SCHEMA: _chronoturtle_internal (Internal functions)
----------------------------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION _chronoturtle_internal.get_schema_and_table_name(
    p_table_name TEXT
)
    RETURNS TABLE (schema_name TEXT, table_name TEXT)
    LANGUAGE plpgsql
AS
$$
BEGIN
    IF p_table_name NOT LIKE '%.%' THEN
        RAISE EXCEPTION 'No schema for table % defined', p_table_name;
    END IF;

    RETURN QUERY
        SELECT split_part(p_table_name, '.', 1),
               split_part(p_table_name, '.', 2);
END;
$$;

CREATE OR REPLACE FUNCTION _chronoturtle_internal.array_reverse(anyarray) RETURNS anyarray AS $$
SELECT ARRAY(
               SELECT $1[i]
               FROM generate_subscripts($1,1) AS s(i)
               ORDER BY i DESC
       );
$$ LANGUAGE 'sql' STRICT IMMUTABLE;
