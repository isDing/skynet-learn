-- 说明：
--  snax.hotfix 实现对已运行 Snax 服务的热更新：
--   - 解析 patch 源码，构造一个临时的接口描述（与 snax.interface 一致的结构）
--   - 收集现有服务方法闭包的 upvalue，并通过 upvaluejoin 将新函数绑定到旧环境
--   - 按 group/name 精确替换目标函数；若存在 system.hotfix 则调用它完成用户自定义处理
local si = require "snax.interface"

-- 获取函数的 _ENV upvalue id，用于判断闭包是否属于同一环境
local function envid(f)
	local i = 1
	while true do
		local name, value = debug.getupvalue(f, i)
		if name == nil then
			return
		end
		if name == "_ENV" then
			return debug.upvalueid(f, i)
		end
		i = i + 1
	end
end

-- 递归收集函数 f 及其同环境子函数的 upvalue 映射（name -> {func, index, id}）
local function collect_uv(f , uv, env)
	local i = 1
	while true do
		local name, value = debug.getupvalue(f, i)
		if name == nil then
			break
		end
		local id = debug.upvalueid(f, i)

		if uv[name] then
			assert(uv[name].id == id, string.format("ambiguity local value %s", name))
		else
			uv[name] = { func = f, index = i, id = id }

			if type(value) == "function" then
				if envid(value) == env then
					collect_uv(value, uv, env)
				end
			end
		end

		i = i + 1
	end
end

-- 为现有服务方法（funcs）收集全局 upvalue 表（包括 _ENV）
local function collect_all_uv(funcs)
	local global = {}
	for _, v in pairs(funcs) do
		if v[4] then
			collect_uv(v[4], global, envid(v[4]))
		end
	end
	if not global["_ENV"] then
		global["_ENV"] = {func = collect_uv, index = 1}
	end
	return global
end

-- patch loader：忽略路径，直接 load 传入的源码字符串
local function loader(source)
	return function (path, name, G)
		return load(source, "=patch", "bt", G)
	end
end

-- 在 funcs 中按 group/name 查找方法描述项
local function find_func(funcs, group , name)
	for _, desc in pairs(funcs) do
		local _, g, n = table.unpack(desc)
		if group == g and name == n then
			return desc
		end
	end
end

-- 用于识别“未绑定” upvalue 的哑环境副本
local dummy_env = {}
for k,v in pairs(_ENV) do dummy_env[k] = v end

-- 将函数 f 的 upvalue 与 global 表中的旧 upvalue 进行 join（替换到原有闭包环境）
local function _patch(global, f)
	local i = 1
	while true do
		local name, value = debug.getupvalue(f, i)
		if name == nil then
			break
		elseif value == nil or value == dummy_env then
			local old_uv = global[name]
			if old_uv then
				debug.upvaluejoin(f, i, old_uv.func, old_uv.index)
			end
		else
			if type(value) == "function" then
				_patch(global, value)
			end
		end
		i = i + 1
	end
end

-- 替换 funcs 中指定 group/name 的函数实现为 f，并保持原有 upvalue 绑定
local function patch_func(funcs, global, group, name, f)
	local desc = assert(find_func(funcs, group, name) , string.format("Patch mismatch %s.%s", group, name))
	_patch(global, f)
	desc[4] = f
end

-- 主流程：
--  1) 解析 patch 源码，得到临时 func 描述
--  2) 收集现有 upvalue
--  3) 逐个替换匹配到的函数
--  4) 若存在 system.hotfix，则调用它
local function inject(funcs, source, ...)
	local patch = si("patch", dummy_env, loader(source))
	local global = collect_all_uv(funcs)

	for _, v in pairs(patch) do
		local _, group, name, f = table.unpack(v)
		if f then
			patch_func(funcs, global, group, name, f)
		end
	end

	local hf = find_func(patch, "system", "hotfix")
	if hf and hf[4] then
		return hf[4](...)
	end
end

-- 对外导出：返回 pcall 结果（成功/失败及错误信息）
return function (funcs, source, ...)
	return pcall(inject, funcs, source, ...)
end
