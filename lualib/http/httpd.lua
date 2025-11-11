-- 说明：
--  httpd 提供最小化的 HTTP 服务器编解码：
--   - read_request(readfunc, bodylimit?) 读取完整请求，支持 chunked 与 identity
--   - write_response(writefunc, statuscode, bodyfunc|string|nil, header_table)
--  常配合 http.sockethelper/readfunc 与 socket.write 实现简单 HTTP 服务。
--  使用要点：
--   - read_request 返回 (code, url, method, header, body)；code 非 200 代表错误
--   - bodylimit 可限制请求体大小，超限返回 413
--   - write_response 的 body 可为 string（一次性）或 function（chunked 流）或 nil
--   - 返回值为 ok, err（pcall 包装），避免将异常抛到上层
local internal = require "http.internal"

local string = string
local type = type
local assert = assert
local tonumber = tonumber
local pcall = pcall
local ipairs = ipairs
local pairs = pairs

local httpd = {}

local http_status_msg = {
	[100] = "Continue",
	[101] = "Switching Protocols",
	[200] = "OK",
	[201] = "Created",
	[202] = "Accepted",
	[203] = "Non-Authoritative Information",
	[204] = "No Content",
	[205] = "Reset Content",
	[206] = "Partial Content",
	[300] = "Multiple Choices",
	[301] = "Moved Permanently",
	[302] = "Found",
	[303] = "See Other",
	[304] = "Not Modified",
	[305] = "Use Proxy",
	[307] = "Temporary Redirect",
	[400] = "Bad Request",
	[401] = "Unauthorized",
	[402] = "Payment Required",
	[403] = "Forbidden",
	[404] = "Not Found",
	[405] = "Method Not Allowed",
	[406] = "Not Acceptable",
	[407] = "Proxy Authentication Required",
	[408] = "Request Time-out",
	[409] = "Conflict",
	[410] = "Gone",
	[411] = "Length Required",
	[412] = "Precondition Failed",
	[413] = "Request Entity Too Large",
	[414] = "Request-URI Too Large",
	[415] = "Unsupported Media Type",
	[416] = "Requested range not satisfiable",
	[417] = "Expectation Failed",
	[500] = "Internal Server Error",
	[501] = "Not Implemented",
	[502] = "Bad Gateway",
	[503] = "Service Unavailable",
	[504] = "Gateway Time-out",
	[505] = "HTTP Version not supported",
}

-- 读取并解析一条 HTTP 请求，返回 (code, url, method, header, body)
--  - code 非 200 表示错误（状态码）
--  - 支持 transfer-encoding: chunked 与 content-length
-- 读取并解析一条 HTTP 请求的内部实现：
--  - readbytes: 函数，读取若干字节；由 http.sockethelper.readfunc(fd) 提供
--  - bodylimit: number|nil，限制非 chunked 模式下的 Content-Length
local function readall(readbytes, bodylimit)
	local tmpline = {}
	local body = internal.recvheader(readbytes, tmpline, "")
	if not body then
		return 413	-- Request Entity Too Large
	end
	local request = assert(tmpline[1])
	local method, url, httpver = request:match "^(%a+)%s+(.-)%s+HTTP/([%d%.]+)$"
	assert(method and url and httpver)
	httpver = assert(tonumber(httpver))
	if httpver < 1.0 or httpver > 1.1 then
		return 505	-- HTTP Version not supported
	end
	local header = internal.parseheader(tmpline,2,{})
	if not header then
		return 400	-- Bad request
	end
	local length = header["content-length"]
	if length then
		length = tonumber(length)
	end
	local mode = header["transfer-encoding"]
	if mode then
		if mode ~= "identity" and mode ~= "chunked" then
			-- 服务器端仅支持 identity 与 chunked 两种传输编码
			return 501	-- Not Implemented
		end
	end

	if mode == "chunked" then
		-- chunked：逐块读取直到 size=0，随后解析 trailer 合并到 header
		body, header = internal.recvchunkedbody(readbytes, bodylimit, header, body)
		if not body then
			return 413
		end
	else
		-- identity mode 按 content-length 读取完整体
		if length then
			if bodylimit and length > bodylimit then
				return 413
			end
			if #body >= length then
				body = body:sub(1,length)
			else
				local padding = readbytes(length - #body)
				body = body .. padding
			end
		end
	end

	return 200, url, method, header, body
end

function httpd.read_request(...)
	local ok, code, url, method, header, body = pcall(readall, ...)
	if ok then
		return code, url, method, header, body
	else
		return nil, code
	end
end

-- 写出一个 HTTP 响应：
--  - bodyfunc 可为 string（一次性）或 function（chunked 流）或 nil（无正文）
--  - header 为 kv 表，value 可为字符串或数组
-- 写出一个 HTTP 响应：
--  - writefunc: 函数，发送字符串到 socket；常用 http.sockethelper.writefunc(fd)
--  - statuscode: 数字状态码（200/404/...）
--  - bodyfunc: string | function | nil
--      string   -> 设置 content-length 并一次性写出
--      function -> 采用 chunked 编码，函数每次返回一段数据（"" 允许，nil 结束）
--      nil      -> 仅写出 header
--  - header: table，k/v 头部；若 v 为数组则输出多行
local function writeall(writefunc, statuscode, bodyfunc, header)
	local statusline = string.format("HTTP/1.1 %03d %s\r\n", statuscode, http_status_msg[statuscode] or "")
	writefunc(statusline)
	if header then
		for k,v in pairs(header) do
			if type(v) == "table" then
				for _,v in ipairs(v) do
					writefunc(string.format("%s: %s\r\n", k,v))
				end
			else
				writefunc(string.format("%s: %s\r\n", k,v))
			end
		end
	end
	local t = type(bodyfunc)
	if t == "string" then
		writefunc(string.format("content-length: %d\r\n\r\n", #bodyfunc))
		writefunc(bodyfunc)
	elseif t == "function" then
		-- 按 chunked 编码逐块写出：
		--  每个块格式为：CRLF + hexlen + CRLF + data
		--  结束块格式为：CRLF + 0 + CRLF + CRLF
		writefunc("transfer-encoding: chunked\r\n")
		while true do
			local s = bodyfunc()
			if s then
				if s ~= "" then
					writefunc(string.format("\r\n%x\r\n", #s))
					writefunc(s)
				end
			else
				writefunc("\r\n0\r\n\r\n")
				break
			end
		end
	else
		assert(t == "nil")
		writefunc("\r\n")
	end
end

function httpd.write_response(...)
	return pcall(writeall, ...)
end

return httpd
