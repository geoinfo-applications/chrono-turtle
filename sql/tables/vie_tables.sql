----------------------------------------------------------------------------------------------------
-- SCHEMA: _vie (Version control metadata tables - Git-like with BYTEA hashes)
----------------------------------------------------------------------------------------------------

-- Branch registry: named pointers to commit heads
CREATE TABLE _vie.branch
(
    name             TEXT PRIMARY KEY,
    head_commit_hash BYTEA       NOT NULL, -- SHA-256 hash (32 bytes)
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE _vie.branch IS 'Branch pointers to commits';
COMMENT ON COLUMN _vie.branch.name IS 'Branch name (e.g., main, feature/xyz)';
COMMENT ON COLUMN _vie.branch.head_commit_hash IS 'SHA-256 hash of current commit head';

-- Commit objects: immutable snapshots with lineage
CREATE TABLE _vie.commit
(
    hash        BYTEA PRIMARY KEY, -- SHA-256 hash (32 bytes)
    parent_hash BYTEA,             -- NULL for initial commit
    author      TEXT        NOT NULL,
    message     TEXT        NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    FOREIGN KEY (parent_hash) REFERENCES _vie.commit (hash)
);

COMMENT ON TABLE _vie.commit IS 'Immutable commit objects with lineage';
COMMENT ON COLUMN _vie.commit.hash IS 'SHA-256 hash of the commit';
COMMENT ON COLUMN _vie.commit.parent_hash IS 'Reference to parent commit (NULL for initial)';
COMMENT ON COLUMN _vie.commit.author IS 'Commit author';
COMMENT ON COLUMN _vie.commit.message IS 'Commit message';

-- Tree objects: content-addressable row versions
CREATE TABLE _vie.tree
(
    hash         BYTEA PRIMARY KEY GENERATED ALWAYS AS (
        sha256((table_schema || '|' || table_name || '|' || original_pks)::bytea || '|'::bytea || COALESCE(row_hash, 'tombstone'::bytea))
        ) STORED,
    table_schema TEXT  NOT NULL,
    table_name   TEXT  NOT NULL,
    original_pks JSONB NOT NULL,
    row_hash     BYTEA, -- Hash of actual row content + FK hashes (NULL = tombstone/delete)

    UNIQUE (table_schema, table_name, original_pks, row_hash)
);

COMMENT ON TABLE _vie.tree IS 'Content-addressable tree objects for row versions';
COMMENT ON COLUMN _vie.tree.hash IS 'Generated SHA-256 hash of tree identity';
COMMENT ON COLUMN _vie.tree.table_schema IS 'Schema of the versioned table';
COMMENT ON COLUMN _vie.tree.table_name IS 'Name of the versioned table';
COMMENT ON COLUMN _vie.tree.original_pks IS 'Original primary keys';
COMMENT ON COLUMN _vie.tree.row_hash IS 'Hash of row content (NULL for deletions/tombstones)';

-- Many-to-many: commits contain multiple tree entries
CREATE TABLE _vie.commit_tree
(
    commit_hash BYTEA NOT NULL,
    tree_hash   BYTEA NOT NULL,

    PRIMARY KEY (commit_hash, tree_hash),
    FOREIGN KEY (commit_hash) REFERENCES _vie.commit (hash),
    FOREIGN KEY (tree_hash) REFERENCES _vie.tree (hash)
);

COMMENT ON TABLE _vie.commit_tree IS 'Many-to-many relationship between commits and trees';

-- Indexes for performance
CREATE INDEX idx_branch_head ON _vie.branch (head_commit_hash);
CREATE INDEX idx_commit_parent ON _vie.commit (parent_hash);
CREATE INDEX idx_commit_tree_commit ON _vie.commit_tree (commit_hash);
CREATE INDEX idx_commit_tree_tree ON _vie.commit_tree (tree_hash);
CREATE INDEX idx_tree_table_pk ON _vie.tree (table_schema, table_name, original_pks);
CREATE INDEX idx_tree_row_hash ON _vie.tree (row_hash);

-- Enums
CREATE TYPE _vie.column_default_info AS
(
    column_name    text,
    column_default text
);
