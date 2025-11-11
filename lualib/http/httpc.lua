-- 说明：
--  httpc 是一个轻量 HTTP/HTTPS 客户端：
--   - 支持 http/https 协议，https 通过 tlshelper 建立 TLS 客户端会话
--   - 可选异步 DNS（skynet.dns），通过 httpc.dns(server,port) 指定解析器
--   - 提供 request/get/post/head 与 request_stream（流式响应）
--  使用概览：
--    local code, body = httpc.get("http://example.com", "/path")
--    local code = httpc.head("https://example.com", "/")
--    -- 流式读取示例：
--    local stream = httpc.request_stream("GET", "https://example.com", "/large")
--    for chunk in stream do
--        if not chunk then break end  -- 连接关闭/异常
--        -- 处理 chunk（可能为空字符串）
--    end
--    stream:close()
local skynet = require "skynet"
local socket = require "http.sockethelper"
local internal = require "http.internal"
local dns = require "skynet.dns"

local string = string
local table = table
local pcall = pcall
local error = error
local pairs = pairs

local httpc = {}


local async_dns

function httpc.dns(server,port)
	async_dns = true
	dns.server(server,port)
end


-- 解析协议前缀，返回 (protocol, host)
local function check_protocol(host)
	local protocol = host:match("^[Hh][Tt][Tt][Pp][Ss]?://")
	if protocol then
		host = string.gsub(host, "^"..protocol, "")
		protocol = string.lower(protocol)
		if protocol == "https://" then
			return "https", host
		elseif protocol == "http://" then
			return "http", host
		else
			error(string.format("Invalid protocol: %s", protocol))
		end
	else
		return "http", host
	end
end

local SSLCTX_CLIENT = nil
-- 根据协议构造 I/O 接口：
--  - http: 直接使用 sockethelper 的 read/write/readall
--  - https: 使用 tlshelper 包装 fd，提供 TLS 的 read/write/readall
local function gen_interface(protocol, fd, hostname)
	if protocol == "http" then
		return {
			init = nil,
			close = nil,
			read = socket.readfunc(fd),
			write = socket.writefunc(fd),
			readall = function ()
				return socket.readall(fd)
			end,
		}
	elseif protocol == "https" then
		local tls = require "http.tlshelper"
		SSLCTX_CLIENT = SSLCTX_CLIENT or tls.newctx()
		local tls_ctx = tls.newtls("client", SSLCTX_CLIENT, hostname)
		return {
			init = tls.init_requestfunc(fd, tls_ctx),
			close = tls.closefunc(tls_ctx),
			read = tls.readfunc(fd, tls_ctx),
			write = tls.writefunc(fd, tls_ctx),
			readall = tls.readallfunc(fd, tls_ctx),
		}
	else
		error(string.format("Invalid protocol: %s", protocol))
	end
end

-- 连接到目标主机：
--  - 支持 http/https 与显式端口
--  - 可选 async_dns ：通过 dns.resolve(hostname) 获取地址
--  - 超时控制：超时后 shutdown fd（交由 close 进行清理）
local function connect(host, timeout)
	local protocol
	protocol, host = check_protocol(host)
	local hostaddr, port = host:match"([^:]+):?(%d*)$"
	if port == "" then
		port = protocol=="http" and 80 or protocol=="https" and 443
	else
		port = tonumber(port)
	end
	local hostname
	if not hostaddr:match(".*%d+$") then
		hostname = hostaddr
		if async_dns then
			hostaddr = dns.resolve(hostname)
		end
	end
	local fd = socket.connect(hostaddr, port, timeout)
	if not fd then
		error(string.format("%s connect error host:%s, port:%s, timeout:%s", protocol, hostaddr, port, timeout))
	end
	-- print("protocol hostname port", protocol, hostname, port)
	local interface = gen_interface(protocol, fd, hostname)
	if timeout then
		skynet.timeout(timeout, function()
			if not interface.finish then
				socket.shutdown(fd)	-- shutdown the socket fd, need close later.
			end
		end)
	end
	if interface.init then
		interface.init(host)
	end
	return fd, interface, host
end

-- 关闭连接，释放 TLS 资源（若有）
local function close_interface(interface, fd)
	interface.finish = true
	socket.close(fd)
	if interface.close then
		interface.close()
		interface.close = nil
	end
end

-- 发送一次完整请求，返回 (statuscode, body)
function httpc.request(method, hostname, url, recvheader, header, content)
	local fd, interface, host = connect(hostname, httpc.timeout)
	local ok , statuscode, body , header = pcall(internal.request, interface, method, host, url, recvheader, header, content)
	if ok then
		ok, body = pcall(internal.response, interface, statuscode, body, header)
	end
	close_interface(interface, fd)
	if ok then
		return statuscode, body
	else
		error(body or statuscode)
	end
end

-- 发送 HEAD 请求，仅返回状态码
function httpc.head(hostname, url, recvheader, header, content)
	local fd, interface, host = connect(hostname, httpc.timeout)
	local ok , statuscode = pcall(internal.request, interface, "HEAD", host, url, recvheader, header, content)
	close_interface(interface, fd)
	if ok then
		return statuscode
	else
		error(statuscode)
	end
end

-- 发送请求并以流式方式读取响应体（chunked/大文件友好）
--  注意：response_stream 暂无超时控制，上层需在合适时机调用 stream:close()
function httpc.request_stream(method, hostname, url, recvheader, header, content)
	local fd, interface, host = connect(hostname, httpc.timeout)
	local ok , statuscode, body , header = pcall(internal.request, interface, method, host, url, recvheader, header, content)
	interface.finish = true -- don't shutdown fd in timeout
	local function close_fd()
		close_interface(interface, fd)
	end
	if not ok then
		close_fd()
		error(statuscode)
	end
	-- todo: stream support timeout
	local stream = internal.response_stream(interface, statuscode, body, header)
	stream._onclose = close_fd
	return stream
end

function httpc.get(...)
	return httpc.request("GET", ...)
end

-- 表单编码：对非字母数字下划线字符进行 %XX 转义
local function escape(s)
	return (string.gsub(s, "([^A-Za-z0-9_])", function(c)
		return string.format("%%%02X", string.byte(c))
	end))
end

-- x-www-form-urlencoded 的快捷 POST：form 为 k/v 表
function httpc.post(host, url, form, recvheader)
	local header = {
		["content-type"] = "application/x-www-form-urlencoded"
	}
	local body = {}
	for k,v in pairs(form) do
		table.insert(body, string.format("%s=%s",escape(k),escape(v)))
	end

	return httpc.request("POST", host, url, recvheader, header, table.concat(body , "&"))
end

return httpc
