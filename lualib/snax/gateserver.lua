-- 说明：
--  Gateserver 是一个通用的 TCP 网关框架：监听端口、接入客户端、收发消息、
--  并将网络事件转交给上层 handler 处理（connect/message/disconnect 等）。
--  依赖 skynet.netpack 做半包/粘包处理；依赖 skynet.socketdriver 进行底层收发。
local skynet = require "skynet"
local netpack = require "skynet.netpack"
local socketdriver = require "skynet.socketdriver"

local gateserver = {}

local socket	-- 监听 socket fd（server socket）
local queue		-- socket 协议返回的消息队列（由 netpack.filter 维护）
local maxclient	-- 最大客户端连接数
local client_number = 0
local CMD = setmetatable({}, { __gc = function() netpack.clear(queue) end })
local nodelay = false

local connection = {}   -- 记录 fd 的连接状态
-- true : connected
-- nil : closed
-- false : close read
-- true : 已连接且读写正常
-- nil  : 已关闭
-- false: 只关闭读（收到 close 事件，等待发送缓冲清空）

function gateserver.openclient(fd)
	-- 允许某个已存在记录的 fd 进入“收消息”状态
	if connection[fd] then
		socketdriver.start(fd)
	end
end

function gateserver.closeclient(fd)
	-- 主动关闭某个客户端连接
	local c = connection[fd]
	if c ~= nil then
		connection[fd] = nil
		socketdriver.close(fd)
	end
end

function gateserver.start(handler)
	-- 启动 gateserver，并将网络事件转发给 handler：
	--   必须实现：handler.message(fd, msg, sz), handler.connect(fd, msg)
	--   可选实现：handler.open/close/disconnect/error/warning/command/embed
	assert(handler.message)
	assert(handler.connect)

	local listen_context = {}

	function CMD.open( source, conf )
		-- 监听端口，并等待底层返回实际监听地址（IPv6/随机端口等场景）
		assert(not socket)
		local address = conf.address or "0.0.0.0"
		local port = assert(conf.port)
		maxclient = conf.maxclient or 1024
		nodelay = conf.nodelay
		skynet.error(string.format("Listen on %s:%d", address, port))
		socket = socketdriver.listen(address, port, conf.backlog)
		listen_context.co = coroutine.running()
		listen_context.fd = socket
		skynet.wait(listen_context.co)
		conf.address = listen_context.addr
		conf.port = listen_context.port
		listen_context = nil
		socketdriver.start(socket)
		if handler.open then
			return handler.open(source, conf)
		end
	end

	function CMD.close()
		assert(socket)
		socketdriver.close(socket)
	end

	local MSG = {}

	local function dispatch_msg(fd, msg, sz)
		-- 将数据包转给上层 handler.message，若 fd 状态已无效则丢弃并打印日志
		if connection[fd] then
			handler.message(fd, msg, sz)
		else
			skynet.error(string.format("Drop message from fd (%d) : %s", fd, netpack.tostring(msg,sz)))
		end
	end

	MSG.data = dispatch_msg

	local function dispatch_queue()
		-- 从 netpack 队列批量弹出数据并分发（避免 handler.block 导致收包阻塞）
		local fd, msg, sz = netpack.pop(queue)
		if fd then
			-- may dispatch even the handler.message blocked
			-- If the handler.message never block, the queue should be empty, so only fork once and then exit.
			skynet.fork(dispatch_queue)
			dispatch_msg(fd, msg, sz)

			for fd, msg, sz in netpack.pop, queue do
				dispatch_msg(fd, msg, sz)
			end
		end
	end

	MSG.more = dispatch_queue

	function MSG.open(fd, msg)
		-- 新连接建立，若超过上限则直接 shutdown
		client_number = client_number + 1
		if client_number >= maxclient then
			socketdriver.shutdown(fd)
			return
		end
		if nodelay then
			socketdriver.nodelay(fd)
		end
		connection[fd] = true
		handler.connect(fd, msg)
	end

	function MSG.close(fd)
		-- 连接关闭事件：更新状态并调用 handler.disconnect
		if fd ~= socket then
			client_number = client_number - 1
			if connection[fd] then
				connection[fd] = false	-- close read
			end
			if handler.disconnect then
				handler.disconnect(fd)
			end
		else
			socket = nil
		end
	end

	function MSG.error(fd, msg)
		-- 监听失败或客户端错误：监听失败直接打印，客户端错误执行 shutdown
		if fd == socket then
			skynet.error("gateserver accept error:",msg)
		else
			socketdriver.shutdown(fd)
			if handler.error then
				handler.error(fd, msg)
			end
		end
	end

	function MSG.warning(fd, size)
		-- 发送队列积压通知（由 socketdriver 触发）
		if handler.warning then
			handler.warning(fd, size)
		end
	end

	function MSG.init(id, addr, port)
		if listen_context then
			local co = listen_context.co
			if co then
				assert(id == listen_context.fd)
				listen_context.addr = addr
				listen_context.port = port
				skynet.wakeup(co)
				listen_context.co = nil
			end
		end
	end

	skynet.register_protocol {
		name = "socket",
		id = skynet.PTYPE_SOCKET,	-- PTYPE_SOCKET = 6
		unpack = function ( msg, sz )
			-- 由 netpack.filter 进行消息重组，将半包拼接，粘包拆分，最终输出 (queue, type, ...)
			return netpack.filter( queue, msg, sz)
		end,
		dispatch = function (_, _, q, type, ...)
			queue = q
			if type then
				MSG[type](...)
			end
		end
	}

	local function init()
		-- 注册 lua 协议的命令处理：优先处理 gateserver 内置 CMD，其次交给上层 handler.command
		skynet.dispatch("lua", function (_, address, cmd, ...)
			local f = CMD[cmd]
			if f then
				skynet.ret(skynet.pack(f(address, ...)))
			else
				skynet.ret(skynet.pack(handler.command(cmd, address, ...)))
			end
		end)
	end

	if handler.embed then
		-- 以内嵌模式运行（无需 skynet.start）
		init()
	else
		-- 标准模式：注册回调并进入事件循环
		skynet.start(init)
	end
end

return gateserver
