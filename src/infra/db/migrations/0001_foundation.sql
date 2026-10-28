CREATE TABLE schema_migration (
    version INTEGER PRIMARY KEY CHECK (version > 0),
    applied_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
) STRICT;

CREATE TABLE business (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    name TEXT NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 120),
    mode TEXT NOT NULL CHECK (mode IN ('retail', 'food', 'service')),
    address TEXT NOT NULL DEFAULT '' CHECK (length(address) <= 512),
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
) STRICT;

INSERT INTO schema_migration (version) VALUES (1);
PRAGMA user_version = 1;
