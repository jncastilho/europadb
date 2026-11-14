local serializer = require("europadb.storage.serializer")
local proto = {}

-- Message Header: 1 byte Type + 4 bytes Payload Length (Big Endian)
local pack_u32 = serializer.pack_uint32
local function unpack_u32(str, pos)
    return serializer.unpack_uint32(str, pos) or 0
end

function proto.make_msg(msg_type, payload)
    payload = payload or ""
    local len = #payload
    return msg_type .. pack_u32(len) .. payload
end

function proto.parse_msg(pkt)
    if not pkt or #pkt < 5 then return nil, "Incomplete header" end
    local msg_type = pkt:sub(1, 1)
    local len = unpack_u32(pkt, 2)
    if #pkt < 5 + len then return nil, "Incomplete payload" end
    local payload = pkt:sub(6, 5 + len)
    local rest = pkt:sub(6 + len)
    return {
        type = msg_type,
        len = len,
        payload = payload
    }, rest
end

function proto.serialize_replicate(tx_id, origin_node, ts, sql, table_name, pk_val)
    local t_name = table_name or ""
    local pk = pk_val ~= nil and tostring(pk_val) or ""
    local ts_str = ""
    if type(ts) == "table" then
        ts_str = string.format("%.0f:%.0f", tonumber(ts.pt) or 0, tonumber(ts.lc) or 0)
    else
        ts_str = tostring(ts or 0)
    end
    return string.format("%s\n%s\n%s\n%s\n%s\n%s", tostring(tx_id), tostring(origin_node), ts_str, tostring(t_name), tostring(pk), tostring(sql))
end

function proto.deserialize_replicate(payload)
    if not payload then return nil end
    local tx_id, origin_node, ts_str, t_name, pk_val, sql = payload:match("^([^\n]+)\n([^\n]+)\n([^\n]+)\n([^\n]*)\n([^\n]*)\n(.*)$")
    if tx_id then
        local pt, lc = ts_str:match("^([%d%.]+):([%d%.]+)$")
        local hlc_val
        if pt then
            hlc_val = { pt = tonumber(pt) or 0, lc = tonumber(lc) or 0 }
        else
            hlc_val = { pt = tonumber(ts_str) or 0, lc = 0 }
        end
        return {
            tx_id = tx_id,
            origin_node = origin_node,
            timestamp = hlc_val,
            table_name = t_name ~= "" and t_name or nil,
            pk_val = pk_val ~= "" and pk_val or nil,
            sql = sql
        }
    end
    -- Fallback for legacy format
    local l_tx, l_node, l_ts, l_sql = payload:match("^([^\n]+)\n([^\n]+)\n(%d+)\n(.*)$")
    if l_tx then
        return {
            tx_id = l_tx,
            origin_node = l_node,
            timestamp = { pt = tonumber(l_ts) or 0, lc = 0 },
            table_name = nil,
            pk_val = nil,
            sql = l_sql
        }
    end
    return nil
end

return proto
