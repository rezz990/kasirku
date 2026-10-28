CREATE TABLE product (
    id INTEGER PRIMARY KEY AUTOINCREMENT CHECK (id BETWEEN 1 AND 9000000000000000),
    revision INTEGER NOT NULL DEFAULT 1 CHECK (revision BETWEEN 1 AND 9000000000000000),
    name TEXT NOT NULL CHECK (length(CAST(name AS BLOB)) BETWEEN 1 AND 120 AND length(trim(name)) > 0),
    sku TEXT NOT NULL CHECK (length(CAST(sku AS BLOB)) <= 64),
    barcode TEXT NOT NULL CHECK (length(CAST(barcode AS BLOB)) <= 64),
    category TEXT NOT NULL CHECK (length(CAST(category AS BLOB)) <= 64),
    unit TEXT NOT NULL CHECK (length(CAST(unit AS BLOB)) BETWEEN 1 AND 16 AND length(trim(unit)) > 0),
    price INTEGER NOT NULL CHECK (price BETWEEN 0 AND 9000000000000000),
    cost INTEGER NOT NULL CHECK (cost BETWEEN 0 AND 9000000000000000),
    stock_milli INTEGER CHECK (stock_milli BETWEEN 0 AND 9000000000000000),
    active INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0,1))
) STRICT;
CREATE UNIQUE INDEX product_active_sku ON product(sku) WHERE active=1 AND sku<>'';
CREATE UNIQUE INDEX product_active_barcode ON product(barcode) WHERE active=1 AND barcode<>'';
CREATE INDEX product_active_name ON product(active, name COLLATE NOCASE, id);

CREATE TABLE sale_sequence (
    sale_date TEXT PRIMARY KEY NOT NULL CHECK (length(sale_date)=10),
    sequence INTEGER NOT NULL CHECK (sequence BETWEEN 1 AND 9000000000000000)
) STRICT;

CREATE TABLE sale (
    id INTEGER PRIMARY KEY AUTOINCREMENT CHECK (id BETWEEN 1 AND 9000000000000000),
    checkout_id TEXT NOT NULL UNIQUE CHECK (length(checkout_id) BETWEEN 1 AND 80 AND checkout_id NOT GLOB '*[^A-Za-z0-9_-]*'),
    input_hash TEXT NOT NULL CHECK (length(input_hash)=64),
    number TEXT NOT NULL UNIQUE,
    created_at TEXT NOT NULL CHECK (substr(created_at,-1)='Z'),
    sale_date TEXT NOT NULL CHECK (length(sale_date)=10),
    business_name TEXT NOT NULL,
    business_address TEXT NOT NULL,
    discount_kind TEXT NOT NULL CHECK (discount_kind IN ('none','nominal','percent')),
    discount_value INTEGER NOT NULL CHECK (discount_value BETWEEN 0 AND 9000000000000000 AND (discount_kind<>'none' OR discount_value=0) AND (discount_kind<>'percent' OR discount_value<=10000)),
    cash_rounding_increment INTEGER NOT NULL CHECK (cash_rounding_increment IN (1,50,100)),
    gross INTEGER NOT NULL CHECK (gross BETWEEN 0 AND 9000000000000000),
    line_discount INTEGER NOT NULL CHECK (line_discount BETWEEN 0 AND gross),
    subtotal INTEGER NOT NULL CHECK (subtotal=gross-line_discount),
    transaction_discount INTEGER NOT NULL CHECK (transaction_discount BETWEEN 0 AND subtotal),
    net_subtotal INTEGER NOT NULL CHECK (net_subtotal=subtotal-transaction_discount),
    service_charge INTEGER NOT NULL CHECK (service_charge BETWEEN 0 AND 9000000000000000),
    tax_base INTEGER NOT NULL CHECK (tax_base BETWEEN 0 AND 9000000000000000),
    tax INTEGER NOT NULL CHECK (tax BETWEEN 0 AND 9000000000000000),
    total_before_rounding INTEGER NOT NULL CHECK (total_before_rounding BETWEEN 0 AND 9000000000000000 AND total_before_rounding=tax_base+tax),
    rounding_adjustment INTEGER NOT NULL CHECK (rounding_adjustment BETWEEN -50 AND 50),
    total INTEGER NOT NULL CHECK (total BETWEEN 0 AND 9000000000000000 AND total=total_before_rounding+rounding_adjustment),
    tendered INTEGER NOT NULL CHECK (tendered BETWEEN total AND 9000000000000000),
    change INTEGER NOT NULL CHECK (change=tendered-total)
) STRICT;
CREATE INDEX sale_date_newest ON sale(sale_date, id DESC);

CREATE TABLE sale_item (
    sale_id INTEGER NOT NULL REFERENCES sale(id),
    position INTEGER NOT NULL CHECK (position BETWEEN 0 AND 39),
    product_id INTEGER NOT NULL REFERENCES product(id),
    revision INTEGER NOT NULL CHECK (revision BETWEEN 1 AND 9000000000000000),
    name TEXT NOT NULL,
    sku TEXT NOT NULL,
    barcode TEXT NOT NULL,
    category TEXT NOT NULL,
    unit TEXT NOT NULL,
    unit_price INTEGER NOT NULL CHECK (unit_price BETWEEN 0 AND 9000000000000000),
    unit_cost INTEGER NOT NULL CHECK (unit_cost BETWEEN 0 AND 9000000000000000),
    quantity_milli INTEGER NOT NULL CHECK (quantity_milli BETWEEN 1 AND 9000000000000000),
    discount_kind TEXT NOT NULL CHECK (discount_kind IN ('none','nominal','percent')),
    discount_value INTEGER NOT NULL CHECK (discount_value BETWEEN 0 AND 9000000000000000 AND (discount_kind<>'none' OR discount_value=0) AND (discount_kind<>'percent' OR discount_value<=10000)),
    note TEXT NOT NULL CHECK (length(CAST(note AS BLOB))<=160),
    gross INTEGER NOT NULL CHECK (gross BETWEEN 0 AND 9000000000000000),
    discount INTEGER NOT NULL CHECK (discount BETWEEN 0 AND gross),
    net INTEGER NOT NULL CHECK (net=gross-discount),
    PRIMARY KEY(sale_id,position),
    UNIQUE(sale_id,product_id)
) STRICT;
CREATE INDEX sale_item_product ON sale_item(product_id);

CREATE TABLE payment (
    sale_id INTEGER PRIMARY KEY REFERENCES sale(id),
    method TEXT NOT NULL CHECK (method='cash'),
    amount INTEGER NOT NULL CHECK (amount BETWEEN 0 AND 9000000000000000),
    tendered INTEGER NOT NULL CHECK (tendered BETWEEN amount AND 9000000000000000),
    change INTEGER NOT NULL CHECK (change=tendered-amount)
) STRICT;

CREATE TABLE stock_movement (
    id INTEGER PRIMARY KEY AUTOINCREMENT CHECK (id BETWEEN 1 AND 9000000000000000),
    product_id INTEGER NOT NULL REFERENCES product(id),
    sale_id INTEGER REFERENCES sale(id),
    kind TEXT NOT NULL CHECK (kind IN ('initial','adjustment','sale')),
    quantity_milli INTEGER NOT NULL CHECK (quantity_milli BETWEEN -9000000000000000 AND 9000000000000000),
    before_milli INTEGER CHECK (before_milli BETWEEN 0 AND 9000000000000000),
    after_milli INTEGER CHECK (after_milli BETWEEN 0 AND 9000000000000000),
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    CHECK (quantity_milli=coalesce(after_milli,0)-coalesce(before_milli,0)),
    CHECK ((kind='sale' AND sale_id IS NOT NULL AND before_milli IS NOT NULL AND after_milli IS NOT NULL AND quantity_milli<0) OR (kind<>'sale' AND sale_id IS NULL)),
    CHECK (kind<>'initial' OR (before_milli IS NULL AND after_milli IS NOT NULL))
) STRICT;
CREATE INDEX stock_movement_product ON stock_movement(product_id,id);
CREATE INDEX stock_movement_sale ON stock_movement(sale_id) WHERE sale_id IS NOT NULL;

INSERT INTO schema_migration(version) VALUES(2);
PRAGMA user_version=2;
