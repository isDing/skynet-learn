-- 说明：
--  gate 是通用 TCP 接入服务：
--   - 监听端口并接入客户端
--   - 默认将收到的数据以字符串形态发送给 watchdog（lua 消息）
--   - 通过 CMD.forward 将 fd 绑定到某个 agent，之后数据走 client 协议重定向到 agent
--  流程：
--   1) Watchdog 启动 gate 并设置 conf.watchdog
--   2) 新连接触发 handler.connect → 记录 connection[fd] 并通知 watchdog.socket.open
--   3) 未 forward 前，数据经 handler.message → watchdog.socket.data（字符串），并释放 msg
--   4) 当 watchdog 分配 agent 后，调用 CMD.forward 绑定 {client, agent}
--   5) 此后数据由 handler.message → skynet.redirect(agent, client, "client", fd, msg, sz) 零拷贝转发
--  关键点：
--   - 当未 forward 时，采用 skynet.tostring 拷贝数据并回收 C 层缓冲；一旦 forward，走 client 协议零拷贝转发给 agent
--   - connection[fd].client 用于作为 redirect 的 source，便于 agent 按 PTYPE_CLIENT 分路
--   - CMD.accept 可以将 forward 状态退回（解绑 agent），恢复为字符串上报 watchdog 的模式
local skynet = require "skynet"
local gateserver = require "snax.gateserver"

local watchdog
local connection = {}	-- fd -> connection : { fd , client, agent , ip, mode }

skynet.register_protocol {
	name = "client",
	id = skynet.PTYPE_CLIENT,
}

local handler = {}

function handler.open(source, conf)
	watchdog = conf.watchdog or source
	return conf.address, conf.port
end

function handler.message(fd, msg, sz)
	-- recv a package, forward it
	-- 收到数据包：转发到 agent（若已 forward），否则以字符串通知 watchdog
	local c = connection[fd]
	local agent = c.agent
	if agent then
		-- It's safe to redirect msg directly , gateserver framework will not free msg.
		skynet.redirect(agent, c.client, "client", fd, msg, sz)
	else
		skynet.send(watchdog, "lua", "socket", "data", fd, skynet.tostring(msg, sz))
		-- skynet.tostring will copy msg to a string, so we must free msg here.
		skynet.trash(msg,sz)
	end
end

function handler.connect(fd, addr)
	local c = {
		fd = fd,
		ip = addr,
	}
	connection[fd] = c
	skynet.send(watchdog, "lua", "socket", "open", fd, addr)
end

local function unforward(c)
	if c.agent then
		c.agent = nil
		c.client = nil
	end
end

local function close_fd(fd)
	local c = connection[fd]
	if c then
		unforward(c)
		connection[fd] = nil
	end
end

function handler.disconnect(fd)
	close_fd(fd)
	skynet.send(watchdog, "lua", "socket", "close", fd)
end

function handler.error(fd, msg)
	close_fd(fd)
	skynet.send(watchdog, "lua", "socket", "error", fd, msg)
end

function handler.warning(fd, size)
	skynet.send(watchdog, "lua", "socket", "warning", fd, size)
end

local CMD = {}

function CMD.forward(source, fd, client, address)
	-- 绑定 fd 到某个 agent，并记录 client 源地址（用于重定向）
	local c = assert(connection[fd])
	unforward(c)
	c.client = client or 0
	c.agent = address or source
	gateserver.openclient(fd)
end

function CMD.accept(source, fd)
	-- 将 fd 从转发状态退回，仅作为普通连接开放读取
	local c = assert(connection[fd])
	unforward(c)
	gateserver.openclient(fd)
end

function CMD.kick(source, fd)
	-- 主动断开某个 fd
	gateserver.closeclient(fd)
end

function handler.command(cmd, source, ...)
	local f = assert(CMD[cmd])
	return f(source, ...)
end

gateserver.start(handler)
