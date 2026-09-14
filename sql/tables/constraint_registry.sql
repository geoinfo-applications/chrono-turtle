----------------------------------------------------------------------------------------------------
-- Constraint Registry: Stores unique and primary key constraints for versioned tables
----------------------------------------------------------------------------------------------------

CREATE TYPE _vie.constraint_type AS ENUM ('PRIMARY KEY', 'UNIQUE');

CREATE TABLE _vie.constraint_registry (
    constraint_id SERIAL PRIMARY KEY,
    backing_table_name TEXT NOT NULL,
    constraint_name TEXT NOT NULL,
    constraint_type _vie.constraint_type NOT NULL,
    constraint_columns TEXT[] NOT NULL,

    UNIQUE(backing_table_name, constraint_name)
);

CREATE INDEX idx_constraint_registry_table ON _vie.constraint_registry(backing_table_name);
CREATE UNIQUE INDEX unique_pk_per_table
    ON _vie.constraint_registry (backing_table_name)
    WHERE constraint_type = 'PRIMARY KEY';

COMMENT ON TABLE _vie.constraint_registry IS 'Registry of unique and primary key constraints for versioned tables';
COMMENT ON COLUMN _vie.constraint_registry.backing_table_name IS 'Name of the backing table';
COMMENT ON COLUMN _vie.constraint_registry.constraint_name IS 'Original constraint name';
COMMENT ON COLUMN _vie.constraint_registry.constraint_type IS 'Type of constraint: PRIMARY KEY or UNIQUE';
COMMENT ON COLUMN _vie.constraint_registry.constraint_columns IS 'Array of column names in the constraint';
