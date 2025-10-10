--[[
	Harbor Slave（分布式从节点）

	职责概述：
	- 连接 Master，完成握手并接收拓扑/名字广播（C/N/D）。
	- 监听本节点 address，接受其它 Slave 入站连接，读取对端 Harbor ID。
	- 启动并桥接 C 层 harbor 服务（service-src/service_harbor.c），实现跨节点路由。
	- 作为 Lua 层对外的名字服务入口（.cslave），提供 REGISTER / QUERYNAME / LINK / CONNECT 等接口。

	协议约定（slave <-> master）：
	- 封包：1 字节长度 + packstring 内容（见 read_package/pack_package）。
	- 从 slave 发往 master：
	  H harbor_id, slave_address    -- 握手
	  R name, address               -- 注册全局名
	  Q name                        -- 查询全局名
	- 从 master 发往 slave：
	  W n                           -- 需等待的其它 harbor 数量
	  C id, addr                    -- 新节点连接信息
	  N name, address               -- 名字广播
	  D id                          -- 节点下线
]]

local skynet = require "skynet"
local socket = require "skynet.socket"
local socketdriver = require "skynet.socketdriver"
require "skynet.manager"	-- import skynet.launch, ...
local table = table

-- 远端节点表：harbor_id -> fd
local slaves = {}
-- 启动早期暂存的“待连接”节点，ready() 后会被消化并置 nil
local connect_queue = {}
-- 全局名字缓存：name -> handle（含 harbor 高位）
local globalname = {}
-- 名字查询等待队列：name -> { response() ... }
local queryname = {}
-- 导出给 skynet.harbor 的 Lua 命令集合
local harbor = {}
-- C 层 harbor 服务句柄，用于 redirect 文本命令（PTYPE_HARBOR）
local harbor_service
-- 节点状态等待：id -> { response() ... }
local monitor = {}
-- Master 监控等待集合
local monitor_master_set = {}

-- 读取一帧 master/slave 协议包（1 字节长度 + packstring）
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

-- 唤醒等待某 harbor id 的所有回调（用于连接完成或下线通知清理）
local function monitor_clear(id)
	local v = monitor[id]
	if v then
		monitor[id] = nil
		for _, v in ipairs(v) do
			v(true)
		end
	end
end

-- 主动连接其它 Slave（根据 master 广播或 ready() 阶段触发）
local function connect_slave(slave_id, address)
	local ok, err = pcall(function()
		if slaves[slave_id] == nil then
			local fd = assert(socket.open(address), "Can't connect to "..address)
			socketdriver.nodelay(fd) -- 关闭 Nagle，降低消息延迟
			skynet.error(string.format("Connect to harbor %d (fd=%d), %s", slave_id, fd, address))
			slaves[slave_id] = fd
			monitor_clear(slave_id)  -- 唤醒等待该节点的请求
			socket.abandon(fd)        -- 交给 C 层 harbor 接管该 fd 的收发
			skynet.send(harbor_service, "harbor", string.format("S %d %d",fd,slave_id)) -- 主动连接路径
		end
	end)
	if not ok then
		skynet.error(err)
	end
end

-- 握手完成后进入就绪：
-- 1) 消化 connect_queue 并发起连接
-- 2) 将已知的全局名字同步给 C 层 harbor（用于名字队列派发）
local function ready()
	local queue = connect_queue
	connect_queue = nil
	for k,v in pairs(queue) do
		connect_slave(k,v)
	end
	for name,address in pairs(globalname) do
		skynet.redirect(harbor_service, address, "harbor", 0, "N " .. name) -- 通知 C 层 harbor：name -> handle
	end
end

-- 将已解析的 name -> handle 结果分发给所有等待者
local function response_name(name)
	local address = globalname[name]
	if queryname[name] then
		local tmp = queryname[name]
		queryname[name] = nil
		for _,resp in ipairs(tmp) do
			resp(true, address)
		end
	end
end

-- 监听来自 Master 的广播（C/N/D）与响应（N），保持与 Master 的长期连接
local function monitor_master(master_fd)
	while true do
		local ok, t, id_name, address = pcall(read_package,master_fd)
		if ok then
			if t == 'C' then
				if connect_queue then
					connect_queue[id_name] = address
				else
					connect_slave(id_name, address)
				end
			elseif t == 'N' then
				globalname[id_name] = address
				response_name(id_name)
				if connect_queue == nil then
					skynet.redirect(harbor_service, address, "harbor", 0, "N " .. id_name) -- 同步给 C 层 harbor
				end
			elseif t == 'D' then
				local fd = slaves[id_name]
				slaves[id_name] = false
				if fd then
					monitor_clear(id_name)
					socket.close(fd)
				end
			end
		else
			skynet.error("Master disconnect")
			for _, v in ipairs(monitor_master_set) do
				v(true)
			end
			socket.close(master_fd)
			break
		end
	end
end

-- 接受其它 Slave 入站连接：读取 1 字节对端 harbor_id，交给 C 层 harbor
local function accept_slave(fd)
	socket.start(fd)
	local id = socket.read(fd, 1)
	if not id then
		skynet.error(string.format("Connection (fd =%d) closed", fd))
		socket.close(fd)
		return
	end
	id = string.byte(id)
	if slaves[id] ~= nil then
		skynet.error(string.format("Slave %d exist (fd =%d)", id, fd))
		socket.close(fd)
		return
	end
	slaves[id] = fd
	monitor_clear(id)               -- 唤醒等待该节点
	socket.abandon(fd)              -- 交由 C 层 harbor 接管该 fd
	skynet.error(string.format("Harbor %d connected (fd = %d)", id, fd))
	skynet.send(harbor_service, "harbor", string.format("A %d %d", fd, id)) -- 被动接入路径
end

-- 注册协议：harbor（纯文本透传，用于与 C 层 harbor 的内部控制转发）
skynet.register_protocol {
	name = "harbor",
	id = skynet.PTYPE_HARBOR,
	pack = function(...) return ... end,
	unpack = skynet.tostring,
}

-- 注册协议：text（从 C 层 harbor 发来的文本控制，如 'Q name'、'D id'）
skynet.register_protocol {
	name = "text",
	id = skynet.PTYPE_TEXT,
	pack = function(...) return ... end,
	unpack = skynet.tostring,
}

-- 处理来自 C 层 harbor 的控制文本：
-- 'Q name'：让 .cslave 尝试用本地缓存直接回答；否则发给 master 查询
-- 'D id'  ：标记对应 harbor 下线
local function monitor_harbor(master_fd)
	return function(session, source, command)
		local t = string.sub(command, 1, 1)
		local arg = string.sub(command, 3)
		if t == 'Q' then
			-- query name
			if globalname[arg] then
				skynet.redirect(harbor_service, globalname[arg], "harbor", 0, "N " .. arg)
			else
				socket.write(master_fd, pack_package("Q", arg))
			end
		elseif t == 'D' then
			-- harbor down
			local id = tonumber(arg)
			if slaves[id] then
				monitor_clear(id)
			end
			slaves[id] = false
		else
			skynet.error("Unknown command ", command)
		end
	end
end

-- 注册全局名字：更新本地缓存 -> 回复等待者 -> 通知 master -> 通知 C 层 harbor
function harbor.REGISTER(fd, name, handle)
	assert(globalname[name] == nil)
	globalname[name] = handle
	response_name(name)
	socket.write(fd, pack_package("R", name, handle))
	skynet.redirect(harbor_service, handle, "harbor", 0, "N " .. name)
end

-- 监听某个 harbor 的联通性：若未就绪则挂起等待，连上后由 monitor_clear 唤醒
function harbor.LINK(fd, id)
	if slaves[id] then
		if monitor[id] == nil then
			monitor[id] = {}
		end
		table.insert(monitor[id], skynet.response())
	else
		skynet.ret()
	end
end

function harbor.LINKMASTER()
	table.insert(monitor_master_set, skynet.response())
end

-- 等待与某 harbor 的连接：若尚未连上则挂起等待
function harbor.CONNECT(fd, id)
	if not slaves[id] then
		if monitor[id] == nil then
			monitor[id] = {}
		end
		table.insert(monitor[id], skynet.response())
	else
		skynet.ret()
	end
end

-- 查询名字：'.xxx' 为本地名；全局名命中缓存直接返回，否则发给 master 并挂起等待
function harbor.QUERYNAME(fd, name)
	if name:byte() == 46 then	-- "." , local name
		skynet.ret(skynet.pack(skynet.localname(name)))
		return
	end
	local result = globalname[name]
	if result then
		skynet.ret(skynet.pack(result))
		return
	end
	local queue = queryname[name]
	if queue == nil then
		socket.write(fd, pack_package("Q", name))
		queue = { skynet.response() }
		queryname[name] = queue
	else
		table.insert(queue, skynet.response())
	end
end

skynet.start(function()
	-- 读取分布式配置：Master 地址 / 本 Harbor ID / 本节点监听地址
	local master_addr = skynet.getenv "master"
	local harbor_id = tonumber(skynet.getenv "harbor")
	local slave_address = assert(skynet.getenv "address")
	local slave_fd = socket.listen(slave_address)
	skynet.error("slave connect to master " .. tostring(master_addr))
	local master_fd = assert(socket.open(master_addr), "Can't connect to master")

	-- 绑定 .cslave 的 Lua 命令（REGISTER/QUERYNAME/LINK/CONNECT/...）
	skynet.dispatch("lua", function (_,_,command,...)
		local f = assert(harbor[command])
		f(master_fd, ...)
	end)
	-- 绑定 text 协议处理（来自 C 层 harbor 的控制指令）
	skynet.dispatch("text", monitor_harbor(master_fd))

	-- 启动 C 层 harbor 服务（参数：本 harbor_id 与 .cslave 句柄）
	harbor_service = assert(skynet.launch("harbor", harbor_id, skynet.self()))

	-- 向 Master 发送握手包 'H', harbor_id, address，并读回 'W', n
	local hs_message = pack_package("H", harbor_id, slave_address)
	socket.write(master_fd, hs_message)
	local t, n = read_package(master_fd)
	assert(t == "W" and type(n) == "number", "slave shakehand failed")
	skynet.error(string.format("Waiting for %d harbors", n))
	skynet.fork(monitor_master, master_fd)
	if n > 0 then
		-- 开始监听 address 接受其它 Slave 入站，读 1 字节对端 ID 后通过 “A fd id” 交给 C Harbor
		local co = coroutine.running()
		socket.start(slave_fd, function(fd, addr)
			skynet.error(string.format("New connection (fd = %d, %s)",fd, addr))
			socketdriver.nodelay(fd)
			if pcall(accept_slave,fd) then
				local s = 0
				for k,v in pairs(slaves) do
					s = s + 1
				end
				if s >= n then
					skynet.wakeup(co) -- 接满期望数量，结束监听阶段
				end
			end
		end)
		skynet.wait()
	end
	socket.close(slave_fd)
	skynet.error("Shakehand ready")
	-- 进入就绪：连接待接入节点、同步已知全局名到 C 层 harbor
	skynet.fork(ready)
end)
