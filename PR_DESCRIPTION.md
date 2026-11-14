# Pull Request: fix(storage,sql,vfs): harden storage engine, SQL parser/executor, and VFS; deduplicate helpers

## Summary

Hardens **EuropaDB** across the B+Tree storage engine, WAL indexer, SQL parser/executor, VFS drivers, and PostgreSQL wire protocol gateway while removing duplicated helper code and preserving 100% backward compatibility (`require("luadb")` / `require("europadb")`, legacy `.db` format, and CLI/server entrypoints).

---

## Key Changes

### 1. Storage Engine & B+Tree Integrity (`src/europadb/storage/`)
- **Split-Page Allocation Safety (`executor.lua`)**: Advances `next_page_id` past all physical pages on disk and in `wal_index` during `_load_catalog()` so child pages allocated during B+Tree splits are never overwritten after database reopen.
- **Interior B+Tree Node Splits (`page.lua`, `btree.lua`)**: Added `page_mgr.write_interior_if_fits()` so interior splits trigger cleanly past ~23k rows instead of raising a payload overflow error, and preserved `next_page_id` sibling links during leaf splits.
- **Committed-Only WAL Indexing (`wal.lua`)**: `WAL:sync_wal_index()` buffers frames per transaction and only publishes page offsets once `commit_flag == 1`.
- **Exact 64-Bit Integer Serialization (`serializer.lua`)**: Added tag `\x06` (`>i8`) to preserve Lua 5.3+ `integer` vs `float` subtypes while retaining backward-compatible decoding for legacy `.db` files.
- **Transactional `REINDEX` (`executor.lua`)**: Removed `self.wal:recover()` from `executor:reindex()` so uncommitted pages inside an active transaction are preserved.

### 2. SQL Parser & Executor Correctness (`src/europadb/sql/`)
- **Boolean Precedence & Signed Numbers (`parser.lua`)**: Refactored `parse_expression` into `parse_or` -> `parse_and` -> `parse_primary` so `AND` binds tighter than `OR`, and added unary `-` support in `WHERE` and `UPDATE SET`.
- **`JOIN ... ON` Execution (`parser.lua`, `executor.lua`)**: Wired `INNER JOIN` and `LEFT JOIN` AST nodes into the executor with qualified (`table.col` / alias) column resolution.
- **CTE Pipeline Integration (`executor.lua`)**: Routed `WITH ... AS (...)` transient rows through the full `SELECT` pipeline (`WHERE`, `GROUP BY`, `ORDER BY`, projections, `LIMIT`/`OFFSET`) and removed duplicate CTE return blocks.
- **Safe `LIKE` Pattern Matching (`executor.lua`)**: Escapes Lua regex metacharacters (`(`, `)`, `.`, `+`, `-`, `*`, `?`, `[`, `]`, `^`, `$`) in a single pass before translating `%` and `_`.
- **String Literals & Cross-Column `UPDATE` (`parser.lua`, `executor.lua`)**: Preserves string literals `'NULL'`, `'true'`, and `'false'` on `INSERT`, supports cross-column arithmetic (`SET a = b + 1`), and cleans up stale secondary index keys on `UPDATE`.

### 3. VFS, Wire Protocol & Deduplication (`src/europadb/vfs/`, `net/`, `cluster/`, `bin/`)
- **VFS Hardening (`local_vfs.lua`, `s3_vfs.lua`, `aws_sigv4.lua`)**: Supports absolute paths in `LocalVFS`, sanitizes numeric PIDs before `kill -0`, single-quote escapes all `curl` arguments in `S3VFS`, and uses native Lua 5.3+ bitwise operators (`&`, `|`, `~`, `<<`, `>>`) in `aws_sigv4.lua`.
- **PostgreSQL Wire Protocol & Replicator (`pg_server.lua`, `replicator.lua`, `proto.lua`)**: Encodes SQL `NULL` as `-1` (`\255\255\255\255`) in `DataRow`, cleans up closed client sockets on `Terminate` (`X`), avoids executing DML mutations during `Describe` (`D`), fixes primary-key detection (`col.primary_key`) in `replicator.lua`, and consolidates 3 duplicate `pack_u32` implementations into `serializer.pack_uint32`.
- **CLI/Server Entrypoint Deduplication (`bin/`)**: Delegated `bin/luadb_cli.lua` and `bin/luadb_server.lua` to `bin/europadb_cli.lua` and `bin/europadb_server.lua` while preserving legacy `luadb=>` prompts and default `.db` paths.

---

## Verification
- All 22 suites in `make test` (`lua tests/run_all.lua`) pass 100%, including new regression tests in `tests/bugfixes_spec.lua`.
