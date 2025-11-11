-- 说明：
--  snax.loginserver 实现一个带鉴权的登录服务模板：
--   - 文本行协议（\n 分隔），使用 DH 密钥交换 + HMAC 校验 + DES 加密 token
--   - 角色分离：master（监听入口，分发给 slave）与 slave（实际鉴权流程）
--   - 通过传入 conf = { auth_handler, login_handler, command_handler, host, port, instance, multilogin, name }
--     控制认证、登录回调、外部指令处理、监听参数以及并发实例数。
local skynet = require "skynet"
require "skynet.manager"
local socket = require "skynet.socket"
local crypt = require "skynet.crypt"
local table = table
local string = string
local assert = assert

--[[

Protocol:

	line (\n) based text protocol

	1. Server->Client : base64(8bytes random challenge)
	2. Client->Server : base64(8bytes handshake client key)
	3. Server: Gen a 8bytes handshake server key
	4. Server->Client : base64(DH-Exchange(server key))
	5. Server/Client secret := DH-Secret(client key/server key)
	6. Client->Server : base64(HMAC(challenge, secret))
	7. Client->Server : DES(secret, base64(token))
	8. Server : call auth_handler(token) -> server, uid (A user defined method)
	9. Server : call login_handler(server, uid, secret) ->subid (A user defined method)
	10. Server->Client : 200 base64(subid)

Error Code:
	401 Unauthorized . unauthorized by auth_handler
	403 Forbidden . login_handler failed
	406 Not Acceptable . already in login (disallow multi login)

Success:
	200 base64(subid)
]]

local socket_error = {}
-- 校验 socket 写/读结果：若失败则抛 socket_error 并打印统一错误
local function assert_socket(service, v, fd)
	if v then
		return v
	else
		skynet.error(string.format("%s failed: socket (fd = %d) closed", service, fd))
		error(socket_error)
	end
end

-- 可靠写：带错误包装
local function write(service, fd, text)
	assert_socket(service, socket.write(fd, text), fd)
end

-- 启动 slave：执行握手 + 认证流程
-- Server 侧流程（详见文件头注释）：challenge -> exchange -> secret -> HMAC 校验 -> 解密 token -> auth_handler
local function launch_slave(auth_handler)
	local function auth(fd, addr)
		-- set socket buffer limit (8K)
		-- If the attacker send large package, close the socket
		socket.limit(fd, 8192)

		local challenge = crypt.randomkey()
		write("auth", fd, crypt.base64encode(challenge).."\n")

		-- 1) 客户端握手 key
		local handshake = assert_socket("auth", socket.readline(fd), fd)
		local clientkey = crypt.base64decode(handshake)
		if #clientkey ~= 8 then
			error "Invalid client key"
		end
		-- 2) 生成服务端 key，回发 DH 交换值
		local serverkey = crypt.randomkey()
		write("auth", fd, crypt.base64encode(crypt.dhexchange(serverkey)).."\n")

		-- 3) 计算共享密钥 secret
		local secret = crypt.dhsecret(clientkey, serverkey)

		-- 4) 校验 challenge 的 HMAC 响应
		local response = assert_socket("auth", socket.readline(fd), fd)
		local hmac = crypt.hmac64(challenge, secret)

		if hmac ~= crypt.base64decode(response) then
			error "challenge failed"
		end

		-- 5) 解密 token（DES(secret, base64(token))）
		local etoken = assert_socket("auth", socket.readline(fd),fd)

		local token = crypt.desdecode(secret, crypt.base64decode(etoken))

		local ok, server, uid =  pcall(auth_handler,token)  -- 用户自定义：解析 token，返回 server 与 uid

		return ok, server, uid, secret
	end

	local function ret_pack(ok, err, ...)
		if ok then
			return skynet.pack(err, ...)
		else
			if err == socket_error then
				return skynet.pack(nil, "socket error")
			else
				return skynet.pack(false, err)
			end
		end
	end

	-- 将鉴权过程包装为可返回给 master 的二进制包（skynet.pack）
	local function auth_fd(fd, addr)
		skynet.error(string.format("connect from %s (fd = %d)", addr, fd))
		socket.start(fd)	-- may raise error here
		-- 认证过程中可能抛 socket_error：用 ret_pack 封装后回给 master
		local msg, len = ret_pack(pcall(auth, fd, addr))
		socket.abandon(fd)	-- never raise error here
		return msg, len
	end

	skynet.dispatch("lua", function(_,_,...)
		local ok, msg, len = pcall(auth_fd, ...)
		if ok then
			skynet.ret(msg,len)
		else
			skynet.ret(skynet.pack(false, msg))
		end
	end)
end

-- 记录 uid 是否已登录（当 multilogin=false 时禁止重复登录）
local user_login = {}

-- master 接入处理：
--  1) 调用 slave 鉴权（auth_handler）获得 server, uid, secret
--  2) 根据 multilogin 判重（禁止重复登录）
--  3) 调用 login_handler(server, uid, secret) 返回 subid（返回给客户端）
-- 接入一个客户端连接：
--  1) 将 fd 交给某个 slave 做握手/认证（auth_handler）
--  2) 如果 multilogin=false，使用 user_login 表阻止同一 uid 并发登录，返回 406
--  3) 调用 login_handler(server, uid, secret) 进行业务登录，成功返回 subid（写回 200 base64(subid)）
local function accept(conf, s, fd, addr)
	-- call slave auth
	local ok, server, uid, secret = skynet.call(s, "lua",  fd, addr)
	-- slave will accept(start) fd, so we can write to fd later

	-- 认证失败：按照约定写回 401；ok==nil 表示 rpc 异常（不回 401）
	if not ok then
		if ok ~= nil then
			write("response 401", fd, "401 Unauthorized\n")
		end
		error(server)
	end

	if not conf.multilogin then
		if user_login[uid] then
			write("response 406", fd, "406 Not Acceptable\n")
			error(string.format("User %s is already login", uid))
		end

		user_login[uid] = true
	end

	-- 执行业务登录：返回 subid（可作为后续握手参数），失败返回 403
	local ok, err = pcall(conf.login_handler, server, uid, secret)
	-- unlock login
	user_login[uid] = nil

	if ok then
		err = err or ""
		write("response 200",fd,  "200 "..crypt.base64encode(err).."\n")
	else
		write("response 403",fd,  "403 Forbidden\n")
		error(err)
	end
end

-- 启动 master：监听入口端口，将每个连接分发给一个 slave 完成鉴权与登录
-- 启动 master：
--  - 预创建 conf.instance 个 slave；每次新连接轮询分配一个 slave 做鉴权
--  - master 自身仅负责监听、调度与组装响应（401/403/406/200）
local function launch_master(conf)
	local instance = conf.instance or 8
	assert(instance > 0)
	local host = conf.host or "0.0.0.0"
	local port = assert(tonumber(conf.port))
	local slave = {}
	local balance = 1

	skynet.dispatch("lua", function(_,source,command, ...)
		skynet.ret(skynet.pack(conf.command_handler(command, ...)))
	end)

	-- 预创建 slave 实例，采用简单轮询做负载均衡
	for i=1,instance do
		table.insert(slave, skynet.newservice(SERVICE_NAME))
	end

	skynet.error(string.format("login server listen at : %s %d", host, port))
	local id = socket.listen(host, port)
	-- 主动接入回调：从 slave 池轮询挑一个进行鉴权
	socket.start(id , function(fd, addr)
		local s = slave[balance]
		balance = balance + 1
		if balance > #slave then
			balance = 1
		end
		local ok, err = pcall(accept, conf, s, fd, addr)
		if not ok then
			if err ~= socket_error then
				skynet.error(string.format("invalid client (fd = %d) error = %s", fd, err))
			end
		end
		socket.close(fd)
	end)
end

-- 入口：根据 conf.name 判定是否已存在 master 实例，若存在则作为 slave 运行，否则作为 master 注册并监听
local function login(conf)
	local name = "." .. (conf.name or "login")
	skynet.start(function()
		local loginmaster = skynet.localname(name)
		if loginmaster then
			local auth_handler = assert(conf.auth_handler)
			launch_master = nil
			conf = nil
			launch_slave(auth_handler)
		else
			launch_slave = nil
			conf.auth_handler = nil
			assert(conf.login_handler)
			assert(conf.command_handler)
			skynet.register(name)
			launch_master(conf)
		end
	end)
end

return login
