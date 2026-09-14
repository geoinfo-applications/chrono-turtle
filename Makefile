EXTENSION = chronoturtle
DATA = sql/chronoturtle--0.1.0.sql
REGRESS = 00_init 01_api_functions 02_vie_migration_and_dml 03_rows_across_tables 04_reserved_names
REGRESS_OPTS = --inputdir=test --outputdir=test

# Source files that get concatenated into the main SQL file
SQL_SOURCES = \
	sql/schemas.sql \
	sql/tables/vie_tables.sql \
	sql/tables/table_registry.sql \
	sql/tables/constraint_registry.sql \
	sql/functions/_chronoturtle_internal.sql \
	sql/functions/_vie_constraint.sql \
	sql/functions/_vie_core.sql \
	sql/functions/_vie_migration.sql \
	sql/functions/_vie_trigger.sql \
	sql/functions/chronoturtle.sql \
	sql/init.sql

PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

# Build the main SQL file by concatenating all sources
$(DATA): $(SQL_SOURCES)
	cat $(SQL_SOURCES) > $(DATA)

# Add data to all target to ensure it's built
all: $(DATA)
