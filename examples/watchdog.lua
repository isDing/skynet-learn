-- 说明：
--  watchdog 示例：
--   - 作为网关连接的“连接管理器”，负责为每个新连接创建/绑定一个 agent，并在断连/异常时清理。
--   - gate 收到的数据在未 forward 前会以字符串形态上报到本服务；在 forward 后，数据经 client 协议零拷贝转发到 agent。
--   - 典型流程：SOCKET.open → 创建 agent 并调用 agent.start 绑定 fd → 后续 socket 事件（close/error/warning）回收资源。
local skynet = require "skynet"

local CMD = {}
local SOCKET = {}
local gate
local agent = {}

function SOCKET.open(fd, addr)
	-- 新连接到来：创建对应的 agent，并通过 agent.start 绑定 gate/client/watchdog 信息
	skynet.error("New client from : " .. addr)
	agent[fd] = skynet.newservice("agent")
	skynet.call(agent[fd], "lua", "start", { gate = gate, client = fd, watchdog = skynet.self() })
end

local function close_agent(fd)
	local a = agent[fd]
	agent[fd] = nil
	if a then
		skynet.call(gate, "lua", "kick", fd)
		-- disconnect never return
		skynet.send(a, "lua", "disconnect")
	end
end

function SOCKET.close(fd)
	print("socket close",fd)
	close_agent(fd)
end

function SOCKET.error(fd, msg)
	print("socket error",fd, msg)
	close_agent(fd)
end

function SOCKET.warning(fd, size)
	-- size K bytes havn't send out in fd 发送缓冲区积压：size 为 KB（近似值）。可在此做限流或踢出“慢客户端”。
	print("socket warning", fd, size)
end

function SOCKET.data(fd, msg)
end

function CMD.start(conf)
	-- 由外部（main）调用打开 gate：conf 包含 port/maxclient/nodelay 等
	return skynet.call(gate, "lua", "open" , conf)
end

function CMD.close(fd)
	close_agent(fd)
end

skynet.start(function()
	skynet.dispatch("lua", function(session, source, cmd, subcmd, ...)
		if cmd == "socket" then
			local f = SOCKET[subcmd]
			f(...)
			-- socket api don't need return
		else
			local f = assert(CMD[cmd])
			skynet.ret(skynet.pack(f(subcmd, ...)))
		end
	end)

	-- 创建通用 gate 服务：
	--  - gate 会回调本服务的 SOCKET.* 事件
	gate = skynet.newservice("gate")
end)
