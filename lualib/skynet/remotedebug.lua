-- 说明：
--  remotedebug 提供远程交互式调试能力：进入“调试模式”后，可以通过 socket 远端发送命令，
--  在服务内执行表达式/语句、设置钩子、单步/下一步/继续等。核心机制：
--    - 替换 skynet.dispatch_message 的内部 raw_dispatch_message 为带钩子的版本
--    - 通过 debugchannel 与远端交互（读取命令、回显输出），print 重定向到 socket
--    - 设置 linehook/skip_hook 实现断点样式的单步，watch_proto 实现按协议触发进入调试
local skynet = require "skynet"
local debugchannel = require "skynet.debugchannel"
local socketdriver = require "skynet.socketdriver"
local injectrun = require "skynet.injectcode"
local table = table
local debug = debug
local coroutine = coroutine
local sethook = debugchannel.sethook


local M = {}

local HOOK_FUNC = "raw_dispatch_message"  -- 目标 upvalue 名称（在 dispatcher 内部闭包中）
local raw_dispatcher
local print = _G.print
local skynet_suspend
local skynet_resume
local prompt
local newline

local function change_prompt(s)
	-- 更新远端提示符
	newline = true
	prompt = s
end

local function replace_upvalue(func, uvname, value)
	-- 在闭包中找到名为 uvname 的 upvalue，并可选择替换其值
	local i = 1
	while true do
		local name, uv = debug.getupvalue(func, i)
		if name == nil then
			break
		end
		if name == uvname then
			if value then
				debug.setupvalue(func, i, value)
			end
			return uv
		end
		i = i + 1
	end
end

local function remove_hook(dispatcher)
	-- 退出调试模式：还原 raw_dispatch_message、恢复 print、记录日志
	assert(raw_dispatcher, "Not in debug mode")
	replace_upvalue(dispatcher, HOOK_FUNC, raw_dispatcher)
	raw_dispatcher = nil
	print = _G.print

	skynet.error "Leave debug mode"
end

local function gen_print(fd)
	-- redirect print to socket fd
	return function(...)
		local tmp = table.pack(...)
		for i=1,tmp.n do
			tmp[i] = tostring(tmp[i])
		end
		table.insert(tmp, "\n")
		socketdriver.send(fd, table.concat(tmp, "\t"))
	end
end

local function run_exp(ok, ...)
	if ok then
		print(...)
	end
	return ok
end

local function run_cmd(cmd, env, co, level)
	-- 先尝试当作表达式返回（"return ..."），失败再当作语句执行
	if not run_exp(injectrun("return "..cmd, co, level, env)) then
		print(select(2, injectrun(cmd,co, level,env)))
	end
end

local ctx_skynet = debug.getinfo(skynet.start,"S").short_src	-- skip when enter this source file
local ctx_term = debug.getinfo(run_cmd, "S").short_src	-- term when get here
local ctx_active = {}

local linehook
local function skip_hook(mode)
	-- 用于“下一步”逻辑：跨越来自 skynet.start 的跳转或其他非用户代码
	local co = coroutine.running()
	local ctx = ctx_active[co]
	if mode == "return" then
		ctx.level = ctx.level - 1
		if ctx.level == 0 then
			ctx.needupdate = true
			sethook(linehook, "crl")
		end
	else
		ctx.level = ctx.level + 1
	end
end

function linehook(mode, line)
	-- 行级钩子：更新提示符、在用户代码处 yield，触发远端命令读取
	local co = coroutine.running()
	local ctx = ctx_active[co]
	if mode ~= "line" then
		ctx.needupdate = true
		if mode ~= "return" then
			if ctx.next_mode or debug.getinfo(2,"S").short_src == ctx_skynet then
				ctx.level = 1
				sethook(skip_hook, "cr")
			end
		end
	else
		if ctx.needupdate then
			ctx.needupdate = false
			ctx.filename = debug.getinfo(2, "S").short_src
			if ctx.filename == ctx_term then
				ctx_active[co] = nil
				sethook()
				change_prompt(string.format(":%08x>", skynet.self()))
				return
			end
		end
		change_prompt(string.format("%s(%d)>",ctx.filename, line))
		return true	-- yield
	end
end

local function add_watch_hook()
	-- 进入“监听模式”：在下次命中条件时切换到行级钩子
	local co = coroutine.running()
	local ctx = {}
	ctx_active[co] = ctx
	local level = 1
	sethook(function(mode)
		if mode == "return" then
			level = level - 1
		else
			level = level + 1
			if level == 0 then
				ctx.needupdate = true
				sethook(linehook, "crl")
			end
		end
	end, "cr")
end

local function watch_proto(protoname, cond)
	-- 监听指定协议的下一次分发（可选 cond 过滤），命中后挂上行级钩子
	local proto = assert(replace_upvalue(skynet.register_protocol, "proto"), "Can't find proto table")
	local p = proto[protoname]
	if p == nil then
		return "No " .. protoname
	end
	local dispatch = p.dispatch_origin or p.dispatch
	if dispatch == nil then
		return "No dispatch"
	end
	p.dispatch_origin = dispatch
	p.dispatch = function(...)
		if not cond or cond(...) then
			p.dispatch = dispatch	-- restore origin dispatch function
			add_watch_hook()
		end
		dispatch(...)
	end
end

local function remove_watch()
	-- 取消所有监听：移除钩子并清空 ctx_active
	for co in pairs(ctx_active) do
		sethook(co)
	end
	ctx_active = {}
end

local dbgcmd = {}

function dbgcmd.s(co)
	local ctx = ctx_active[co]
	ctx.next_mode = false
	skynet_suspend(co, skynet_resume(co))
end

function dbgcmd.n(co)
	local ctx = ctx_active[co]
	ctx.next_mode = true
	skynet_suspend(co, skynet_resume(co))
end

function dbgcmd.c(co)
	sethook(co)
	ctx_active[co] = nil
	change_prompt(string.format(":%08x>", skynet.self()))
	skynet_suspend(co, skynet_resume(co))
end

local function hook_dispatch(dispatcher, resp, fd, channel)
	-- 用 hook 包裹 dispatcher：拦截执行前进入 debug_loop，随后调用原始 dispatcher
	change_prompt(string.format(":%08x>", skynet.self()))

	print = gen_print(fd)
	local env = {
		print = print,
		watch = watch_proto
	}

	local watch_env = {
		print = print
	}

	local function watch_cmd(cmd)
		local co = next(ctx_active)
		watch_env._CO = co
		if dbgcmd[cmd] then
			dbgcmd[cmd](co)
		else
			run_cmd(cmd, watch_env, co, 0)
		end
	end

	local function debug_hook()
		-- 交互主循环：打印提示符、读取远端命令、执行、直到 cont 为止
		while true do
			if newline then
				socketdriver.send(fd, prompt)
				newline = false
			end
			local cmd = channel:read()
			if cmd then
				if cmd == "cont" then
					-- leave debug mode
					break
				end
				if cmd ~= "" then
					if next(ctx_active) then
						watch_cmd(cmd)
					else
						run_cmd(cmd, env, coroutine.running(),2)
					end
				end
				newline = true
			else
				-- no input
				return
			end
		end
		-- exit debug mode
		remove_watch()
		remove_hook(dispatcher)
		resp(true)
	end

	local func
	local function hook(...)
		debug_hook()
		return func(...)
	end
	func = replace_upvalue(dispatcher, HOOK_FUNC, hook)
	if func then
		local function idle()
			if raw_dispatcher then
			    skynet.timeout(10,idle)	-- idle every 0.1s
			end
		end
		skynet.timeout(0, idle)
	end
	return func
end

function M.start(import, fd, handle)
	-- 开启远程调试：替换 dispatcher 内部 raw_dispatch_message，并与远端建立控制通道
	local dispatcher = import.dispatch
	skynet_suspend = import.suspend
	skynet_resume = import.resume
	assert(raw_dispatcher == nil, "Already in debug mode")
	skynet.error "Enter debug mode"
	local channel = debugchannel.connect(handle)
	raw_dispatcher = hook_dispatch(dispatcher, skynet.response(), fd, channel)
end

return M
