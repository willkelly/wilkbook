CREATE TABLE metadata (
    key TEXT PRIMARY KEY NOT NULL,
    integer_value INTEGER NOT NULL
) STRICT;

CREATE TABLE book_instances (
    namespace_id INTEGER PRIMARY KEY,
    book_revision TEXT NOT NULL,
    instance_id TEXT NOT NULL,
    storage_schema_version INTEGER NOT NULL CHECK (storage_schema_version = 1),
    state_version INTEGER NOT NULL DEFAULT 0
        CHECK (state_version >= 0 AND state_version <= 64),
    has_value INTEGER NOT NULL DEFAULT 0 CHECK (has_value IN (0, 1)),
    text TEXT,
    UNIQUE (book_revision, instance_id),
    CHECK (length(CAST(book_revision AS BLOB)) BETWEEN 1 AND 256),
    CHECK (length(CAST(instance_id AS BLOB)) BETWEEN 1 AND 256),
    CHECK (text IS NULL OR length(CAST(text AS BLOB)) <= 4096),
    CHECK (
        (has_value = 0 AND state_version = 0 AND text IS NULL)
        OR
        (has_value = 1 AND state_version >= 1 AND text IS NOT NULL)
    )
) STRICT;

CREATE TABLE commit_receipts (
    namespace_id INTEGER NOT NULL,
    operation_id TEXT NOT NULL,
    expected_state_version INTEGER NOT NULL
        CHECK (expected_state_version >= 0 AND expected_state_version < 64),
    text TEXT NOT NULL,
    text_bytes INTEGER NOT NULL CHECK (text_bytes >= 0 AND text_bytes <= 4096),
    resulting_state_version INTEGER NOT NULL
        CHECK (resulting_state_version >= 1 AND resulting_state_version <= 64),
    PRIMARY KEY (namespace_id, operation_id),
    FOREIGN KEY (namespace_id) REFERENCES book_instances(namespace_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,
    CHECK (length(CAST(operation_id AS BLOB)) BETWEEN 1 AND 128),
    CHECK (operation_id NOT GLOB '*[^A-Za-z0-9_-]*'),
    CHECK (text_bytes = length(CAST(text AS BLOB))),
    CHECK (resulting_state_version = expected_state_version + 1)
) STRICT;

INSERT INTO metadata (key, integer_value)
VALUES ('storage_schema_version', 1);

PRAGMA user_version = 1;
