-- 说明：
--  提供面向流（TCP）与数据报（UDP）的高层 socket API，封装底层 socketdriver，
--  并与 skynet 的协程机制结合，提供阻塞式 read/accept 等接口（实际通过挂起协程实现）。
local driver = require "skynet.socketdriver"
local skynet = require "skynet"
local skynet_core = require "skynet.core"
local assert = assert

local BUFFER_LIMIT = 128 * 1024
local socket = {}	-- api 导出的 API 表
local socket_pool = setmetatable( -- store all socket object
	{},
	{ __gc = function(p)
		for id,v in pairs(p) do
			driver.close(id)
			p[id] = nil
		end
	end
	}
)

local socket_onclose = {}   -- fd -> onclose 回调（close 后回调）
local socket_message = {}   -- socket 协议的分发表（由 C 层回调触发）

-- 流程总览（TCP）：
-- 1) 连接建立：
--    - 主动 socket.open → connect(id) → suspend 等待 → socket_message[2] 触发 → s.connected=true → 唤醒
--    - 监听 socket.listen → suspend 等待 → socket_message[2] 中 listen 分支赋 s.addr/s.port → 唤醒
-- 2) 数据到达：socket_message[1]
--    - push 数据入缓冲 → 根据 read_required 判断是否满足 → 唤醒读协程（wakeup）
--    - 超过 BUFFER_LIMIT 触发 pause_socket 暂停读，待协程切换/消费后 resume
-- 3) 错误/关闭：socket_message[5]/[3]
--    - ERROR：记录 connecting 错误/标记 connected=false，shutdown 并唤醒等待者
--    - CLOSE：回调 onclose（若有）并唤醒等待者
-- 4) 写入：socket.write/socket.lwrite 直接调用底层 driver 发送
-- 5) 所有权让渡：socket.abandon 将 fd 移交他服，由新服务 socket.start(id) 接管

-- 读状态机要点（read_required 的不同取值）：
--  - nil    ：无等待者；收到数据仅入缓冲，若超限触发 pause
--  - 0      ：任意数据即可唤醒（用于 block / read(nil) 等）
--  - number ：需要累计到指定字节数才唤醒（用于 read(sz)）
--  - string ：行分隔符，driver.readline(buffer, pool, sep) 返回非 nil 时唤醒（用于 readline）
--  - true   ：读取到连接关闭（CLOSE）后唤醒（用于 readall）
-- 返回值约定：
--  - 读取成功：返回字符串数据
--  - 连接关闭：返回 false, 剩余缓冲（可能为空串）
-- 背压策略：
--  - driver.push 返回的缓冲大小超过 BUFFER_LIMIT 即 pause_socket（暂停底层读），
--    待上层协程切换/读取后，在 suspend 中 driver.start 恢复

local function wakeup(s)
	local co = s.co
	if co then
		s.co = nil
		skynet.wakeup(co)
	end
end

local function pause_socket(s, size)
	-- 当缓冲区过大或上层处理过慢时，临时暂停底层 fd 的读
	if s.pause ~= nil then
		return
	end
	if size then
		skynet.error(string.format("Pause socket (%d) size : %d" , s.id, size))
	else
		skynet.error(string.format("Pause socket (%d)" , s.id))
	end
	driver.pause(s.id)
	s.pause = true
	skynet.yield()	-- there are subsequent socket messages in mqueue, maybe.
end

local function suspend(s)
	-- 将当前协程挂起到 s.co，并根据 s.pause 状态决定是否恢复底层读取
	assert(not s.co)
	s.co = coroutine.running()
	if s.pause then
		skynet.error(string.format("Resume socket (%d)", s.id))
		driver.start(s.id)
		skynet.wait(s.co)
		s.pause = nil
	else
		skynet.wait(s.co)
	end
	-- wakeup closing corouting every time suspend,
	-- because socket.close() will wait last socket buffer operation before clear the buffer.
	if s.closing then
		skynet.wakeup(s.closing)
	end
end

-- read skynet_socket.h for these macro
-- SKYNET_SOCKET_TYPE_DATA = 1
socket_message[1] = function(id, size, data)
	-- 数据到达：推入 buffer，根据 read_required 类型（number 行为、string 行分隔、true 读到 EOF、0 任意数据）决定是否唤醒
	local s = socket_pool[id]
	if s == nil then
		skynet.error("socket: drop package from " .. id)
		driver.drop(data, size)
		return
	end

	local sz = driver.push(s.buffer, s.pool, data, size)
	local rr = s.read_required
	local rrt = type(rr)
	if rrt == "number" then
		-- read size
		if sz >= rr then
			s.read_required = nil
			if sz > BUFFER_LIMIT then
				pause_socket(s, sz)
			end
			wakeup(s)
		end
	else
		if s.buffer_limit and sz > s.buffer_limit then
			skynet.error(string.format("socket buffer overflow: fd=%d size=%d", id , sz))
			driver.close(id)
			return
		end
		if rrt == "string" then
			-- read line
			if driver.readline(s.buffer,nil,rr) then
				s.read_required = nil
				if sz > BUFFER_LIMIT then
					pause_socket(s, sz)
				end
				wakeup(s)
			end
		elseif sz > BUFFER_LIMIT and not s.pause then
			pause_socket(s, sz)
		end
	end
end

-- SKYNET_SOCKET_TYPE_CONNECT = 2
socket_message[2] = function(id, ud , addr)
	-- 连接建立：对于监听 socket，ud/addr 会带回监听到的本地地址与端口
	local s = socket_pool[id]
	if s == nil then
		return
	end
	-- log remote addr
	if not s.connected then	-- resume may also post connect message
		if s.listen then
			s.addr = addr
			s.port = ud
		end
		s.connected = true
		wakeup(s)
	end
end

-- SKYNET_SOCKET_TYPE_CLOSE = 3
socket_message[3] = function(id)
	-- 连接关闭：唤醒等待的协程，并触发 onclose 回调
	local s = socket_pool[id]
	if s then
		s.connected = false
		wakeup(s)
	else
		driver.close(id)
	end
	local cb = socket_onclose[id]
	if cb then
		cb(id)
		socket_onclose[id] = nil
	end
end

-- SKYNET_SOCKET_TYPE_ACCEPT = 4
socket_message[4] = function(id, newid, addr)
	-- 接受新连接：将新 fd 交给上层回调处理（一般配合 socket.start 使用）
	local s = socket_pool[id]
	if s == nil then
		driver.close(newid)
		return
	end
	s.callback(newid, addr)
end

-- SKYNET_SOCKET_TYPE_ERROR = 5
socket_message[5] = function(id, _, err)
	-- 错误：关闭写端，唤醒等待，并记录错误信息
	local s = socket_pool[id]
	if s == nil then
		driver.shutdown(id)
		skynet.error("socket: error on unknown", id, err)
		return
	end
	if s.callback then
		skynet.error("socket: accept error:", err)
		return
	end
	if s.connected then
		skynet.error("socket: error on", id, err)
	elseif s.connecting then
		s.connecting = err
	end
	s.connected = false
	driver.shutdown(id)

	wakeup(s)
end

-- SKYNET_SOCKET_TYPE_UDP = 6
socket_message[6] = function(id, size, data, address)
	-- UDP 数据：直接回调到上层 callback
	local s = socket_pool[id]
	if s == nil or s.callback == nil then
		skynet.error("socket: drop udp package from " .. id)
		driver.drop(data, size)
		return
	end
	local str = skynet.tostring(data, size)
	skynet_core.trash(data, size)
	s.callback(str, address)
end

local function default_warning(id, size)
	local s = socket_pool[id]
	if not s then
		return
	end
	skynet.error(string.format("WARNING: %d K bytes need to send out (fd = %d)", size, id))
end

-- SKYNET_SOCKET_TYPE_WARNING
socket_message[7] = function(id, size)
	local s = socket_pool[id]
	if s then
		local warning = s.on_warning or default_warning
		warning(id, size)
	end
end

skynet.register_protocol {
	name = "socket",
	id = skynet.PTYPE_SOCKET,	-- PTYPE_SOCKET = 6
	unpack = driver.unpack,
	dispatch = function (_, _, t, ...)
		socket_message[t](...)
	end
}

local function connect(id, func)
	-- 将一个 fd 封装为 socket 对象：func 存在则为 accept/回调式，nil 则创建缓冲区用于主动连接
	local newbuffer
	if func == nil then
		newbuffer = driver.buffer()
	end
	local s = {
		id = id,
		buffer = newbuffer,
		pool = newbuffer and {},
		connected = false,
		connecting = true,
		read_required = false,
		co = false,
		callback = func,
		protocol = "TCP",
	}
	assert(not socket_onclose[id], "socket has onclose callback")
	local s2 = socket_pool[id]
	if s2 and not s2.listen then
		error("socket is not closed")
	end
	socket_pool[id] = s
	suspend(s)
	local err = s.connecting
	s.connecting = nil
	if s.connected then
		return id
	else
		socket_pool[id] = nil
		return nil, err
	end
end

function socket.open(addr, port)
	-- 主动连接 TCP 服务
	local id = driver.connect(addr,port)
	return connect(id)
end

function socket.bind(os_fd)
	local id = driver.bind(os_fd)
	return connect(id)
end

function socket.stdin()
	-- 将标准输入 0 号 fd 封装为 socket
	return socket.bind(0)
end

function socket.start(id, func)
	-- 启动监听 fd 的接收，func 接收 (newfd, addr) 回调
	driver.start(id)
	return connect(id, func)
end

function socket.pause(id)
	-- 暂停读取，通常用于上游处理过慢的反压
	local s = socket_pool[id]
	if s == nil then
		return
	end
	pause_socket(s)
end

function socket.shutdown(id)
	-- 半关闭（发送缓冲清空后再 close），等待 CLOSE 事件来清理资源
	local s = socket_pool[id]
	if s then
		-- the framework would send SKYNET_SOCKET_TYPE_CLOSE , need close(id) later
		driver.shutdown(id)
	end
end

function socket.close_fd(id)
	assert(socket_pool[id] == nil,"Use socket.close instead")
	driver.close(id)
end

function socket.close(id)
	-- 关闭连接：若有读取协程则等待其读取缓冲区并唤醒
	local s = socket_pool[id]
	if s == nil then
		return
	end
	driver.close(id)
	if s.connected then
		s.pause = false -- Do not resume this fd if it paused.
		if s.co then
			-- reading this socket on another coroutine, so don't shutdown (clear the buffer) immediately
			-- wait reading coroutine read the buffer.
			assert(not s.closing)
			s.closing = coroutine.running()
			skynet.wait(s.closing)
		else
			suspend(s)
		end
		s.connected = false
	end
	socket_pool[id] = nil
end

function socket.read(id, sz)
	-- 读取 sz 字节；若 sz 为空，则尽量读出当前缓冲区
	local s = socket_pool[id]
	assert(s)
	if sz == nil then
		-- read some bytes
		local ret = driver.readall(s.buffer, s.pool)
		if ret ~= "" then
			return ret
		end

		if not s.connected then
			return false, ret
		end
		assert(not s.read_required)
		s.read_required = 0
		suspend(s)
		ret = driver.readall(s.buffer, s.pool)
		if ret ~= "" then
			return ret
		else
			return false, ret
		end
	end

	local ret = driver.pop(s.buffer, s.pool, sz)
	if ret then
		return ret
	end
	if s.closing or not s.connected then
		return false, driver.readall(s.buffer, s.pool)
	end

	assert(not s.read_required)
	s.read_required = sz
	suspend(s)
	ret = driver.pop(s.buffer, s.pool, sz)
	if ret then
		return ret
	else
		return false, driver.readall(s.buffer, s.pool)
	end
end

function socket.readall(id)
	-- 读取直至连接关闭，返回已收集的数据；若已关闭且无数据返回 nil
	local s = socket_pool[id]
	assert(s)
	if not s.connected then
		local r = driver.readall(s.buffer, s.pool)
		return r ~= "" and r
	end
	assert(not s.read_required)
	s.read_required = true
	suspend(s)
	assert(s.connected == false)
	return driver.readall(s.buffer, s.pool)
end

function socket.readline(id, sep)
	-- 读取一行（以分隔符 sep 结尾，默认 \n）
	sep = sep or "\n"
	local s = socket_pool[id]
	assert(s)
	local ret = driver.readline(s.buffer, s.pool, sep)
	if ret then
		return ret
	end
	if not s.connected then
		return false, driver.readall(s.buffer, s.pool)
	end
	assert(not s.read_required)
	s.read_required = sep
	suspend(s)
	if s.connected then
		return driver.readline(s.buffer, s.pool, sep)
	else
		return false, driver.readall(s.buffer, s.pool)
	end
end

function socket.block(id)
	-- 阻塞直到至少有数据（read_required=0），返回连接是否仍然有效
	local s = socket_pool[id]
	if not s or not s.connected then
		return false
	end
	assert(not s.read_required)
	s.read_required = 0
	suspend(s)
	return s.connected
end

socket.write = assert(driver.send)
socket.lwrite = assert(driver.lsend)
socket.header = assert(driver.header)

function socket.invalid(id)
	return socket_pool[id] == nil
end

function socket.disconnected(id)
	local s = socket_pool[id]
	if s then
		return not(s.connected or s.connecting)
	end
end

function socket.listen(host, port, backlog)
	if port == nil then
		host, port = string.match(host, "([^:]+):(.+)$")
		port = tonumber(port)
	end
	local id = driver.listen(host, port, backlog)
	local s = {
		id = id,
		connected = false,
		listen = true,
	}
	assert(socket_pool[id] == nil)
	socket_pool[id] = s
	suspend(s)
	return id, s.addr, s.port
end

-- abandon use to forward socket id to other service
-- you must call socket.start(id) later in other service
-- 将一个 fd 的所有权让渡到其他服务：
--  - 典型用于 gate/agent 之间转移连接所有权的场景
--  - 放弃后本服务不再持有该 fd 的 socket 对象，需要在新服务中调用 socket.start(id)
function socket.abandon(id)
	local s = socket_pool[id]
	if s then
		s.connected = false
		wakeup(s)
		socket_onclose[id] = nil
		socket_pool[id] = nil
	end
end

function socket.limit(id, limit)
	local s = assert(socket_pool[id])
	s.buffer_limit = limit
end

---------------------- UDP

local function create_udp_object(id, cb)
	assert(not socket_pool[id], "socket is not closed")
	socket_pool[id] = {
		id = id,
		connected = true,
		protocol = "UDP",
		callback = cb,
	}
end

function socket.udp(callback, host, port)
	local id = driver.udp(host, port)
	create_udp_object(id, callback)
	return id
end

function socket.udp_connect(id, addr, port, callback)
	local obj = socket_pool[id]
	if obj then
		assert(obj.protocol == "UDP")
		if callback then
			obj.callback = callback
		end
	else
		create_udp_object(id, callback)
	end
	driver.udp_connect(id, addr, port)
end

function socket.udp_listen(addr, port, callback)
	local id = driver.udp_listen(addr, port)
	create_udp_object(id, callback)
	return id
end

function socket.udp_dial(addr, port, callback)
	local id = driver.udp_dial(addr, port)
	create_udp_object(id, callback)
	return id
end

-- UDP 发送接口（注意 UDP 不支持 socket.write）：
--  - sendto(id, addr, data) 发送数据，其中 addr 可通过 udp_address(host,port) 构造
--  - 若已调用 udp_connect 设置默认地址，addr 仍需显式传入
socket.sendto = assert(driver.udp_send)
socket.udp_address = assert(driver.udp_address)
socket.netstat = assert(driver.info)
socket.resolve = assert(driver.resolve)

function socket.warning(id, callback)
    -- 注册发送队列积压回调：
    --  - 当底层发现写缓冲积压时，会回调 on_warning(id, sizeK)
    --  - 可用于触发限流/断连保护
	local obj = socket_pool[id]
	assert(obj)
	obj.on_warning = callback
end

function socket.onclose(id, callback)
    -- 注册连接关闭回调：当 SOCKET_TYPE_CLOSE 触发时回调
	socket_onclose[id] = callback
end

return socket
