CREATE TABLE device_config (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    printer_kind TEXT NOT NULL DEFAULT 'spooler' CHECK (printer_kind IN ('spooler','file','tcp')),
    printer_name TEXT NOT NULL DEFAULT '' CHECK (length(CAST(printer_name AS BLOB)) <= 255),
    file_path TEXT NOT NULL DEFAULT '' CHECK (length(CAST(file_path AS BLOB)) <= 512),
    tcp_host TEXT NOT NULL DEFAULT '' CHECK (length(CAST(tcp_host AS BLOB)) <= 255),
    tcp_port INTEGER NOT NULL DEFAULT 9100 CHECK (tcp_port BETWEEN 1 AND 65535),
    paper_width INTEGER NOT NULL DEFAULT 80 CHECK (paper_width IN (58,80)),
    logo BLOB NOT NULL DEFAULT x'' CHECK (length(logo) <= 262144),
    header TEXT NOT NULL DEFAULT '' CHECK (length(CAST(header AS BLOB)) <= 512),
    footer TEXT NOT NULL DEFAULT '' CHECK (length(CAST(footer AS BLOB)) <= 512),
    qr_payload TEXT NOT NULL DEFAULT '' CHECK (length(CAST(qr_payload AS BLOB)) <= 512),
    copies INTEGER NOT NULL DEFAULT 1 CHECK (copies BETWEEN 1 AND 5),
    feed_lines INTEGER NOT NULL DEFAULT 3 CHECK (feed_lines BETWEEN 0 AND 20),
    show_sku INTEGER NOT NULL DEFAULT 0 CHECK (show_sku IN (0,1)),
    show_barcode INTEGER NOT NULL DEFAULT 0 CHECK (show_barcode IN (0,1)),
    show_qr INTEGER NOT NULL DEFAULT 0 CHECK (show_qr IN (0,1)),
    cash_drawer INTEGER NOT NULL DEFAULT 1 CHECK (cash_drawer IN (0,1)),
    cut_paper INTEGER NOT NULL DEFAULT 1 CHECK (cut_paper IN (0,1)),
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
) STRICT;

CREATE TABLE audit_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT CHECK (id BETWEEN 1 AND 9000000000000000),
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')) CHECK (substr(created_at,-1)='Z'),
    kind TEXT NOT NULL CHECK (kind IN ('drawer_open','reprint','price_change','data_delete')),
    actor TEXT NOT NULL DEFAULT '' CHECK (length(CAST(actor AS BLOB)) <= 64),
    entity_type TEXT NOT NULL DEFAULT '' CHECK (length(CAST(entity_type AS BLOB)) <= 32),
    entity_id TEXT NOT NULL DEFAULT '' CHECK (length(CAST(entity_id AS BLOB)) <= 80),
    detail TEXT NOT NULL DEFAULT '' CHECK (length(CAST(detail AS BLOB)) <= 512)
) STRICT;
CREATE INDEX audit_log_created ON audit_log(created_at, id);
CREATE INDEX audit_log_kind ON audit_log(kind, created_at);

INSERT INTO schema_migration(version) VALUES(3);
PRAGMA user_version=3;
