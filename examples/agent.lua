-- 说明（示例 agent）：
--  - 与 watchdog/gate 模式配套的“会话代理”，绑定一个 client fd，处理协议与业务。
--  - 使用 sproto 作为编解码；通过 host:dispatch 解包客户端请求，通过 send_request 发送响应包。
--  - 绑定完成后（CMD.start），会通过 gate 的 forward 将 client fd 置入“重定向模式”（PTYPE_CLIENT → 本服务）。
local skynet = require "skynet"
local socket = require "skynet.socket"
local sproto = require "sproto"
local sprotoloader = require "sprotoloader"

local WATCHDOG
local host
local send_request

local CMD = {}
local REQUEST = {}
local client_fd

function REQUEST:get()
	-- 业务示例：从 SIMPLEDB 查询键值
	print("get", self.what)
	local r = skynet.call("SIMPLEDB", "lua", "get", self.what)
	return { result = r }
end

function REQUEST:set()
	-- 业务示例：向 SIMPLEDB 写入键值
	print("set", self.what, self.value)
	local r = skynet.call("SIMPLEDB", "lua", "set", self.what, self.value)
end

function REQUEST:handshake()
	-- 客户端握手：发送欢迎消息
	return { msg = "Welcome to skynet, I will send heartbeat every 5 sec." }
end

function REQUEST:quit()
	-- 客户端主动退出：请求 watchdog 断开连接
	skynet.call(WATCHDOG, "lua", "close", client_fd)
end

local function request(name, args, response)
	local f = assert(REQUEST[name])
	local r = f(args)
	if response then
		return response(r)
	end
end

local function send_package(pack)
	local package = string.pack(">s2", pack)
	socket.write(client_fd, package)
end

skynet.register_protocol {
	name = "client",
	id = skynet.PTYPE_CLIENT,
	unpack = function (msg, sz)
		-- 由 sproto host 解析客户端包：返回 type="REQUEST"/"RESPONSE" 及参数
		return host:dispatch(msg, sz)
	end,
	dispatch = function (fd, _, type, ...)
		assert(fd == client_fd)	-- You can use fd to reply message 约束：当前连接 fd
		skynet.ignoreret()	-- session is fd, don't call skynet.ret session 与 fd 绑定，不返回 skynet.ret
		skynet.trace()
		if type == "REQUEST" then
			local ok, result  = pcall(request, ...)
			if ok then
				if result then
					send_package(result)
				end
			else
				skynet.error(result)
			end
		else
			assert(type == "RESPONSE")
			error "This example doesn't support request client"
		end
	end
}

function CMD.start(conf)
	local fd = conf.client
	local gate = conf.gate
	WATCHDOG = conf.watchdog
	-- slot 1,2 set at main.lua 协议槽位：1=请求协议，2=响应协议（由 main.lua 预先放入 sprotoloader）
	host = sprotoloader.load(1):host "package"
	send_request = host:attach(sprotoloader.load(2))
	skynet.fork(function()
		-- 示例：定时发送心跳
		while true do
			send_package(send_request "heartbeat")
			skynet.sleep(500)
		end
	end)

	client_fd = fd
	-- 将 fd 切换为“重定向到本服务”的模式（gate → agent）
	skynet.call(gate, "lua", "forward", fd)
end

function CMD.disconnect()
	-- todo: do something before exit 连接断开：可做资源清理
	skynet.exit()
end

skynet.start(function()
	skynet.dispatch("lua", function(_,_, command, ...)
		skynet.trace()
		local f = CMD[command]
		skynet.ret(skynet.pack(f(...)))
	end)
end)
