const std = @import("std");
pub const schema_version = 2;
pub const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const Business = struct {
    name: []const u8,
    mode: []const u8,
    address: []const u8,
};

pub const Database = struct {
    handle: *c.sqlite3,

    pub fn open(path: [:0]const u8) !Database {
        var handle: ?*c.sqlite3 = null;
        const result = c.sqlite3_open_v2(path.ptr, &handle, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_FULLMUTEX, null);
        if (result != c.SQLITE_OK) {
            if (handle) |db| _ = c.sqlite3_close(db);
            return error.DatabaseOpenFailed;
        }
        const self = Database{ .handle = handle.? };
        errdefer self.close();
        if (c.sqlite3_busy_timeout(self.handle, 5000) != c.SQLITE_OK) return error.DatabaseSetupFailed;
        try self.exec("PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA trusted_schema=OFF;");
        if (!std.mem.eql(u8, path, ":memory:")) {
            const mode = try self.text(std.heap.page_allocator, "PRAGMA journal_mode;");
            defer std.heap.page_allocator.free(mode);
            if (!std.mem.eql(u8, mode, "wal")) return error.WalUnavailable;
        }
        if (try self.integer("PRAGMA synchronous;") != 2) return error.DurabilityUnavailable;
        return self;
    }

    pub fn close(self: Database) void {
        std.debug.assert(c.sqlite3_close(self.handle) == c.SQLITE_OK);
    }

    pub fn exec(self: Database, sql: [:0]const u8) !void {
        const result = c.sqlite3_exec(self.handle, sql.ptr, null, null, null);
        return check(result);
    }

    pub fn prepare(self: Database, sql: [:0]const u8) !Statement {
        var statement: ?*c.sqlite3_stmt = null;
        try check(c.sqlite3_prepare_v2(self.handle, sql.ptr, -1, &statement, null));
        return .{ .handle = statement orelse return error.EmptyStatement };
    }

    pub fn integer(self: Database, sql: [:0]const u8) !i64 {
        const statement = try self.prepare(sql);
        defer statement.close();
        if (!try statement.next()) return error.NoResult;
        return c.sqlite3_column_int64(statement.handle, 0);
    }

    pub fn text(self: Database, allocator: std.mem.Allocator, sql: [:0]const u8) ![]const u8 {
        const statement = try self.prepare(sql);
        defer statement.close();
        if (!try statement.next()) return error.NoResult;
        return allocator.dupe(u8, statement.columnText(0));
    }

    pub fn migrate(self: Database, allocator: std.mem.Allocator, path: [:0]const u8) !void {
        const version = try self.integer("PRAGMA user_version;");
        if (version > schema_version or version < 0) return error.UnsupportedSchemaVersion;
        if (version > 0) try self.validateHistory(version);
        if (version == schema_version) return;
        if (version == 1) {
            // The connection's actual filename, not a caller-supplied alias, owns the recovery copy.
            const filename = c.sqlite3_db_filename(self.handle, "main");
            if (filename != null and filename[0] != 0) {
                while (true) {
                    const suffix = std.crypto.random.int(u128);
                    const backup_path = try std.fmt.allocPrintSentinel(allocator, "{s}.pre-migration-v1.{x}.bak", .{ std.mem.span(filename), suffix }, 0);
                    defer allocator.free(backup_path);
                    self.backup(backup_path) catch |err| switch (err) {
                        error.PathAlreadyExists => continue,
                        else => return err,
                    };
                    break;
                }
            }
        }
        try self.exec("BEGIN IMMEDIATE;");
        errdefer self.exec("ROLLBACK;") catch {};
        const locked_version = try self.integer("PRAGMA user_version;");
        if (locked_version > schema_version or locked_version < 0) return error.UnsupportedSchemaVersion;
        if (locked_version > 0) try self.validateHistory(locked_version);
        if (locked_version == 0) {
            const tables = try self.integer("SELECT count(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';");
            if (tables != 0) {
                // SQLite backup cannot copy a source connection holding a write transaction.
                try self.exec("ROLLBACK;");
                const backup_path = try std.fmt.allocPrintSentinel(allocator, "{s}.pre-migration-v0.bak", .{path}, 0);
                defer allocator.free(backup_path);
                self.backup(backup_path) catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    else => return err,
                };
                return error.UnrecognizedDatabase;
            }
            try self.exec(@embedFile("migrations/0001_foundation.sql"));
        }
        if (locked_version < schema_version) try self.exec(@embedFile("migrations/0002_pos.sql"));
        try self.exec("COMMIT;");
    }

    fn validateHistory(self: Database, version: i64) !void {
        if (try self.integer("SELECT count(*) FROM sqlite_master WHERE type='table' AND name='schema_migration';") != 1) return error.InvalidMigrationHistory;
        const statement = self.prepare("SELECT count(*),min(version),max(version),count(DISTINCT version) FROM schema_migration;") catch |err| switch (err) {
            error.DatabaseFailure => return error.InvalidMigrationHistory,
            else => return err,
        };
        defer statement.close();
        if (!try statement.next() or statement.columnInt(0) != version or statement.columnInt(1) != 1 or statement.columnInt(2) != version or statement.columnInt(3) != version) return error.InvalidMigrationHistory;
    }

    pub fn business(self: Database, allocator: std.mem.Allocator) !?Business {
        const statement = try self.prepare("SELECT name, mode, address FROM business WHERE id=1;");
        defer statement.close();
        if (!try statement.next()) return null;
        const name = try allocator.dupe(u8, statement.columnText(0));
        errdefer allocator.free(name);
        const mode = try allocator.dupe(u8, statement.columnText(1));
        errdefer allocator.free(mode);
        const address = try allocator.dupe(u8, statement.columnText(2));
        return .{ .name = name, .mode = mode, .address = address };
    }

    pub fn saveBusiness(self: Database, business_value: Business) !void {
        try validateBusiness(business_value);
        try self.exec("BEGIN IMMEDIATE;");
        errdefer self.exec("ROLLBACK;") catch {};
        const statement = try self.prepare("INSERT INTO business(id,name,mode,address) VALUES(1,?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name,mode=excluded.mode,address=excluded.address;");
        defer statement.close();
        try statement.bindText(1, std.mem.trim(u8, business_value.name, " \t\r\n"));
        try statement.bindText(2, business_value.mode);
        try statement.bindText(3, business_value.address);
        if (try statement.next()) return error.UnexpectedResult;
        try self.exec("COMMIT;");
    }

    pub fn backup(self: Database, destination: [:0]const u8) !void {
        const file = try std.fs.cwd().createFile(destination, .{ .exclusive = true });
        file.close();
        errdefer std.fs.cwd().deleteFile(destination) catch {};
        var target: ?*c.sqlite3 = null;
        const opened = c.sqlite3_open_v2(destination.ptr, &target, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE, null);
        if (opened != c.SQLITE_OK) {
            if (target) |db| _ = c.sqlite3_close(db);
            return error.BackupOpenFailed;
        }
        defer _ = c.sqlite3_close(target.?);
        const copy = c.sqlite3_backup_init(target.?, "main", self.handle, "main") orelse return error.BackupFailed;
        const stepped = c.sqlite3_backup_step(copy, -1);
        const finished = c.sqlite3_backup_finish(copy);
        if (stepped != c.SQLITE_DONE or finished != c.SQLITE_OK) return error.BackupFailed;
    }
};

pub fn validateBusiness(value: Business) !void {
    const name = std.mem.trim(u8, value.name, " \t\r\n");
    if (name.len == 0 or name.len > 120 or value.address.len > 512) return error.InvalidBusiness;
    if (!std.unicode.utf8ValidateSlice(name) or !std.unicode.utf8ValidateSlice(value.address)) return error.InvalidBusiness;
    for (name) |byte| if (byte < 32 or byte == 127) return error.InvalidBusiness;
    for (value.address) |byte| if ((byte < 32 and byte != '\n' and byte != '\r' and byte != '\t') or byte == 127) return error.InvalidBusiness;
    if (!std.mem.eql(u8, value.mode, "retail") and !std.mem.eql(u8, value.mode, "food") and !std.mem.eql(u8, value.mode, "service")) return error.InvalidBusiness;
}

pub const Statement = struct {
    handle: *c.sqlite3_stmt,

    pub fn close(self: Statement) void {
        _ = c.sqlite3_finalize(self.handle);
    }

    pub fn bindText(self: Statement, index: c_int, value: []const u8) !void {
        if (value.len > std.math.maxInt(c_int)) return error.ValueTooLarge;
        const transient: c.sqlite3_destructor_type = @ptrFromInt(std.math.maxInt(usize));
        try check(c.sqlite3_bind_text(self.handle, index, value.ptr, @intCast(value.len), transient));
    }

    pub fn bindInt(self: Statement, index: c_int, value: i64) !void {
        try check(c.sqlite3_bind_int64(self.handle, index, value));
    }

    pub fn bindNull(self: Statement, index: c_int) !void {
        try check(c.sqlite3_bind_null(self.handle, index));
    }

    pub fn columnInt(self: Statement, index: c_int) i64 {
        return c.sqlite3_column_int64(self.handle, index);
    }

    pub fn isNull(self: Statement, index: c_int) bool {
        return c.sqlite3_column_type(self.handle, index) == c.SQLITE_NULL;
    }

    pub fn next(self: Statement) !bool {
        const result = c.sqlite3_step(self.handle);
        if (result == c.SQLITE_ROW) return true;
        if (result == c.SQLITE_DONE) return false;
        try check(result);
        unreachable;
    }

    pub fn columnText(self: Statement, index: c_int) []const u8 {
        const pointer = c.sqlite3_column_text(self.handle, index);
        const length: usize = @intCast(c.sqlite3_column_bytes(self.handle, index));
        return if (pointer == null) "" else pointer[0..length];
    }
};

fn check(result: c_int) !void {
    switch (result & 0xff) {
        c.SQLITE_OK => {},
        c.SQLITE_BUSY, c.SQLITE_LOCKED => return error.DatabaseBusy,
        c.SQLITE_CONSTRAINT => return error.ConstraintViolation,
        c.SQLITE_FULL => return error.DiskFull,
        c.SQLITE_CORRUPT, c.SQLITE_NOTADB => return error.DatabaseCorrupt,
        else => return error.DatabaseFailure,
    }
}

test "fresh and repeated migrations, business parameters and constraints" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const db = try Database.open(":memory:");
    defer db.close();
    try db.migrate(a, ":memory:");
    try db.migrate(a, ":memory:");
    try std.testing.expectEqual(@as(i64, schema_version), try db.integer("SELECT count(*) FROM schema_migration;"));
    try std.testing.expectEqual(@as(i64, schema_version), try db.integer("PRAGMA user_version;"));
    try std.testing.expect((try db.business(arena.allocator())) == null);
    try db.saveBusiness(.{ .name = "Toko ' Sari", .mode = "retail", .address = "Jalan Mawar" });
    const saved = (try db.business(arena.allocator())).?;
    try std.testing.expectEqualStrings("Toko ' Sari", saved.name);
    try std.testing.expectError(error.InvalidBusiness, db.saveBusiness(.{ .name = " ", .mode = "retail", .address = "" }));
    try std.testing.expectError(error.InvalidBusiness, db.saveBusiness(.{ .name = "Toko", .mode = "other", .address = "" }));
    try std.testing.expectError(error.ConstraintViolation, db.exec("INSERT INTO business(id,name,mode) VALUES(2,'Other','retail');"));
    try db.exec("PRAGMA user_version=99;");
    try std.testing.expectError(error.UnsupportedSchemaVersion, db.migrate(a, ":memory:"));
}

test "file database enforces WAL FULL, rollback, persistence and consistent backup" {
    const a = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const directory = try temp.dir.realpathAlloc(a, ".");
    defer a.free(directory);
    const path = try std.fmt.allocPrintSentinel(a, "{s}/test.db", .{directory}, 0);
    defer a.free(path);
    const destination = try std.fmt.allocPrintSentinel(a, "{s}/backup.db", .{directory}, 0);
    defer a.free(destination);
    {
        const db = try Database.open(path);
        defer db.close();
        try db.migrate(a, path);
        try std.testing.expectEqual(@as(i64, 2), try db.integer("PRAGMA synchronous;"));
        try std.testing.expectEqual(@as(i64, 1), try db.integer("PRAGMA foreign_keys;"));
        try db.saveBusiness(.{ .name = "KasirKu Test", .mode = "food", .address = "" });
        try db.exec("BEGIN IMMEDIATE; UPDATE business SET name='Uncommitted';");
        try db.exec("ROLLBACK;");
        try db.backup(destination);
        try db.exec("UPDATE business SET name='After backup';");
        try std.testing.expectError(error.PathAlreadyExists, db.backup(destination));
    }
    const reopened = try Database.open(path);
    defer reopened.close();
    const restored = try Database.open(destination);
    defer restored.close();
    const original_name = try reopened.text(a, "SELECT name FROM business;");
    defer a.free(original_name);
    try std.testing.expectEqualStrings("After backup", original_name);
    const backup_name = try restored.text(a, "SELECT name FROM business;");
    defer a.free(backup_name);
    try std.testing.expectEqualStrings("KasirKu Test", backup_name);
    const integrity = try restored.text(a, "PRAGMA integrity_check;");
    defer a.free(integrity);
    try std.testing.expectEqualStrings("ok", integrity);
}

test "rejected migrations preserve the first recovery snapshot" {
    const a = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const directory = try temp.dir.realpathAlloc(a, ".");
    defer a.free(directory);
    const path = try std.fmt.allocPrintSentinel(a, "{s}/unknown.db", .{directory}, 0);
    defer a.free(path);
    const backup_path = try std.fmt.allocPrintSentinel(a, "{s}.pre-migration-v0.bak", .{path}, 0);
    defer a.free(backup_path);
    const db = try Database.open(path);
    defer db.close();
    try db.exec("CREATE TABLE original(value TEXT); INSERT INTO original VALUES('first');");
    try std.testing.expectError(error.UnrecognizedDatabase, db.migrate(a, path));
    try db.exec("UPDATE original SET value='second';");
    try std.testing.expectError(error.UnrecognizedDatabase, db.migrate(a, path));
    const snapshot = try Database.open(backup_path);
    defer snapshot.close();
    const value = try snapshot.text(a, "SELECT value FROM original;");
    defer a.free(value);
    try std.testing.expectEqualStrings("first", value);
    try std.testing.expectEqual(@as(i64, 0), try db.integer("PRAGMA user_version;"));
}

test "constraint failure can roll back all prior transaction writes" {
    const db = try Database.open(":memory:");
    defer db.close();
    try db.migrate(std.testing.allocator, ":memory:");
    try db.exec("BEGIN; INSERT INTO business(id,name,mode) VALUES(1,'Partial','retail');");
    try std.testing.expectError(error.ConstraintViolation, db.exec("UPDATE business SET mode='invalid';"));
    try db.exec("ROLLBACK;");
    try std.testing.expectEqual(@as(i64, 0), try db.integer("SELECT count(*) FROM business;"));
}

test "v1 upgrade backs up the actual file and preserves the business" {
    const a = std.testing.allocator;
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    const directory = try temp.dir.realpathAlloc(a, ".");
    defer a.free(directory);
    const path = try std.fmt.allocPrintSentinel(a, "{s}/previous.db", .{directory}, 0);
    defer a.free(path);
    const db = try Database.open(path);
    defer db.close();
    try db.exec(@embedFile("migrations/0001_foundation.sql"));
    try db.saveBusiness(.{ .name = "Before upgrade", .mode = "retail", .address = "Preserved address" });
    try db.migrate(a, ":memory:");
    try std.testing.expectEqual(@as(i64, 2), try db.integer("PRAGMA user_version;"));
    try db.saveBusiness(.{ .name = "After upgrade", .mode = "food", .address = "New address" });
    try db.migrate(a, path);
    var count: usize = 0;
    var iterator = temp.dir.iterate();
    while (try iterator.next()) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "previous.db.pre-migration-v1.") or !std.mem.endsWith(u8, entry.name, ".bak")) continue;
        count += 1;
        const snapshot_path = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ directory, entry.name }, 0);
        defer a.free(snapshot_path);
        const snapshot = try Database.open(snapshot_path);
        defer snapshot.close();
        try std.testing.expectEqual(@as(i64, 1), try snapshot.integer("PRAGMA user_version;"));
        const name = try snapshot.text(a, "SELECT name FROM business;");
        defer a.free(name);
        try std.testing.expectEqualStrings("Before upgrade", name);
        const address = try snapshot.text(a, "SELECT address FROM business;");
        defer a.free(address);
        try std.testing.expectEqualStrings("Preserved address", address);
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "failed v1 upgrades roll back schema and keep distinct recovery copies" {
    const a = std.testing.allocator;
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    const directory = try temp.dir.realpathAlloc(a, ".");
    defer a.free(directory);
    const path = try std.fmt.allocPrintSentinel(a, "{s}/conflicting.db", .{directory}, 0);
    defer a.free(path);
    const db = try Database.open(path);
    defer db.close();
    try db.exec(@embedFile("migrations/0001_foundation.sql"));
    try db.saveBusiness(.{ .name = "First recovery", .mode = "service", .address = "" });
    try db.exec("CREATE TABLE product(existing TEXT);");
    try std.testing.expectError(error.DatabaseFailure, db.migrate(a, path));
    try db.saveBusiness(.{ .name = "Second recovery", .mode = "service", .address = "" });
    try std.testing.expectError(error.DatabaseFailure, db.migrate(a, path));
    try std.testing.expectEqual(@as(i64, 1), try db.integer("PRAGMA user_version;"));
    try std.testing.expectEqual(@as(i64, 1), try db.integer("SELECT count(*) FROM schema_migration;"));
    try std.testing.expectEqual(@as(i64, 0), try db.integer("SELECT count(*) FROM sqlite_master WHERE name='sale';"));
    var first: usize = 0;
    var second: usize = 0;
    var iterator = temp.dir.iterate();
    while (try iterator.next()) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".bak")) continue;
        const snapshot_path = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ directory, entry.name }, 0);
        defer a.free(snapshot_path);
        const snapshot = try Database.open(snapshot_path);
        defer snapshot.close();
        const name = try snapshot.text(a, "SELECT name FROM business;");
        defer a.free(name);
        if (std.mem.eql(u8, name, "First recovery")) first += 1;
        if (std.mem.eql(u8, name, "Second recovery")) second += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), first);
    try std.testing.expectEqual(@as(usize, 1), second);
}

test "migration history cannot be missing or inconsistent" {
    const a = std.testing.allocator;
    const missing = try Database.open(":memory:");
    defer missing.close();
    try missing.exec("PRAGMA user_version=1;");
    try std.testing.expectError(error.InvalidMigrationHistory, missing.migrate(a, ":memory:"));
    const db = try Database.open(":memory:");
    defer db.close();
    try db.migrate(a, ":memory:");
    try db.exec("DELETE FROM schema_migration WHERE version=1;");
    try std.testing.expectError(error.InvalidMigrationHistory, db.migrate(a, ":memory:"));
}
