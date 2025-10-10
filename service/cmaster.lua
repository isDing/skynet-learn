--[[
	Harbor Master（分布式主节点）

	职责概述：
	- 维护系统拓扑（slave_id -> address）与全局名字表（name -> handle）。
	- 接收来自各个 Slave 的请求（H/R/Q），并向所有 Slave 广播必要的拓扑/名字变更（W/C/N/D）。
	- 长连接模型：Master 持有所有 Slave 的连接，Slave 也与 Master 保持连接。

	协议（与 Slave 的双向消息）：
	- 封包：1 字节长度 + packstring 内容（read_package/pack_package）。
	- Slave -> Master：
	  H id, addr    握手（上报自身 id 与监听地址）
	  R name, addr  注册全局名字（name -> address）
	  Q name        查询 name
	- Master -> Slave：
	  W n           返回当前需要等待的其它 harbor 数量（用于 Slave 监听接入）
	  C id, addr    广播新节点信息
	  N name, addr  广播名字表更新
	  D id          广播节点下线
]]

local skynet = require "skynet"
local socket = require "skynet.socket"

--[[
	master manage data :
		1. all the slaves address : id -> ipaddr:port
		2. all the global names : name -> address

	master hold connections from slaves .

	protocol slave->master :
		package size 1 byte
		type 1 byte :
			'H' : HANDSHAKE, report slave id, and address.
			'R' : REGISTER name address
			'Q' : QUERY name


	protocol master->slave:
		package size 1 byte
		type 1 byte :
			'W' : WAIT n
			'C' : CONNECT slave_id slave_address
			'N' : NAME globalname address
			'D' : DISCONNECT slave_id
]]

local slave_node = {}
local global_name = {}

-- 读取一帧（1 字节长度 + packstring），返回 unpack 后的多值
local function read_package(fd)
	local sz = socket.read(fd, 1)
	assert(sz, "closed")
	sz = string.byte(sz)
	local content = assert(socket.read(fd, sz), "closed")
	return skynet.unpack(content)
end

-- 打包一帧（限制单帧 <= 255 字节）
local function pack_package(...)
	local message = skynet.packstring(...)
	local size = #message
	assert(size <= 255 , "too long")
	return string.char(size) .. message
end

-- 新上线的 slave：
-- 1) 广播给所有在线节点（C id addr）
-- 2) 回给当前 fd 一个 'W n'，告知需要等待的其它 harbor 数量
local function report_slave(fd, slave_id, slave_addr)
	local message = pack_package("C", slave_id, slave_addr)
	local n = 0
	for k,v in pairs(slave_node) do
		if v.fd ~= 0 then
			socket.write(v.fd, message)
			n = n + 1
		end
	end
	socket.write(fd, pack_package("W", n))
end

-- 握手：读取 'H id addr'，校验重复；广播拓扑并记录节点信息
local function handshake(fd)
	local t, slave_id, slave_addr = read_package(fd)
	assert(t=='H', "Invalid handshake type " .. t)
	assert(slave_id ~= 0 , "Invalid slave id 0")
	if slave_node[slave_id] then
		error(string.format("Slave %d already register on %s", slave_id, slave_node[slave_id].addr))
	end
	report_slave(fd, slave_id, slave_addr)
	slave_node[slave_id] = {
		fd = fd,
		id = slave_id,
		addr = slave_addr,
	}
	return slave_id , slave_addr
end

-- 处理来自某个 slave 的业务请求：R（注册全局名）/Q（查询名字）
local function dispatch_slave(fd)
	local t, name, address = read_package(fd)
	if t == 'R' then
		-- register name
		assert(type(address)=="number", "Invalid request")
		if not global_name[name] then
			global_name[name] = address
		end
		local message = pack_package("N", name, address)
		for k,v in pairs(slave_node) do
			socket.write(v.fd, message)
		end
	elseif t == 'Q' then
		-- query name
		local address = global_name[name]
		if address then
			socket.write(fd, pack_package("N", name, address))
		end
	else
		skynet.error("Invalid slave message type " .. t)
	end
end

-- 监控某个 slave：循环处理其 R/Q；断连后广播 'D id' 并清理记录
local function monitor_slave(slave_id, slave_address)
	local fd = slave_node[slave_id].fd
	skynet.error(string.format("Harbor %d (fd=%d) report %s", slave_id, fd, slave_address))
	while pcall(dispatch_slave, fd) do end
	skynet.error("slave " ..slave_id .. " is down")
	local message = pack_package("D", slave_id)
	slave_node[slave_id].fd = 0
	for k,v in pairs(slave_node) do
		socket.write(v.fd, message)
	end
	socket.close(fd)
end

skynet.start(function()
	local master_addr = skynet.getenv "standalone"
	skynet.error("master listen socket " .. tostring(master_addr))
	local fd = socket.listen(master_addr)
	-- 接受来自各个 slave 的连接：完成握手并 fork 监控协程
	socket.start(fd , function(id, addr)
		skynet.error("connect from " .. addr .. " " .. id)
		socket.start(id)
		local ok, slave, slave_addr = pcall(handshake, id)
		if ok then
			skynet.fork(monitor_slave, slave, slave_addr)
		else
			skynet.error(string.format("disconnect fd = %d, error = %s", id, slave))
			socket.close(id)
		end
	end)
end)
