-- 说明：
--  sharedatad 统一管理 sharedata 的多版本对象：
--   - new/delete/query/confirm/update/monitor
--   - 通过 host.incref/decref 控制对象生命周期
--   - 支持热更新：update 生成新版本，并通过 monitor 通知订阅者
local skynet = require "skynet"
local sharedata = require "skynet.sharedata.corelib"
local table = table
local cache = require "skynet.codecache"
cache.mode "OFF"	-- turn off codecache, because CMD.new may load data file

local NORET = {}
local pool = {}
local pool_count = {}
local objmap = {}
local collect_tick = 10

-- 创建一个新的共享对象版本
local function newobj(name, tbl)
	assert(pool[name] == nil)
	local cobj = sharedata.host.new(tbl)
	sharedata.host.incref(cobj)
	local v = {obj = cobj, watch = {} }
	objmap[cobj] = v
	pool[name] = v
	pool_count[name] = { n = 0, threshold = 16 }
end

-- 触发 1 分钟后的垃圾回收周期加速
local function collect1min()
	if collect_tick > 1 then
		collect_tick = 1
	end
end

-- 后台 GC：每分钟检查一次，累计 10 分钟触发一次全面回收
local function collectobj()
	while true do
		skynet.sleep(60*100)	-- sleep 1min
		if collect_tick <= 0 then
			collect_tick = 10	-- reset tick count to 10 min
			collectgarbage()
			for obj, v in pairs(objmap) do
				if v == true then
					if sharedata.host.getref(obj) <= 0  then
						objmap[obj] = nil
						sharedata.host.delete(obj)
					end
				end
			end
		else
			collect_tick = collect_tick - 1
		end
	end
end

local CMD = {}

local env_mt = { __index = _ENV }

-- 新建对象：支持 table / string(加载文件或 chunk) / nil
function CMD.new(name, t, ...)
	local dt = type(t)
	local value
	if dt == "table" then
		value = t
	elseif dt == "string" then
		value = setmetatable({}, env_mt)
		local f
		if t:sub(1,1) == "@" then
			f = assert(loadfile(t:sub(2),"bt",value))
		else
			f = assert(load(t, "=" .. name, "bt", value))
		end
		local _, ret = assert(skynet.pcall(f, ...))
		setmetatable(value, nil)
		if type(ret) == "table" then
			value = ret
		end
	elseif dt == "nil" then
		value = {}
	else
		error ("Unknown data type " .. dt)
	end
	newobj(name, value)
end

-- 删除对象：将对象标记为待回收，并唤醒监控者（返回 true）
function CMD.delete(name)
	local v = assert(pool[name])
	pool[name] = nil
	pool_count[name] = nil
	assert(objmap[v.obj])
	objmap[v.obj] = true
	sharedata.host.decref(v.obj)
	for _,response in pairs(v.watch) do
		response(true)
	end
end

-- 查询对象：增加引用计数并返回 C 对象指针
function CMD.query(name)
	local v = assert(pool[name], name)
	local obj = v.obj
	sharedata.host.incref(obj)
	return v.obj
end

-- 客户端确认已使用完该对象指针（减少引用计数）
-- 客户端确认：减少 C 对象的引用计数（与 CMD.query/monitor 成对）
function CMD.confirm(cobj)
	if objmap[cobj] then
		sharedata.host.decref(cobj)
	end
	return NORET
end

-- 更新对象：生成新版本，并通知所有监控协程（monitor）
function CMD.update(name, t, ...)
	local v = pool[name]
	local watch, oldcobj
	if v then
		watch = v.watch
		oldcobj = v.obj
		objmap[oldcobj] = true
		sharedata.host.decref(oldcobj)
		pool[name] = nil
		pool_count[name] = nil
	end
	CMD.new(name, t, ...)
	local newobj = pool[name].obj
	if watch then
		sharedata.host.markdirty(oldcobj)
		for _,response in pairs(watch) do
			sharedata.host.incref(newobj)
			response(true, newobj)
		end
	end
	collect1min()	-- collect in 1 min
end

-- 清理已失效的监控 response 闭包
local function check_watch(queue)
	local n = 0
	for k,response in pairs(queue) do
		if not response "TEST" then
			queue[k] = nil
			n = n + 1
		end
	end
	return n
end

-- 订阅对象变更：若 obj 不是最新则立即返回新对象，否则挂起等待 update 通知
function CMD.monitor(name, obj)
	local v = assert(pool[name])
	if obj ~= v.obj then
		sharedata.host.incref(v.obj)
		return v.obj
	end

	local n = pool_count[name].n + 1
	if n > pool_count[name].threshold then
		n = n - check_watch(v.watch)
		pool_count[name].threshold = n * 2
	end
	pool_count[name].n = n

	table.insert(v.watch, skynet.response())

	return NORET
end

skynet.start(function()
	skynet.fork(collectobj)
	skynet.dispatch("lua", function (session, source ,cmd, ...)
		local f = assert(CMD[cmd])
		local r = f(...)
		if r ~= NORET then
			skynet.ret(skynet.pack(r))
		end
	end)
end)
