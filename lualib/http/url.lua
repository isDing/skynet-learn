-- 说明：
--  http.url 提供极简 URL/Query 解析：
--   - parse(u)         -> path, query_string（解码 path 中的 %XX 与 +）
--   - parse_query(qs)  -> table，支持同名多值（折叠为数组）
--  注意：不解析 scheme/host/port，仅对形如 "/path?x=1&x=2&y=3" 的路径与查询串进行处理。
local url = {}

local function decode_func(c)
	return string.char(tonumber(c, 16))
end

-- 解码：将 "+" 恢复为空格，"%XX" 转为字节
local function decode(str)
	local str = str:gsub('+', ' ')
	return str:gsub("%%(..)", decode_func)
end

-- 解析 URL：返回 path 与原始 query 字符串（不含问号）
function url.parse(u)
	local path,query = u:match "([^?]*)%??(.*)"
	if path then
		path = decode(path)
	end
	return path, query
end

-- 解析查询串：形如 "a=1&b=2&b=3"；多值折叠为数组
function url.parse_query(q)
	local r = {}
	for k,v in q:gmatch "(.-)=([^&]*)&?" do
		local dk, dv = decode(k), decode(v)
		local oldv = r[dk]
		if oldv then
			if type(oldv) ~= "table" then
				r[dk] = {oldv, dv}
			else
				oldv[#oldv+1] = dv
			end
		else
			r[dk] = dv
		end
	end
	return r
end

return url
