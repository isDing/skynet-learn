-- 说明：
--  datacenter 提供一个跨服务（本地）共享的键值存取中心，由名为 "DATACENTER" 的服务实现。
--  典型用途：配置、全局路由表、运行时状态等。
--  路径语义：
--   - get(path1, path2, ...) 递归索引 table，返回叶子或中间表（不可变更约束由业务自律）
--   - set(path1, path2, ..., value) 在末端写入，必要时逐级创建子表
--   - wait(path1, path2, ...) 若键不存在则挂起，直到 UPDATE 同一路径写入非 nil 值
local skynet = require "skynet"

local datacenter = {}

-- 获取键值：QUERY path... -> value（返回 nil 表示不存在）
function datacenter.get(...)
	return skynet.call("DATACENTER", "lua", "QUERY", ...)
end

-- 设置键值：UPDATE path... value（返回旧值或 nil）
function datacenter.set(...)
	return skynet.call("DATACENTER", "lua", "UPDATE", ...)
end

-- 等待某个键出现或更新：WAIT path... -> value
--  注意：仅对叶子键生效；对分支键调用将唤醒整个队列并返回错误（参见 datacenterd.lua）
function datacenter.wait(...)
	return skynet.call("DATACENTER", "lua", "WAIT", ...)
end

return datacenter
