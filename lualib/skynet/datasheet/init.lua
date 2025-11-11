-- 说明：
--  datasheet 提供“静态数据表”的共享访问（同属只读共享数据，但以 handle + object 模式管理）。
--  特点：
--   - datasheet_svr（唯一服务）集中管理 handle（版本）
--   - 本地通过 core.new(handle) 构建 object，随后 monitor 得到新 handle 并 core.update
--   - query(name) 对并发做排队，仅首个协程发起 RPC
local skynet = require "skynet"
local service = require "skynet.service"
local core = require "skynet.datasheet.core"

local datasheet_svr

skynet.init(function()
	datasheet_svr = service.query "datasheet"
end)

local datasheet = {}
local sheets = setmetatable({}, {
	__gc = function(t)
		skynet.send(datasheet_svr, "lua", "close")
	end,
})

-- 向 datasheet 服务查询某个表的当前 handle
local function querysheet(name)
	return skynet.call(datasheet_svr, "lua", "query", name)
end

-- 以 handle 构建本地 object，并启动监控协程：
--  - monitor(old_handle) 返回 new_handle（阻塞，直到有新版本）
--  - core.update(object, new_handle) 增量更新
--  - release old_handle 以减少服务端引用
local function updateobject(name)
	local t = sheets[name]
	if not t.object then
		t.object = core.new(t.handle)
	end
	local function monitor()
		local handle = t.handle
		local newhandle = skynet.call(datasheet_svr, "lua", "monitor", handle)
		core.update(t.object, newhandle)
		t.handle = newhandle
		skynet.send(datasheet_svr, "lua", "release", handle)
		return monitor()
	end
	skynet.fork(monitor)
end

-- 查询一个 datasheet：并发排队，首个协程发起 RPC，后续协程复用结果
function datasheet.query(name)
	local t = sheets[name]
	if not t then
		t = {}
		sheets[name] = t
	end
	if t.error then
		error(t.error)
	end
	if t.object then
		return t.object
	end
	if t.queue then
		local co = coroutine.running()
		table.insert(t.queue, co)
		skynet.wait(co)
	else
		t.queue = {}	-- create wait queue for other query
		local ok, handle = pcall(querysheet, name)
		if ok then
			t.handle = handle
			updateobject(name)
		else
			t.error = handle
		end
		local q = t.queue
		t.queue = nil
		for _, co in ipairs(q) do
			skynet.wakeup(co)
		end
	end
	if t.error then
		error(t.error)
	end
	return t.object
end

return datasheet
