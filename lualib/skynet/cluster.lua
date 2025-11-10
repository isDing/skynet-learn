-- 说明：
--  cluster 模块用于跨节点（node）之间的远程调用/发送。
--  通过与唯一服务 clusterd 通讯，建立到目标节点的 sender，并复用它进行 req/push。
--  特点：
--    - 懒建立连接：首次请求时异步获取 sender（排队等待）
--    - 支持 call（有回复）与 send（push，无回复）
--    - 提供 open/reload/proxy/snax 等辅助接口
local skynet = require "skynet"

local clusterd
local cluster = {}
local sender = {}
local task_queue = {}

local function repack(address, ...)
	return address, skynet.pack(...)
end

-- 在后台线程中请求 clusterd 建立到 node 的 sender，期间执行排队任务
local function request_sender(q, node)
	local ok, c = pcall(skynet.call, clusterd, "lua", "sender", node)
	if not ok then
		skynet.error(c)
		c = nil
	end
	-- run tasks in queue
	local confirm = coroutine.running()
	q.confirm = confirm
	q.sender = c
	for _, task in ipairs(q) do
		if type(task) == "string" then
			if c then
				skynet.send(c, "lua", "push", repack(skynet.unpack(task)))
			end
		else
			skynet.wakeup(task)
			skynet.wait(confirm)
		end
	end
	task_queue[node] = nil
	sender[node] = c
end

-- 为某个 node 创建任务队列，并启动 request_sender
local function get_queue(t, node)
	local q = {}
	t[node] = q
	skynet.fork(request_sender, q, node)
	return q
end

setmetatable(task_queue, { __index = get_queue } )

-- 获取已连接的 sender；若尚未建立，当前协程排队等待
local function get_sender(node)
	local s = sender[node]
	if not s then
		local q = task_queue[node]
		local task = coroutine.running()
		table.insert(q, task)
		skynet.wait(task)
		skynet.wakeup(q.confirm)
		return q.sender
	end
	return s
end

cluster.get_sender = get_sender

-- 远程调用：cluster.call("node", ":addr" or ".name", ...)
function cluster.call(node, address, ...)
	-- skynet.pack(...) will free by cluster.core.packrequest
	local s = sender[node]
	if not s then
		local task = skynet.packstring(address, ...)
		return skynet.call(get_sender(node), "lua", "req", repack(skynet.unpack(task)))
	end
	return skynet.call(s, "lua", "req", address, skynet.pack(...))
end

-- 远程发送（无回复）：cluster.send("node", ":addr" or ".name", ...)
function cluster.send(node, address, ...)
	-- push is the same with req, but no response
	local s = sender[node]
	if not s then
		table.insert(task_queue[node], skynet.packstring(address, ...))
	else
		skynet.send(sender[node], "lua", "push", address, skynet.pack(...))
	end
end

-- 在本地打开 cluster 监听（供其他节点连接）
function cluster.open(port, maxclient)
	if type(port) == "string" then
		return skynet.call(clusterd, "lua", "listen", port, nil, maxclient)
	else
		return skynet.call(clusterd, "lua", "listen", "0.0.0.0", port, maxclient)
	end
end

-- 重新加载 cluster 配置（节点地址等）
function cluster.reload(config)
	skynet.call(clusterd, "lua", "reload", config)
end

-- 获取一个到远端节点 node 上 name/addr 的本地代理 handle
function cluster.proxy(node, name)
	return skynet.call(clusterd, "lua", "proxy", node, name)
end

-- 返回远端 snax 服务的绑定对象（post/req）
function cluster.snax(node, name, address)
	local snax = require "skynet.snax"
	if not address then
		address = cluster.call(node, ".service", "QUERY", "snaxd" , name)
	end
	local handle = skynet.call(clusterd, "lua", "proxy", node, address)
	return snax.bind(handle, name)
end

-- 本地注册一个可被 cluster 查询的名字（给远端节点用）
function cluster.register(name, addr)
	assert(type(name) == "string")
	assert(addr == nil or type(addr) == "number")
	return skynet.call(clusterd, "lua", "register", name, addr)
end

-- 取消本地注册名
function cluster.unregister(name)
	assert(type(name) == "string")
	return skynet.call(clusterd, "lua", "unregister", name)
end

-- 在远端节点查询名字对应的地址
function cluster.query(node, name)
	return skynet.call(get_sender(node), "lua", "req", 0, skynet.pack(name))
end

-- 初始化：启动唯一 clusterd 服务
skynet.init(function()
	clusterd = skynet.uniqueservice("clusterd")
end)

return cluster
