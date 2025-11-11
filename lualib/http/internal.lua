-- 说明：
--  http.internal 是 httpc/httpd 的核心协议工具集：
--   - recvheader/parseheader：读取并解析 HTTP 头
--   - recvchunkedbody：按 chunked 编码读取响应体
--   - request/response：发送请求与读取响应（一次性）
--   - response_stream：以迭代器形式暴露响应体，支持 chunked 与 content-length
--  设计说明：
--   - 限制 header 最大长度（LIMIT）避免 DoS；chunksize/readcrln 对异常严格校验
--   - 流读取中以状态机切换 _reading（nobody/length/all/chunked），并暴露 connected 状态
--   - TODO：流式读取未实现超时，调用方需在上层控制生命周期（见 httpc.request_stream）
local table = table
local type = type
local string = string
local tonumber = tonumber
local pcall = pcall
local assert = assert
local error = error
local pairs = pairs

local M = {}

local LIMIT = 8192

-- 读取 chunked 的 size 行，直到 CRLF；防止无界增长（#body > 128 即拒绝）
local function chunksize(readbytes, body)
	while true do
		local f,e = body:find("\r\n",1,true)
		if f then
			return tonumber(body:sub(1,f-1),16), body:sub(e+1)
		end
		if #body > 128 then
			-- pervent the attacker send very long stream without \r\n
			return
		end
		body = body .. readbytes()
	end
end

-- 读取并校验 CRLF，返回剩余 body；若异常返回 nil
local function readcrln(readbytes, body)
	if #body >= 2 then
		if body:sub(1,2) ~= "\r\n" then
			return
		end
		return body:sub(3)
	else
		body = body .. readbytes(2-#body)
		if body ~= "\r\n" then
			return
		end
		return ""
	end
end

-- 读取 HTTP 首部：
--  - 累积直到出现 \r\n\r\n
--  - 限制最大长度 LIMIT，避免过长首部
--  - 将逐行结果写入 lines，并返回剩余 body（可能含部分实体）
function M.recvheader(readbytes, lines, header)
	if #header >= 2 then
		if header:find "^\r\n" then
			return header:sub(3)
		end
	end
	local result
	local e = header:find("\r\n\r\n", 1, true)
	if e then
		result = header:sub(e+4)
	else
		while true do
			local bytes = readbytes()
			header = header .. bytes
			e = header:find("\r\n\r\n", -#bytes-3, true)
			if e then
				result = header:sub(e+4)
				break
			end
			if header:find "^\r\n" then
				return header:sub(3)
			end
			if #header > LIMIT then
				return
			end
		end
	end
	for v in header:gmatch("(.-)\r\n") do
		if v == "" then
			break
		end
		table.insert(lines, v)
	end
	return result
end

-- 解析首部行：处理同名多值（合并为表），tab 前缀行视为上一行延续
function M.parseheader(lines, from, header)
	local name, value
	for i=from,#lines do
		local line = lines[i]
		if line:byte(1) == 9 then	-- tab, append last line
			if name == nil then
				return
			end
			header[name] = header[name] .. line:sub(2)
		else
			name, value = line:match "^(.-):%s*(.*)"
			if name == nil or value == nil then
				return
			end
			name = name:lower()
			if header[name] then
				local v = header[name]
				if type(v) == "table" then
					table.insert(v, value)
				else
					header[name] = { v , value }
				end
			else
				header[name] = value
			end
		end
	end
	return header
end

-- 读取 chunked 实体：
--  - 循环读取 size → 正文 → CRLF；size=0 后继续读取 trailer（作为 header 补充）
--  - bodylimit：可选的最大实体限制
function M.recvchunkedbody(readbytes, bodylimit, header, body)
	local result = ""
	local size = 0

	while true do
		local sz
		sz , body = chunksize(readbytes, body)
		if not sz then
			return
		end
		if sz == 0 then
			break
		end
		size = size + sz
		if bodylimit and size > bodylimit then
			return
		end
		if #body >= sz then
			result = result .. body:sub(1,sz)
			body = body:sub(sz+1)
		else
			result = result .. body .. readbytes(sz - #body)
			body = ""
		end
		body = readcrln(readbytes, body)
		if not body then
			return
		end
	end

	local tmpline = {}
	body = M.recvheader(readbytes, tmpline, body)
	if not body then
		return
	end

	header = M.parseheader(tmpline,1,header)

	return result, header
end

-- identity 模式读取实体：优先 Content-Length；204/304/1xx 视为空体；否则 readall
local function recvbody(interface, code, header, body)
	local length = header["content-length"]
	if length then
		length = tonumber(length)
	end
	if length then
		if #body >= length then
			body = body:sub(1,length)
		else
			local padding = interface.read(length - #body)
			body = body .. padding
		end
	elseif code == 204 or code == 304 or code < 200 then
		body = ""
		-- See https://stackoverflow.com/questions/15991173/is-the-content-length-header-required-for-a-http-1-0-response
	else
		-- no content-length, read all
		body = body .. interface.readall()
	end
	return body
end

-- 发送一次请求并读取响应首部：
--  - 若有 content 且未启用 chunked，自动写入 Content-length
--  - 返回 code, body(可能含剩余实体), header
function M.request(interface, method, host, url, recvheader, header, content)
	local read = interface.read
	local write = interface.write
	local header_content = ""
	if header then
		if not header.Host then
			header.Host = host
		end
		for k,v in pairs(header) do
			header_content = string.format("%s%s:%s\r\n", header_content, k, v)
		end
	else
		header_content = string.format("host:%s\r\n",host)
	end

	if content then
		local data
		if header and header["transfer-encoding"] == "chunked" then
			data = string.format("%s %s HTTP/1.1\r\n%s\r\n", method, url, header_content)
		else
			data = string.format("%s %s HTTP/1.1\r\n%sContent-length:%d\r\n\r\n", method, url, header_content, #content)
		end
		write(data)
		write(content)
	else
		local request_header = string.format("%s %s HTTP/1.1\r\n%sContent-length:0\r\n\r\n", method, url, header_content)
		write(request_header)
	end

	local tmpline = {}
	local body = M.recvheader(read, tmpline, "")
	if not body then
		error("Recv header failed")
	end

	local statusline = tmpline[1]
	local code, info = statusline:match "HTTP/[%d%.]+%s+([%d]+)%s+(.*)$"
	code = assert(tonumber(code))

	local header = M.parseheader(tmpline,2,recvheader or {})
	if not header then
		error("Invalid HTTP response header")
	end
	return code, body, header
end

-- 读取完整响应体：根据 transfer-encoding 决定 chunked 或 identity
function M.response(interface, code, body, header)
	local mode = header["transfer-encoding"]
	if mode then
		if mode ~= "identity" and mode ~= "chunked" then
			error ("Unsupport transfer-encoding")
		end
	end

	if mode == "chunked" then
		body, header = M.recvchunkedbody(interface.read, nil, header, body)
		if not body then
			error("Invalid response body")
		end
	else
		-- identity mode
		body = recvbody(interface, code, header, body)
	end

	return body
end

-- 流式响应体：
--  - stream.__call → stream:padding()，可被 Lua 泛型 for 使用
--  - stream.connected 指示连接是否仍可读；close 触发 _onclose（通常关闭 fd）
local stream = {}; stream.__index = stream

function stream:close()
	if self._onclose then
		self._onclose(self)
		self._onclose = nil
	end
end

-- 以 (iterator, state) 形式返回，下游可 for chunk in stream do ... end
function stream:padding()
	return self._reading(self), self
end

stream.__close = stream.close
stream.__call = stream.padding

-- 无实体（204/304/1xx）：关闭迭代，返回空串一次
local function stream_nobody(stream)
	stream._reading = stream.close
	stream.connected = nil
	return ""
end

-- 固定长度实体：按 content-length 读取
local function stream_length(length)
	return function(stream)
		local body = stream._body
		if body == nil then
			local ret, padding = stream._interface.read()
			if not ret then
				-- disconnected
				body = padding
				stream.connected = false
			else
				body = ret
			end
		end
		local n = #body
		if n >= length then
			stream._reading = stream.close
			stream.connected = nil
			return (body:sub(1,length))
		else
			length = length - n
			stream._body = nil
			if not stream.connected then
				stream._reading = stream.close
			end
			return body
		end
	end
end

-- 逐次读取：当返回空或连接断开，设置 connected=nil 并触发 close
local function stream_read(stream)
	local ret, padding = stream._interface.read()
	if ret == "" or not ret then
		stream.connected = nil
		stream:close()
		if padding == "" then
			return
		end
		return padding
	end
	return ret
end

-- 读取剩余全部实体后，切换为按需读取模式（对后续 chunked 处理兼容）
local function stream_all(stream)
	local body = stream._body
	stream._body = nil
	stream._reading = stream_read
	return body
end

-- chunked 模式：逐块返回 body，结尾读取 trailer 并合并到 header
local function stream_chunked(stream)
	local read = stream._interface.read
	local sz, body = chunksize(read, stream._body)
	if not sz then
		stream.connected = false
		stream:close()
		return
	end

	if sz == 0 then
		-- last chunk
		local tmpline = {}
		body = M.recvheader(read, tmpline, body)
		if not body then
			stream.connected = false
			stream:close()
			return
		end

		M.parseheader(tmpline,1, stream.header)

		stream._reading = stream.close
		stream.connected = nil
		return ""
	end

	local n = #body
	local remain

	if n >= sz then
		remain = body:sub(sz+1)
		body = body:sub(1,sz)
	else
		body = body .. read(sz - n)
		remain = ""
	end
	remain = readcrln(read, remain)
	if not remain then
		stream.connected = false
		stream:close()
		return
	end
	stream._body = remain
	return body
end

-- 以流式方式封装响应体：根据编码选择读取函数，并携带状态
function M.response_stream(interface, code, body, header)
	local mode = header["transfer-encoding"]
	if mode then
		if mode ~= "identity" and mode ~= "chunked" then
			error ("Unsupport transfer-encoding")
		end
	end

	local read_func

	if mode == "chunked" then
		read_func = stream_chunked
	else
		-- identity mode
		local length = header["content-length"]
		if length then
			length = tonumber(length)
		end
		if length then
			read_func = stream_length(length)
		elseif code == 204 or code == 304 or code < 200 then
			read_func = stream_nobody
		else
			read_func = stream_all
		end
	end

	-- todo: timeout

	return setmetatable({
		status = code,
		_body = body,
		_interface = interface,
		_reading = read_func,
		header = header,
		connected = true,
	}, stream)
end

return M
