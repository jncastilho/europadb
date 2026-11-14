package.path = "src/?.lua;src/?/init.lua;" .. package.path

local luadb = require("luadb")

local function assert_eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format("ASSERT FAILED: [%s] Expected %s, got %s", msg or "test", tostring(expected), tostring(actual)))
    else
        print(string.format("  ✓ [OK] %s: %s", msg or "check", tostring(actual)))
    end
end

print("\n--------------------------------------------------")
print("[TEST SUITE] Comprehensive Bug Fixes Verification")
print("--------------------------------------------------")

local db = luadb.open({ driver = "memory", storage_path = "bugfix_test.db" })

-- 1. Multi-Page B+Tree Leaf Split & Traversal
print("\n[Bug Fix 1] Multi-Page B+Tree Leaf Split & Traversal")
db:exec("CREATE TABLE bugfix_bigdata (id INT PRIMARY KEY, val REAL);")
for i = 1, 150 do
    db:exec(string.format("INSERT INTO bugfix_bigdata VALUES (%d, %.1f);", i, i + 0.5))
end

local all_rows = db:exec("SELECT * FROM bugfix_bigdata;")
assert_eq(#all_rows, 150, "B+Tree 150 Rows Total Count")

local mid_lookup = db:exec("SELECT * FROM bugfix_bigdata WHERE id = 75;")
assert_eq(#mid_lookup, 1, "B+Tree Mid-Tree Lookup Count")
assert_eq(mid_lookup[1].id, 75, "B+Tree Mid-Tree Lookup ID")

-- 2. Deep Tree Deletion across Multi-Level B+Tree
print("\n[Bug Fix 2] Deep Tree Deletion")
db:exec("DELETE FROM bugfix_bigdata WHERE id = 75;")
local post_delete_lookup = db:exec("SELECT * FROM bugfix_bigdata WHERE id = 75;")
assert_eq(#post_delete_lookup, 0, "Deleted Deep Tree Record Count")

local post_delete_all = db:exec("SELECT * FROM bugfix_bigdata;")
assert_eq(#post_delete_all, 149, "Post-Delete B+Tree Record Count")

-- 3. Secondary Index Maintenance on UPDATE and DELETE
print("\n[Bug Fix 3] Secondary Index Sync on UPDATE & DELETE")
db:exec("CREATE TABLE users (id INT PRIMARY KEY, username TEXT, role TEXT);")
db:exec("CREATE INDEX idx_user_role ON users (role);")

db:exec("INSERT INTO users VALUES (1, 'Alice', 'Engineer');")
db:exec("INSERT INTO users VALUES (2, 'Bob', 'Tester');")

-- UPDATE indexed column
db:exec("UPDATE users SET role = 'Lead' WHERE username = 'Alice';")
local updated_idx_lookup = db:exec("SELECT * FROM users WHERE role = 'Lead';")
assert_eq(#updated_idx_lookup, 1, "Updated Secondary Index Query Count")

-- DELETE indexed row
db:exec("DELETE FROM users WHERE username = 'Bob';")
local deleted_idx_lookup = db:exec("SELECT * FROM users WHERE role = 'Tester';")
assert_eq(#deleted_idx_lookup, 0, "Deleted Secondary Index Clean-Up Count")

-- 4. CTE Catalog Cleanup & No Shadowing
print("\n[Bug Fix 4] CTE Catalog Cleanup & No Table Shadowing")
db:exec("CREATE TABLE cte_test_employees (id INT PRIMARY KEY, name TEXT);")
db:exec("INSERT INTO cte_test_employees VALUES (1, 'Charlie');")

-- Run CTE with same name as real table
db:exec("WITH cte_test_employees AS (SELECT name FROM users) SELECT * FROM cte_test_employees;")

-- Verify real table is not shadowed or lost!
local real_emp = db:exec("SELECT * FROM cte_test_employees;")
assert_eq(#real_emp, 1, "Real Table Count Preserved After CTE")
assert_eq(real_emp[1] and real_emp[1].name, "Charlie", "Real Table Record Preserved")

-- 5. Safe ORDER BY Sorting with Mixed Strings/Numbers
print("\n[Bug Fix 5] Safe ORDER BY Comparator")
db:exec("CREATE TABLE items (id INT PRIMARY KEY, label TEXT);")
db:exec("INSERT INTO items VALUES (1, 'Zebra');")
db:exec("INSERT INTO items VALUES (2, 'Apple');")
local sorted = db:exec("SELECT * FROM items ORDER BY label ASC;")
assert_eq(sorted[1].label, "Apple", "ORDER BY String Ascending")

db:close()

-- 6. Foreign Key Catalog Persistence across Database Close and Re-open
print("\n[Bug Fix 6] Foreign Key Persistence Across Restart")
os.remove("fk_persist.db")
local db1 = luadb.open({ driver = "local", storage_path = "fk_persist.db" })
db1:exec("CREATE TABLE parent (id INT PRIMARY KEY, name TEXT);")
db1:exec("CREATE TABLE child (id INT PRIMARY KEY, parent_id INT, FOREIGN KEY (parent_id) REFERENCES parent(id));")
db1:exec("INSERT INTO parent VALUES (1, 'P1');")
db1:close()

-- Reopen database handle
local db2 = luadb.open({ driver = "local", storage_path = "fk_persist.db" })
local ok_fk, err_fk = db2:exec("INSERT INTO child VALUES (10, 99);") -- parent 99 does not exist!
assert_eq(ok_fk, nil, "FK Integrity Preserved After Restart")
assert_eq(err_fk:find("FOREIGN KEY constraint failed") ~= nil, true, "FK Violation Error Preserved")

db2:close()
os.remove("fk_persist.db")

-- 7. Split B+Tree Page Allocation Safety Across Database Reopen
print("\n[Bug Fix 7] Split B+Tree Page Allocation Safety Across Restart")
local split_db_path = "split_reopen_test.db"
os.remove(split_db_path)
os.remove(split_db_path .. ".wal")
os.remove(split_db_path .. ".lock")

local sdb1 = luadb.open({ driver = "local", storage_path = split_db_path })
sdb1:exec("CREATE TABLE big_split (id INT PRIMARY KEY, pad TEXT);")
local pad_200 = string.rep("P", 200)
sdb1:begin()
for i = 1, 200 do
    sdb1:exec(string.format("INSERT INTO big_split VALUES (%d, '%s');", i, pad_200))
end
sdb1:commit()
sdb1:close()

local sdb2 = luadb.open({ driver = "local", storage_path = split_db_path })
sdb2:exec("CREATE TABLE second_split (id INT PRIMARY KEY, pad TEXT);")
sdb2:begin()
for i = 1, 100 do
    sdb2:exec(string.format("INSERT INTO second_split VALUES (%d, '%s');", i, pad_200))
end
for i = 201, 300 do
    sdb2:exec(string.format("INSERT INTO big_split VALUES (%d, '%s');", i, pad_200))
end
sdb2:commit()

local cnt_big = sdb2:exec("SELECT COUNT(*) AS c FROM big_split;")
local cnt_sec = sdb2:exec("SELECT COUNT(*) AS c FROM second_split;")
assert_eq(cnt_big[1].c, 300, "big_split preserved all 300 rows across reopen + split")
assert_eq(cnt_sec[1].c, 100, "second_split preserved all 100 rows")
sdb2:close()
os.remove(split_db_path)
os.remove(split_db_path .. ".wal")
os.remove(split_db_path .. ".lock")

-- 8. SQL Edge Cases: LIKE Metacharacters, CTE Outer WHERE, JOIN, Precedence, UPDATE Negatives & String Literals
print("\n[Bug Fix 8] SQL Edge Cases (LIKE, CTE WHERE, JOIN, AND/OR Precedence, UPDATE, String Literals)")
local edb = luadb.open({ driver = "memory", storage_path = "edge_cases.db" })
edb:exec("CREATE TABLE edge_t (id INT PRIMARY KEY, a INT, b INT, tag TEXT);")
edb:exec("INSERT INTO edge_t VALUES (1, 10, 100, 'NULL');")
edb:exec("INSERT INTO edge_t VALUES (2, 20, 200, 'true');")
edb:exec("INSERT INTO edge_t VALUES (3, 30, 300, '(special).val');")

-- String literals 'NULL' and 'true' must remain strings
local r_lit = edb:exec("SELECT * FROM edge_t ORDER BY id ASC;")
assert_eq(r_lit[1].tag, "NULL", "String literal 'NULL' preserved as string")
assert_eq(r_lit[2].tag, "true", "String literal 'true' preserved as string")

-- LIKE with regex metacharacters '(' and '.'
local r_like_paren = edb:exec("SELECT * FROM edge_t WHERE tag LIKE '(%';")
assert_eq(#r_like_paren, 1, "LIKE with '(' metacharacter does not crash and matches 1 row")
local r_like_dot = edb:exec("SELECT * FROM edge_t WHERE tag LIKE 'n.ll';")
assert_eq(#r_like_dot, 0, "LIKE '.' is escaped as literal dot, not wildcard")

-- CTE with outer WHERE and projection
local r_cte = edb:exec("WITH sub AS (SELECT id, tag FROM edge_t) SELECT tag FROM sub WHERE id = 2;")
assert_eq(#r_cte, 1, "CTE outer WHERE filtered to 1 row")
assert_eq(r_cte[1].tag, "true", "CTE outer projection returned expected column")

-- UPDATE cross-column arithmetic and negative numbers
edb:exec("UPDATE edge_t SET a = b + 5 WHERE id = 1;")
edb:exec("UPDATE edge_t SET b = -42 WHERE id = 2;")
local r_upd = edb:exec("SELECT * FROM edge_t ORDER BY id ASC;")
assert_eq(r_upd[1].a, 105, "UPDATE cross-column SET a = b + 5")
assert_eq(r_upd[2].b, -42, "UPDATE negative number SET b = -42")

-- Boolean operator precedence: AND binds tighter than OR
local r_prec = edb:exec("SELECT * FROM edge_t WHERE id = 1 AND a = 999 OR id = 2;")
assert_eq(#r_prec, 1, "WHERE A AND B OR C evaluates as (A AND B) OR C")
assert_eq(r_prec[1].id, 2, "Precedence matched id = 2")

-- INNER JOIN
edb:exec("CREATE TABLE orders_t (oid INT PRIMARY KEY, uid INT, item TEXT);")
edb:exec("INSERT INTO orders_t VALUES (10, 1, 'Keyboard');")
local r_join = edb:exec("SELECT * FROM edge_t JOIN orders_t ON edge_t.id = orders_t.uid;")
assert_eq(#r_join, 1, "INNER JOIN matched 1 row")
assert_eq(r_join[1].item, "Keyboard", "INNER JOIN projected joined column")

-- REINDEX inside active transaction preserves uncommitted rows
edb:begin()
edb:exec("INSERT INTO edge_t VALUES (4, 40, 400, 'in_tx');")
edb:exec("REINDEX;")
edb:commit()
local r_reidx = edb:exec("SELECT * FROM edge_t WHERE id = 4;")
assert_eq(#r_reidx, 1, "REINDEX inside transaction preserved uncommitted row")
edb:close()

print("\n[PASS] Comprehensive Bug Fixes Suite Passed 100%!")
