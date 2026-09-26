CREATE TABLE revisions (
    revision_id TEXT PRIMARY KEY NOT NULL
        CHECK (length(CAST(revision_id AS BLOB)) = 64
               AND instr(revision_id, char(0)) = 0
               AND revision_id NOT GLOB '*[^0-9a-f]*'),
    source TEXT NOT NULL
        CHECK (length(CAST(source AS BLOB)) <= 8192 AND instr(source, char(0)) = 0)
) STRICT;

CREATE TABLE metadata (
    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
    storage_schema_version INTEGER NOT NULL CHECK (storage_schema_version = 1),
    source_format TEXT NOT NULL CHECK (source_format = 'guile-source-v1'),
    environment TEXT NOT NULL
        CHECK (length(CAST(environment AS BLOB)) BETWEEN 1 AND 128
               AND instr(environment, char(0)) = 0
               AND environment NOT GLOB '*[^A-Za-z0-9._+-]*'),
    seed_revision TEXT NOT NULL REFERENCES revisions(revision_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT
) STRICT;

CREATE TABLE workspace (
    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
    workspace_version INTEGER NOT NULL
        CHECK (workspace_version BETWEEN 0 AND 2147483647),
    source TEXT NOT NULL
        CHECK (length(CAST(source AS BLOB)) <= 8192 AND instr(source, char(0)) = 0),
    source_digest TEXT NOT NULL
        CHECK (length(CAST(source_digest AS BLOB)) = 64
               AND instr(source_digest, char(0)) = 0
               AND source_digest NOT GLOB '*[^0-9a-f]*'),
    active_revision TEXT NOT NULL REFERENCES revisions(revision_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,
    previous_revision TEXT REFERENCES revisions(revision_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,
    activation_generation INTEGER NOT NULL
        CHECK (activation_generation BETWEEN 0 AND 2147483647),
    CHECK (previous_revision IS NULL OR previous_revision <> active_revision)
) STRICT;

CREATE TRIGGER revisions_quota BEFORE INSERT ON revisions
WHEN (SELECT count(*) FROM revisions) >= 128
BEGIN
    SELECT RAISE(ABORT, 'revision quota exhausted');
END;

CREATE TRIGGER revisions_no_update BEFORE UPDATE ON revisions
BEGIN
    SELECT RAISE(ABORT, 'immutable revision');
END;

CREATE TRIGGER revisions_no_delete BEFORE DELETE ON revisions
BEGIN
    SELECT RAISE(ABORT, 'revisions are retained');
END;

CREATE TRIGGER metadata_no_update BEFORE UPDATE ON metadata
BEGIN
    SELECT RAISE(ABORT, 'immutable workspace identity');
END;

CREATE TRIGGER metadata_no_delete BEFORE DELETE ON metadata
BEGIN
    SELECT RAISE(ABORT, 'workspace identity is retained');
END;

CREATE TRIGGER workspace_no_delete BEFORE DELETE ON workspace
BEGIN
    SELECT RAISE(ABORT, 'workspace is retained');
END;

-- Exactly one of draft save and activation changes per transition.  Activation
-- includes rollback and same-revision activation; every accepted activation
-- advances the generation so an A -> B -> A sequence cannot reuse a stale CAS.
CREATE TRIGGER workspace_transition BEFORE UPDATE ON workspace
WHEN NEW.singleton <> OLD.singleton OR NOT (
    (NEW.workspace_version = OLD.workspace_version + 1
     AND NEW.activation_generation = OLD.activation_generation
     AND NEW.active_revision = OLD.active_revision
     AND NEW.previous_revision IS OLD.previous_revision)
    OR
    (NEW.workspace_version = OLD.workspace_version
     AND NEW.source = OLD.source AND NEW.source_digest = OLD.source_digest
     AND NEW.activation_generation = OLD.activation_generation + 1
     AND NEW.previous_revision IS CASE
         WHEN NEW.active_revision = OLD.active_revision THEN OLD.previous_revision
         ELSE OLD.active_revision END)
)
BEGIN
    SELECT RAISE(ABORT, 'invalid workspace transition');
END;

PRAGMA application_id = 1463965489;
PRAGMA user_version = 1;
