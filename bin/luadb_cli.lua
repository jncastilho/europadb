#!/usr/bin/env lua
_G._LUADB_CLI_MODE = true
local script_dir = debug.getinfo(1, "S").source:match("^@(.+/)[^/]+$") or "bin/"
return dofile(script_dir .. "europadb_cli.lua")
