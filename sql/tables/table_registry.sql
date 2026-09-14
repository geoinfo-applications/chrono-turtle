----------------------------------------------------------------------------------------------------
-- Table Registry: Maps backing tables to views
----------------------------------------------------------------------------------------------------

CREATE TABLE _vie.table_registry
(
    table_id           SERIAL PRIMARY KEY,
    backing_table_name TEXT UNIQUE NOT NULL, -- e.g., 'data__user'
    view_name          TEXT        NOT NULL, -- e.g., 'user'
    view_schema        TEXT        NOT NULL, -- e.g., 'data' or 'public'
    created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    UNIQUE (view_schema, view_name)
);

CREATE INDEX idx_table_registry_view ON _vie.table_registry (view_schema, view_name);

COMMENT ON TABLE _vie.table_registry IS 'Registry mapping backing tables to their views';
COMMENT ON COLUMN _vie.table_registry.backing_table_name IS 'Name in _backing schema';
COMMENT ON COLUMN _vie.table_registry.view_name IS 'Original table name exposed as view';
COMMENT ON COLUMN _vie.table_registry.view_schema IS 'Schema where the view is created';
