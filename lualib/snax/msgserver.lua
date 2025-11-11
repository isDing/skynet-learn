-- 说明：
--  msgserver 基于 gateserver 封装了一个“带登录鉴权 + 请求/响应”的客户端消息网关。
--  特点：
--    - 首包握手认证（base64(uid)@base64(server)#base64(subid):index:base64(hmac)）
--    - 之后的包采用带会话的请求/响应格式（大小端：大端序）
--    - 支持重发/重连后的响应重投递（response cache + 版本/索引控制）
--  依赖：netpack 做包编解码，crypt 做 hmac 校验，socketdriver 发包。
local skynet = require "skynet"
local gateserver = require "snax.gateserver"
local netpack = require "skynet.netpack"
local crypt = require "skynet.crypt"
local socketdriver = require "skynet.socketdriver"
local assert = assert
local b64encode = crypt.base64encode
local b64decode = crypt.base64decode

--[[

Protocol:

	All the number type is big-endian

	Shakehands (The first package)

	Client -> Server :

	base64(uid)@base64(server)#base64(subid):index:base64(hmac)

	Server -> Client

	XXX ErrorCode
		404 User Not Found
		403 Index Expired
		401 Unauthorized
		400 Bad Request
		200 OK

	Req-Resp

	Client -> Server : Request
		word size (Not include self)
		string content (size-4)
		dword session

	Server -> Client : Response
		word size (Not include self)
		string content (size-5)
		byte ok (1 is ok, 0 is error)
		dword session

API:
	server.userid(username)
		return uid, subid, server

	server.username(uid, subid, server)
		return username

	server.login(username, secret)
		update user secret

	server.logout(username)
		user logout

	server.ip(username)
		return ip when connection establish, or nil

	server.start(conf)
		start server

Supported skynet command:
	kick username (may used by loginserver)
	login username secret  (used by loginserver)
	logout username (used by agent)

Config for server.start:
	conf.expired_number : the number of the response message cached after sending out (default is 128)
	conf.login_handler(uid, secret) -> subid : the function when a new user login, alloc a subid for it. (may call by login server)
	conf.logout_handler(uid, subid) : the functon when a user logout. (may call by agent)
	conf.kick_handler(uid, subid) : the functon when a user logout. (may call by login server)
	conf.request_handler(username, session, msg) : the function when recv a new request.
	conf.register_handler(servername) : call when gate open
	conf.disconnect_handler(username) : call when a connection disconnect (afk)
]]

local server = {}

skynet.register_protocol {
	name = "client",
	id = skynet.PTYPE_CLIENT,
}

local user_online = {}
local handshake = {}
local connection = {}
-- user_online[username] = {
--   secret, version, index, username,
--   response = { [session] = { return_fd, response_bin, version_at_build, index_at_build } },
--   fd, ip
-- }
-- handshake[fd] = addr  -- 记录新连接在通过认证前的地址，首个包走认证流程
-- connection[fd] = user_online[username]  -- 通过认证后的 fd -> 用户映射

function server.userid(username)
	-- base64(uid)@base64(server)#base64(subid)
	local uid, servername, subid = username:match "([^@]*)@([^#]*)#(.*)"
	return b64decode(uid), b64decode(subid), b64decode(servername)
end

function server.username(uid, subid, servername)
	return string.format("%s@%s#%s", b64encode(uid), b64encode(servername), b64encode(tostring(subid)))
end

function server.logout(username)
	local u = user_online[username]
	user_online[username] = nil
	if u.fd then
		if connection[u.fd] then
			gateserver.closeclient(u.fd)
			connection[u.fd] = nil
		end
	end
end

function server.login(username, secret)
	assert(user_online[username] == nil)
	user_online[username] = {
		secret = secret,
		version = 0,
		index = 0,
		username = username,
		response = {},	-- response cache
	}
end

function server.ip(username)
	local u = user_online[username]
	if u and u.fd then
		return u.ip
	end
end

function server.start(conf)
	local expired_number = conf.expired_number or 128

	local handler = {}

	local CMD = {
		login = assert(conf.login_handler),
		logout = assert(conf.logout_handler),
		kick = assert(conf.kick_handler),
	}

	function handler.command(cmd, source, ...)
		-- 处理外部 skynet 命令（来自 loginserver/agent），如 login/logout/kick
		local f = assert(CMD[cmd])
		return f(...)
	end

	function handler.open(source, gateconf)
		-- 网关监听建立后回调：通知上层注册当前 server 名
		local servername = assert(gateconf.servername)
		return conf.register_handler(servername)
	end

	function handler.connect(fd, addr)
		-- 新连接建立：记录地址，打开客户端收消息；首包走认证
		handshake[fd] = addr
		gateserver.openclient(fd)
	end

	function handler.disconnect(fd)
		-- 连接断开：清理状态并通知上层 disconnect_handler（若提供）
		handshake[fd] = nil
		local c = connection[fd]
		if c then
			if conf.disconnect_handler then
				conf.disconnect_handler(c.username)
			end
			-- double check, conf.disconnect_handler may close fd
			if connection[fd] then
				c.fd = nil
				connection[fd] = nil
				gateserver.closeclient(fd)
			end
		end
	end

	handler.error = handler.disconnect

	-- atomic , no yield
	local function do_auth(fd, message, addr)
		-- 认证流程（不可 yield）
	--  - 客户端首包：username:index:hmac 其中 username=base64(uid)@base64(server)#base64(subid)
	--  - 服务端校验：index 必须严格递增（防止重放），HMAC(challenge, secret) 必须匹配
	--  - 通过后：更新 u.version=idx，记录当前 fd/ip，connection[fd]=u
		local username, index, hmac = string.match(message, "([^:]*):([^:]*):([^:]*)")
		local u = user_online[username]
		if u == nil then
			return "404 User Not Found"
		end
		local idx = assert(tonumber(index))
		hmac = b64decode(hmac)

		if idx <= u.version then
			return "403 Index Expired"
		end

		local text = string.format("%s:%s", username, index)
		local v = crypt.hmac_hash(u.secret, text)	-- equivalent to crypt.hmac64(crypt.hashkey(text), u.secret)
		if v ~= hmac then
			return "401 Unauthorized"
		end

		u.version = idx
		u.fd = fd
		u.ip = addr
		connection[fd] = u
	end

	local function auth(fd, addr, msg, sz)
		-- 认证入口：解析首包、调用 do_auth，返回 200 OK/错误码，并按需关闭连接
		local message = netpack.tostring(msg, sz)
		local ok, result = pcall(do_auth, fd, message, addr)
		if not ok then
			skynet.error(result)
			result = "400 Bad Request"
		end

		local close = result ~= nil

		if result == nil then
			result = "200 OK"
		end

		socketdriver.send(fd, netpack.pack(result))

		if close then
			gateserver.closeclient(fd)
		end
	end

	local request_handler = assert(conf.request_handler)
	-- 上层业务请求处理函数：形如 function(username, message) return response_string end

	-- u.response is a struct { return_fd , response, version, index }
	-- u.response[session] 的条目结构：
	--   p[1] = return_fd（发送响应时用的 fd，支持在多次请求中切换）
	--   p[2] = response（二进制串，打包好的返回数据，含 ok 标志与 session）
	--   p[3] = version（构建响应时的 u.version，用于检测重放/复用）
	--   p[4] = index（构建响应时的 u.index，用于过期淘汰窗口）
	-- 备注：u.index 用于控制缓存窗口大小（expired_number），允许响应在断线重连后被重投递。
	local function retire_response(u)
		-- 清理过期响应：
		--  - 以 u.index 为“构建时刻”的单调计数，对每个响应记录 p[4] 保存构建时的 index
		--  - 当 index 前进到 2*expired_number 时，滑动窗口：把完成的响应中“过旧”的项移除
		--  - 对仍较新的项将 p[4] 回退 expired_number，随后将 u.index 归一为当前窗口最大值+1
		if u.index >= expired_number * 2 then
			local max = 0
			local response = u.response
			for k,p in pairs(response) do
				if p[1] == nil then
					-- request complete, check expired
					if p[4] < expired_number then
						response[k] = nil
					else
						p[4] = p[4] - expired_number
						if p[4] > max then
							max = p[4]
						end
					end
				end
			end
			u.index = max + 1
		end
	end

	local function do_request(fd, message)
		-- 处理业务请求：
		--  1) 解析 session，检查是否已有记录 p = u.response[session]
		--  2) 若 p 存在且 p[3]==u.version，表示同一连接内的复用/重放：
		--     - 若 p[2] 未生成（上一次还在处理），则判为冲突；否则重投递 p[2]
		--  3) 若 p 不存在：创建 p={ return_fd=fd }，调用上层 request_handler 生成结果（二进制响应 + ok/session）
		--     将结果打包为 p[2]，并记录构建时的 version/index
		--  4) 每次请求后 u.index 自增、根据 p[1] 的最新 fd 发送，最后 retire_response 控制窗口大小
		local u = assert(connection[fd], "invalid fd")
		local session = string.unpack(">I4", message, -4)
		message = message:sub(1,-5)
		local p = u.response[session]
		if p then
			-- session can be reuse in the same connection
			-- 同一连接内允许复用 session：
			--   若记录的 version 等于当前 u.version，说明这是一次重放/复用；
			--   若上一条记录还未生成响应（p[2] == nil），判定冲突（错误）。
			if p[3] == u.version then
				local last = u.response[session]
				u.response[session] = nil
				p = nil
				if last[2] == nil then
					local error_msg = string.format("Conflict session %s", crypt.hexencode(session))
					skynet.error(error_msg)
					error(error_msg)
				end
			end
		end

		if p == nil then
			p = { fd }
			u.response[session] = p
			local ok, result = pcall(request_handler, u.username, message)
			-- NOTICE: YIELD here, socket may close.
			-- 注意：此处可能 yield，期间 fd 可能断开，因此后续发送需基于 p[1] 再检查 connection[fd]
			result = result or ""
			if not ok then
				skynet.error(result)
				result = string.pack(">BI4", 0, session)
			else
				result = result .. string.pack(">BI4", 1, session)
			end

			p[2] = string.pack(">s2",result)
			p[3] = u.version
			p[4] = u.index
		else
			-- update version/index, change return fd.
			-- resend response.
			-- 更新返回 fd 与 version/index，用于重投递缓存响应（断线重连场景）
			p[1] = fd
			p[3] = u.version
			p[4] = u.index
			if p[2] == nil then
				-- already request, but response is not ready
				return
			end
		end
		u.index = u.index + 1
		-- the return fd is p[1] (fd may change by multi request) check connect
		fd = p[1]
		if connection[fd] then
			socketdriver.send(fd, p[2])
		end
		p[1] = nil
		retire_response(u)
	end

	local function request(fd, msg, sz)
		-- 网关入口：解包、调用 do_request（可能 yield），异常时关闭连接
		local message = netpack.tostring(msg, sz)
		local ok, err = pcall(do_request, fd, message)
		-- not atomic, may yield
		if not ok then
			skynet.error(string.format("Invalid package %s : %s", err, message))
			if connection[fd] then
				gateserver.closeclient(fd)
			end
		end
	end

	function handler.message(fd, msg, sz)
		-- 新连接的首包走 auth，之后的包走业务 request
		local addr = handshake[fd]
		if addr then
			auth(fd,addr,msg,sz)
			handshake[fd] = nil
		else
			request(fd, msg, sz)
		end
	end

	return gateserver.start(handler)
end

return server
