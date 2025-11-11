-- 说明：
--  harbor 模块提供跨 harbor 的全局命名能力，依赖 .cslave 服务与内核通信。
--  主要用于注册/查询全局名、建立 link/connect，以及与主 harbor 建立关系。
--  术语与约定：
--   - harbor id：低 8 位标识节点；本地数值地址的高 24 位为服务 handle，低 8 位为 harbor id
--   - 全局名：不以 '.' 开头的名字；本地名以 '.' 开头
--   - link(id)：监听与某 harbor 的联通性（下线时获知）；connect(id)：等待与某 harbor 建立连接
--   - linkmaster()：与 master 建立关系，一般在分布式模式下由 cslave 管理
local skynet = require "skynet"

local harbor = {}

-- 将当前（或指定 handle）服务注册为全局名
-- 将当前（或指定 handle）服务注册为全局名（由 .cslave 转发给 Master）
function harbor.globalname(name, handle)
	handle = handle or skynet.self()
	skynet.send(".cslave", "lua", "REGISTER", name, handle)
end

-- 查询全局名对应的地址
-- 查询全局名对应的地址；命中本地缓存直接返回，否则向 Master 查询
function harbor.queryname(name)
	return skynet.call(".cslave", "lua", "QUERYNAME", name)
end

-- 与指定 harbor 建立 link（被动使用）
-- 与指定 harbor 建立 link（被动使用）：
--  - 若链接尚未就绪则挂起等待；就绪或下线时唤醒
function harbor.link(id)
	skynet.call(".cslave", "lua", "LINK", id)
end

-- 主动连接到指定 harbor
-- 主动连接到指定 harbor：
--  - 若尚未建立连接：挂起等待；连接就绪后返回
function harbor.connect(id)
	skynet.call(".cslave", "lua", "CONNECT", id)
end

-- 与 master harbor 建立 link（主从架构）
-- 与 master harbor 建立 link（主从架构，供 .cslave 使用）
function harbor.linkmaster()
	skynet.call(".cslave", "lua", "LINKMASTER")
end

return harbor
