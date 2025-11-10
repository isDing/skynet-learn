-- 说明：
--  datacenterd 是简单的层次化键值中心：
--   - 支持 QUERY/UPDATE/WAIT
--   - 支持以多层 key 访问（通过嵌套表）
--   - WAIT 对分支无效（仅叶子），否则唤醒队列整体并返回错误
local skynet = require "skynet"

local command = {}
local database = {}
local wait_queue = {}
local mode = {}

-- 递归查询（db[key1][key2]...）
local function query(db, key, ...)
	if db == nil or key == nil then
		return db
	else
		return query(db[key], ...)
	end
end

function command.QUERY(key, ...)
	local d = database[key]
	if d ~= nil then
		return query(d, ...)
	end
end

-- 递归更新：末端设置为 value，返回旧值与新值
local function update(db, key, value, ...)
	if select("#",...) == 0 then
		local ret = db[key]
		db[key] = value
		return ret, value
	else
		if db[key] == nil then
			db[key] = {}
		end
		return update(db[key], value, ...)
	end
end

-- 唤醒等待队列：若命中叶子队列，返回该队列
local function wakeup(db, key1, ...)
	if key1 == nil then
		return
	end
	local q = db[key1]
	if q == nil then
		return
	end
	if q[mode] == "queue" then
		db[key1] = nil
		if select("#", ...) ~= 1 then
			-- throw error because can't wake up a branch
			for _,response in ipairs(q) do
				response(false)
			end
		else
			return q
		end
	else
		-- it's branch
		return wakeup(q , ...)
	end
end

-- UPDATE 并尝试唤醒等待者：返回旧值
function command.UPDATE(...)
	local ret, value = update(database, ...)
	if ret ~= nil or value == nil then
		return ret
	end
	local q = wakeup(wait_queue, ...)
	if q then
		for _, response in ipairs(q) do
			response(true,value)
		end
	end
end

-- 构建等待队列：
--  - 叶子：{ [mode] = "queue" , response... }
--  - 分支：{ [mode] = "branch" , key -> next }
local function waitfor(db, key1, key2, ...)
	if key2 == nil then
		-- push queue
		local q = db[key1]
		if q == nil then
			q = { [mode] = "queue" }
			db[key1] = q
		else
			assert(q[mode] == "queue")
		end
		table.insert(q, skynet.response())
	else
		local q = db[key1]
		if q == nil then
			q = { [mode] = "branch" }
			db[key1] = q
		else
			assert(q[mode] == "branch")
		end
		return waitfor(q, key2, ...)
	end
end

skynet.start(function()
	skynet.dispatch("lua", function (_, _, cmd, ...)
		if cmd == "WAIT" then
			local ret = command.QUERY(...)
			if ret ~= nil then
				skynet.ret(skynet.pack(ret))
			else
				waitfor(wait_queue, ...)
			end
		else
			local f = assert(command[cmd])
			skynet.ret(skynet.pack(f(...)))
		end
	end)
end)
