-- 说明：
--  datacenter 提供一个跨服务（本地）共享的键值存取中心，由名为 "DATACENTER" 的服务实现。
--  典型用途：配置、全局路由表、运行时状态等。
local skynet = require "skynet"

local datacenter = {}

-- 获取键值：QUERY path... -> value
function datacenter.get(...)
	return skynet.call("DATACENTER", "lua", "QUERY", ...)
end

-- 设置键值：UPDATE path... value
function datacenter.set(...)
	return skynet.call("DATACENTER", "lua", "UPDATE", ...)
end

-- 等待某个键出现或更新：WAIT path... -> value
function datacenter.wait(...)
	return skynet.call("DATACENTER", "lua", "WAIT", ...)
end

return datacenter
