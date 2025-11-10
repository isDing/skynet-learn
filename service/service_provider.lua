-- 说明：
--  service_provider 是命名服务的后端：
--   - 输入: LAUNCH/QUERY/CLOSE/TEST 等来自 skynet.service 封装的请求
--   - 负责：串行化创建某个 name 的服务（仅一次），其余并发请求排队等待
--   - 记录：启动参数/时间/状态（booting/queue）
local skynet = require "skynet"

local provider = {}

-- 懒加载：当 svr[name] 不存在时创建记录表
local function new_service(svr, name)
	local s = {}
	svr[name] = s
	s.queue = {}
	return s
end

local svr = setmetatable({}, { __index = new_service })


-- 查询已有服务地址：若启动中则压入队列，等待 launch 完成
function provider.query(name)
	local s = svr[name]
	if s.queue then
		table.insert(s.queue, skynet.response())
	else
		if s.address then
			return skynet.ret(skynet.pack(s.address))
		else
			error(s.error)
		end
	end
end

-- 完成 service_cell 初始化并记录启动信息
local function boot(addr, name, code, ...)
	local s = svr[name]
	skynet.call(addr, "lua", "init", code, ...)
	local tmp = table.pack( ... )
	for i=1,tmp.n do
		tmp[i] = tostring(tmp[i])
	end

	if tmp.n > 0 then
		s.init = table.concat(tmp, ",")
	end
	s.time = skynet.time()
end

-- 启动服务（若未启动）：已启动则返回地址；并发调用排队等待
function provider.launch(name, code, ...)
	local s = svr[name]
	if s.address then
		return skynet.ret(skynet.pack(s.address))
	end
	if s.booting then
		table.insert(s.queue, skynet.response())
	else
		s.booting = true
		local err
		local ok, addr = pcall(skynet.newservice,"service_cell", name)
		if ok then
			ok, err = xpcall(boot, debug.traceback, addr, name, code, ...)
		else
			err = addr
			addr = nil
		end
		s.booting = nil
		if ok then
			s.address = addr
			for _, resp in ipairs(s.queue) do
				resp(true, addr)
			end
			s.queue = nil
			skynet.ret(skynet.pack(addr))
		else
			if addr then
				skynet.send(addr, "debug", "EXIT")
			end
			s.error = err
			for _, resp in ipairs(s.queue) do
				resp(false)
			end
			s.queue = nil
			error(err)
		end
	end
end

-- 检查状态：返回地址 / booting / 抛错 / nil
function provider.test(name)
	local s = svr[name]
	if s.booting then
		skynet.ret(skynet.pack(nil, true))	-- booting
	elseif s.address then
		skynet.ret(skynet.pack(s.address))
	elseif s.error then
		error(s.error)
	else
		skynet.ret()	-- nil
	end
end

-- 关闭并清除记录（返回已关闭的地址）
function provider.close(name)
	local s = svr[name]
	if not s or s.booting then
		return skynet.ret(skynet.pack(nil))
	end

	svr[name] = nil
	skynet.ret(skynet.pack(s.address))
end

skynet.start(function()
	skynet.dispatch("lua", function(session, address, cmd, ...)
		provider[cmd](...)
	end)
	skynet.info_func(function()
		local info = {}
		for k,v in pairs(svr) do
			local status
			if v.booting then
				status = "booting"
			elseif v.queue then
				status = "waiting(" .. #v.queue .. ")"
			end
			info[skynet.address(v.address)] = {
				init = v.init,
				name = k,
				time = os.date("%Y %b %d %T %z",math.floor(v.time)),
				status = status,
			}
		end
		return info
	end)
end)
