CREATE TABLE shift (
    id INTEGER PRIMARY KEY AUTOINCREMENT CHECK (id BETWEEN 1 AND 9000000000000000),
    opened_at TEXT NOT NULL CHECK (substr(opened_at,-1)='Z'),
    closed_at TEXT CHECK (closed_at IS NULL OR (substr(closed_at,-1)='Z' AND closed_at>=opened_at)),
    opening_cash INTEGER NOT NULL CHECK (opening_cash BETWEEN 0 AND 9000000000000000),
    expected_cash INTEGER CHECK (expected_cash BETWEEN 0 AND 9000000000000000),
    counted_cash INTEGER CHECK (counted_cash BETWEEN 0 AND 9000000000000000),
    close_note TEXT NOT NULL DEFAULT '' CHECK (length(CAST(close_note AS BLOB)) <= 160),
    CHECK ((closed_at IS NULL)=(expected_cash IS NULL) AND (closed_at IS NULL)=(counted_cash IS NULL)),
    CHECK (closed_at IS NOT NULL OR close_note='')
) STRICT;
-- NULLs are distinct in unique indexes, so the expression keeps a single open shift.
CREATE UNIQUE INDEX shift_single_open ON shift((closed_at IS NULL)) WHERE closed_at IS NULL;

CREATE TABLE cash_entry (
    id INTEGER PRIMARY KEY AUTOINCREMENT CHECK (id BETWEEN 1 AND 9000000000000000),
    entry_key TEXT NOT NULL UNIQUE CHECK (length(entry_key) BETWEEN 1 AND 80 AND entry_key NOT GLOB '*[^A-Za-z0-9_-]*'),
    shift_id INTEGER NOT NULL REFERENCES shift(id),
    created_at TEXT NOT NULL CHECK (substr(created_at,-1)='Z'),
    kind TEXT NOT NULL CHECK (kind IN ('in','out')),
    amount INTEGER NOT NULL CHECK (amount BETWEEN 1 AND 9000000000000000),
    category TEXT NOT NULL CHECK (length(CAST(category AS BLOB)) BETWEEN 1 AND 64 AND length(trim(category)) > 0),
    note TEXT NOT NULL CHECK (length(CAST(note AS BLOB)) <= 160)
) STRICT;
CREATE INDEX cash_entry_shift ON cash_entry(shift_id, id);

ALTER TABLE sale ADD COLUMN shift_id INTEGER REFERENCES shift(id);
CREATE INDEX sale_shift ON sale(shift_id) WHERE shift_id IS NOT NULL;

INSERT INTO schema_migration(version) VALUES(4);
PRAGMA user_version=4;
