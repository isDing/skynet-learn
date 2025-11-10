-- 说明：
--  sharedata 提供“多版本、只读 + 增量更新”的共享数据：
--   - 读者获取到的是一个代理对象（box），支持按增量补丁更新（sd.update）
--   - 背后由 sharedatad 服务统一管理版本与确认
--   - 适合热更新配置、常量表等场景
local skynet = require "skynet"
local sd = require "skynet.sharedata.corelib"

local service

skynet.init(function()
	service = skynet.uniqueservice "sharedatad"
end)

local sharedata = {}
local cache = setmetatable({}, { __mode = "kv" })

-- 监听共享对象的新版本并应用增量更新（直到 sharedatad 返回 nil）
local function monitor(name, obj, cobj)
	local newobj = cobj
	while true do
		newobj = skynet.call(service, "lua", "monitor", name, newobj)
		if newobj == nil then
			break
		end
		sd.update(obj, newobj)
		skynet.send(service, "lua", "confirm" , newobj)
	end
	if cache[name] == obj then
		cache[name] = nil
	end
end

-- 查询共享对象：返回一个可增量更新的代理对象
function sharedata.query(name)
	if cache[name] then
		return cache[name]
	end
	local obj = skynet.call(service, "lua", "query", name)
	if cache[name] and cache[name].__obj == obj then
		skynet.send(service, "lua", "confirm" , obj)
		return cache[name]
	end
	local r = sd.box(obj)
	skynet.send(service, "lua", "confirm" , obj)
	skynet.fork(monitor,name, r, obj)
	cache[name] = r
	return r
end

-- 创建/覆盖一个共享对象
function sharedata.new(name, v, ...)
	skynet.call(service, "lua", "new", name, v, ...)
end

-- 更新共享对象（生成新版本）
function sharedata.update(name, v, ...)
	skynet.call(service, "lua", "update", name, v, ...)
end

-- 删除共享对象
function sharedata.delete(name)
	skynet.call(service, "lua", "delete", name)
end

-- 主动清理本地缓存代理的内部结构并触发 GC
function sharedata.flush()
	for name, obj in pairs(cache) do
		sd.flush(obj)
	end
	collectgarbage()
end

-- 拷贝共享对象的当前版本数据（深拷贝到普通 Lua 表）
function sharedata.deepcopy(name, ...)
	if cache[name] then
		local cobj = cache[name].__obj
		return sd.copy(cobj, ...)
	end

	local cobj = skynet.call(service, "lua", "query", name)
	local ret = sd.copy(cobj, ...)
	skynet.send(service, "lua", "confirm" , cobj)
	return ret
end

return sharedata
