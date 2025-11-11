-- 说明：
--  snax.interface 负责解析 Snax 服务的接口定义文件（accept/response/system），
--  生成一个方法描述表 func 及用于定位源码的 pattern。
--  调用方式：
--    local func, pattern = snax_interface(name, _ENV, optional_loader)
--  其中 func 是形如 { {id, group, name, func}, ... } 的数组，group ∈ {"system","accept","response"}
local skynet = require "skynet"

-- 默认加载器：在 snax 路径下按 "?" 替换为 name 依次查找并 loadfile
local function dft_loader(path, name, G)
	local errlist = {}

	for pat in string.gmatch(path,"[^;]+") do
		local filename = string.gsub(pat, "?", name)
		local f , err = loadfile(filename, "bt", G)
		if f then
			return f, pat
		else
			table.insert(errlist, err)
		end
	end

	error(table.concat(errlist, "\n"))
end

return function (name , G, loader)
	loader = loader or dft_loader

	-- 构造一个方法登记器：写入 accept/response 时分配自增 id
	local function func_id(id, group)
		local tmp = {}
		local function count( _, name, func)
			if type(name) ~= "string" then
				error (string.format("%s method only support string", group))
			end
			if type(func) ~= "function" then
				error (string.format("%s.%s must be function", group, name))
			end
			if tmp[name] then
				error (string.format("%s.%s duplicate definition", group, name))
			end
			tmp[name] = true
			table.insert(id, { #id + 1, group, name, func} )
		end
		return setmetatable({}, { __newindex = count })
	end

	do
		assert(getmetatable(G) == nil)
		assert(G.init == nil)
		assert(G.exit == nil)
		assert(G.accept == nil)
		assert(G.response == nil)
	end

	local temp_global = {}
	local env = setmetatable({} , { __index = temp_global })
	local func = {}

	local system = { "init", "exit", "hotfix", "profile"}

	do
		for k, v in ipairs(system) do
			system[v] = k
			func[k] = { k , "system", v }
		end
	end

	-- 通过 __newindex 捕获 accept.* / response.* 的定义
	env.accept = func_id(func, "accept")
	env.response = func_id(func, "response")

	local function init_system(t, name, f)
		local index = system[name]
		if index then
			if type(f) ~= "function" then
				error (string.format("%s must be a function", name))
			end
			func[index][4] = f
		else
			temp_global[name] = f
		end
	end

	local path = assert(skynet.getenv "snax" , "please set snax in config file")
	local mainfunc, pattern = loader(path, name, G)

	-- 将 G 的 __index 指向 env（包含 accept/response 登记器），
	-- 将 __newindex 指向 init_system（捕获 system 方法及其他全局符号）
	setmetatable(G,	{ __index = env , __newindex = init_system })
	local ok, err = xpcall(mainfunc, debug.traceback)
	setmetatable(G, nil)
	assert(ok,err)

	for k,v in pairs(temp_global) do
		G[k] = v
	end

	-- 返回方法描述数组 func 以及匹配到的路径 pattern（用于定位源码）
	return func, pattern
end
