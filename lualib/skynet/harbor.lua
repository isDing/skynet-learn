-- 说明：
--  harbor 模块提供跨 harbor 的全局命名能力，依赖 .cslave 服务与内核通信。
--  主要用于注册/查询全局名、建立 link/connect，以及与主 harbor 建立关系。
local skynet = require "skynet"

local harbor = {}

-- 将当前（或指定 handle）服务注册为全局名
function harbor.globalname(name, handle)
	handle = handle or skynet.self()
	skynet.send(".cslave", "lua", "REGISTER", name, handle)
end

-- 查询全局名对应的地址
function harbor.queryname(name)
	return skynet.call(".cslave", "lua", "QUERYNAME", name)
end

-- 与指定 harbor 建立 link（被动使用）
function harbor.link(id)
	skynet.call(".cslave", "lua", "LINK", id)
end

-- 主动连接到指定 harbor
function harbor.connect(id)
	skynet.call(".cslave", "lua", "CONNECT", id)
end

-- 与 master harbor 建立 link（主从架构）
function harbor.linkmaster()
	skynet.call(".cslave", "lua", "LINKMASTER")
end

return harbor
