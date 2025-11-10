-- You should use this module (skynet.coroutine) instead of origin lua coroutine in skynet framework
-- 说明：
--  skynet.coroutine 提供对原生 coroutine 的包装，使其与 Skynet 的调度/挂起机制兼容：
--   - skynetco.create/resume/yield/close 与框架 suspend/dispatch 互操作
--   - 正确识别“阻塞于框架”的状态（status 返回 blocked）
--   - 防止 resume 非 skynet 协程或被框架挂起的协程
--  推荐在框架内使用本模块而非原生 coroutine。

local coroutine = coroutine
-- origin lua coroutine module
local coroutine_resume = coroutine.resume
local coroutine_yield = coroutine.yield
local coroutine_status = coroutine.status
local coroutine_running = coroutine.running
local coroutine_close = coroutine.close

local select = select
local skynetco = {}

skynetco.isyieldable = coroutine.isyieldable
skynetco.running = coroutine.running
skynetco.status = coroutine.status

local skynet_coroutines = setmetatable({}, { __mode = "kv" })
-- true : skynet coroutine
-- false : skynet suspend
-- nil : exit

-- 创建一个 skynet 协程，并标记在 skynet_coroutines 中
function skynetco.create(f)
	local co = coroutine.create(f)
	-- mark co as a skynet coroutine
	skynet_coroutines[co] = true
	return co
end

do -- begin skynetco.resume
	local function unlock(co, ...)
		skynet_coroutines[co] = true
		return ...
	end

	local function skynet_yielding(co, ...)
		skynet_coroutines[co] = false
		return unlock(co, coroutine_resume(co, coroutine_yield(...)))
	end

	local function resume(co, ok, ...)
		if not ok then
			return ok, ...
		elseif coroutine_status(co) == "dead" then
			-- the main function exit
			skynet_coroutines[co] = nil
			return true, ...
		elseif (...) == "USER" then
			return true, select(2, ...)
		else
			-- blocked in skynet framework, so raise the yielding message
			return resume(co, skynet_yielding(co, ...))
		end
	end

	-- record the root of coroutine caller (It should be a skynet thread)
	local coroutine_caller = setmetatable({} , { __mode = "kv" })

	-- 恢复协程：
	--  - 拒绝恢复已被框架挂起/非 skynet 的协程
	--  - 处理 USER/SUSPEND 等框架消息，正确返回/递归挂起
	function skynetco.resume(co, ...)
		local co_status = skynet_coroutines[co]
		if not co_status then
			if co_status == false then
				-- is running
				return false, "cannot resume a skynet coroutine suspend by skynet framework"
			end
			if coroutine_status(co) == "dead" then
				-- always return false, "cannot resume dead coroutine"
				return coroutine_resume(co, ...)
			else
				return false, "cannot resume none skynet coroutine"
			end
		end
		local from = coroutine_running()
		local caller = coroutine_caller[from] or from
		coroutine_caller[co] = caller
		return resume(co, coroutine_resume(co, ...))
	end

	function skynetco.thread(co)
		co = co or coroutine_running()
		if skynet_coroutines[co] ~= nil then
			return coroutine_caller[co] , false
		else
			return co, true
		end
	end

end -- end of skynetco.resume

-- 返回更细化的状态：被框架挂起的协程返回 "blocked"
function skynetco.status(co)
	local status = coroutine_status(co)
	if status == "suspended" then
		if skynet_coroutines[co] == false then
			return "blocked"
		else
			return "suspended"
		end
	else
		return status
	end
end

-- 主动让出执行权（向上抛出 USER），由上一层 skynet.resume 驱动
function skynetco.yield(...)
	return coroutine_yield("USER", ...)
end

do -- begin skynetco.wrap

	local function wrap_co(ok, ...)
		if ok then
			return ...
		else
			error(...)
		end
	end

-- 包装一个函数为“可重入调用”的包装器，内部用 skynetco.resume 驱动
function skynetco.wrap(f)
	local co = skynetco.create(function(...)
		return f(...)
	end)
	return function(...)
		return wrap_co(skynetco.resume(co, ...))
	end
end

end	-- end of skynetco.wrap

-- 关闭协程（并在表中去标记）
function skynetco.close(co)
	skynet_coroutines[co] = nil
	return coroutine_close(co)
end

return skynetco
