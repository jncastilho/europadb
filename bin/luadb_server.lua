#!/usr/bin/env luajit
_G._LUADB_SERVER_MODE = true
local script_dir = debug.getinfo(1, "S").source:match("^@(.+/)[^/]+$") or "bin/"
return dofile(script_dir .. "europadb_server.lua")
