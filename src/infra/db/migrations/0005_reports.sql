ALTER TABLE product ADD COLUMN min_stock_milli INTEGER CHECK (min_stock_milli BETWEEN 0 AND 9000000000000000);
CREATE INDEX product_low_stock ON product(active, stock_milli) WHERE active=1 AND stock_milli IS NOT NULL AND min_stock_milli IS NOT NULL;
CREATE INDEX cash_entry_date ON cash_entry(created_at);

INSERT INTO schema_migration(version) VALUES(5);
PRAGMA user_version=5;
