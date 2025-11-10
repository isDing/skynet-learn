# Skynet Lua 模块 API 文档集

欢迎使用 Skynet Lua 模块 API 文档集！本文档集为 Skynet 框架的 lualib 目录中的所有 Lua 模块提供了完整的参考资料。

---

## 目录

- [📚 文档列表](#-文档列表)
  - [1. 详细 API 参考手册](#1-详细-api-参考手册)
  - [2. 快速参考指南](#2-快速参考指南)
  - [3. 使用示例集](#3-使用示例集)
- [🎯 使用指南](#-使用指南)
  - [新手学习路径](#新手学习路径)
  - [开发工作流](#开发工作流)
- [📖 文档结构](#-文档结构)
  - [详细 API 文档结构](#详细-api-文档结构)
  - [快速参考结构](#快速参考结构)
  - [使用示例结构](#使用示例结构)
- [🔑 核心概念](#-核心概念)
  - [Actor 模型](#actor-模型)
  - [消息传递](#消息传递)
  - [协程调度](#协程调度)
  - [服务生命周期](#服务生命周期)
- [💡 最佳实践](#-最佳实践)
  - [性能优化](#性能优化)
  - [错误处理](#错误处理)
  - [内存管理](#内存管理)
  - [调试技巧](#调试技巧)
- [❓ 常见问题](#-常见问题)
- [📝 更新记录](#-更新记录)

---

## 📚 文档列表

### 1. [详细 API 参考手册](LUALIB_API_REFERENCE.md)
**文件**: `LUALIB_API_REFERENCE.md`
**大小**: 约 1500 行
**内容**: lualib 目录下所有模块的完整 API 文档

**包含模块**:
- ✅ `skynet.lua` - 核心 API（100+ 函数）
- ✅ `snax/` - Snax Actor 框架
- ✅ `sproto.lua` - 二进制协议库
- ✅ `sprotoparser.lua` - 协议解析器
- ✅ `sprotoloader.lua` - 协议加载器
- ✅ `http/` - HTTP 客户端和服务器
- ✅ `skynet/socket.lua` - Socket API
- ✅ `skynet/cluster.lua` - 集群通信
- ✅ `skynet/dns.lua` - DNS 解析
- ✅ `skynet/crypt.lua` - 加密工具
- ✅ `skynet/db/` - 数据库客户端
- ✅ `loader.lua` - 服务加载器
- ✅ `md5.lua` - MD5 哈希
- ✅ 以及其他 20+ 工具模块

**适用场景**:
- 深度学习 Skynet 框架
- 查找特定 API 的详细说明
- 了解函数参数、返回值和注意事项
- 作为开发时的参考手册

### 2. [快速参考指南](LUALIB_QUICK_REFERENCE.md)
**文件**: `LUALIB_QUICK_REFERENCE.md`
**大小**: 约 800 行
**内容**: 最常用的 API 和使用模式

**包含内容**:
- ✅ 核心服务操作（启动、退出、创建服务）
- ✅ 消息传递（send、call、ret、批量请求）
- ✅ 协程和调度（fork、sleep、wait、timeout）
- ✅ Socket 操作（TCP/UDP 客户端和服务器）
- ✅ Snax 服务（创建、调用、热更新）
- ✅ 集群通信（跨节点调用）
- ✅ HTTP 和 WebSocket
- ✅ Sproto 协议
- ✅ 调试工具
- ✅ 常用设计模式
- ✅ 注意事项和最佳实践

**适用场景**:
- 快速查找常用 API
- 开发时快速参考
- 学习 Skynet 的核心概念
- 代码审查和团队培训

### 3. [使用示例集](LUALIB_EXAMPLES.md)
**文件**: `LUALIB_EXAMPLES.md`
**大小**: 约 1200 行
**内容**: 实际项目中的使用示例

**包含示例**:
- ✅ 简单服务和状态服务
- ✅ 异步消息和同步调用
- ✅ 协程和调度模式
- ✅ TCP/UDP 网络编程
- ✅ Snax 服务开发
- ✅ 集群通信架构
- ✅ HTTP 和 WebSocket 应用
- ✅ Sproto 协议使用
- ✅ 综合应用案例（游戏服务器、数据库代理、缓存服务）

**适用场景**:
- 学习如何在实际项目中使用 Skynet
- 快速上手和原型开发
- 代码模板和最佳实践
- 架构设计和模式参考

---

## 🎯 使用指南

### 新手学习路径

1. **第一步**: 阅读 [快速参考指南](LUALIB_QUICK_REFERENCE.md)
   - 了解 Skynet 的核心概念
   - 掌握最常用的 API
   - 学习基本的使用模式

2. **第二步**: 运行 [使用示例](LUALIB_EXAMPLES.md)
   - 复制示例代码到你的项目
   - 修改和实验
   - 理解不同场景的应用

3. **第三步**: 查阅 [详细 API 文档](LUALIB_API_REFERENCE.md)
   - 深入了解每个函数的细节
   - 学习高级特性
   - 解决开发中的问题

### 开发工作流

#### 1. 需求分析阶段
```
参考: LUALIB_EXAMPLES.md
查找类似场景的示例代码
确定需要使用的模块和 API
```

#### 2. 设计阶段
```
参考: LUALIB_QUICK_REFERENCE.md
确认 API 列表和调用方式
设计服务架构和消息流
```

#### 3. 开发阶段
```
参考: LUALIB_API_REFERENCE.md
查看函数参数和返回值
了解注意事项和限制
```

#### 4. 调试阶段
```
参考: LUALIB_QUICK_REFERENCE.md 的"调试工具"部分
使用 skynet.error, skynet.trace, skynet.task 等
```

#### 5. 优化阶段
```
参考: LUALIB_API_REFERENCE.md 的"性能建议"
使用批量请求、协程池、内存管理
```

---

## 📖 文档结构

### 详细 API 文档结构

每个模块的文档包含以下部分：

```markdown
### 模块名称

**模块路径**: xxx
**说明**: 模块功能概述

#### 常量/配置
- 列出所有常量和默认值

#### 主要方法
##### function_name(param1, param2, ...)
**功能**: 函数功能描述
**参数**: 详细的参数说明
**返回**: 返回值说明
**示例**: 使用示例
**注意**: 注意事项
```

### 快速参考指南结构

```markdown
## 核心操作类别

### 常用操作
```lua
-- 代码示例
```

### 使用模式
```lua
-- 模式示例
```

### 注意事项
- 重要提醒
```

### 示例文档结构

```markdown
## 功能类别

### 场景描述
代码说明...

#### 示例代码
```lua
-- 完整可运行的代码
```

#### 客户端调用
```lua
-- 使用示例
```

#### 运行结果
```
预期输出
```

---

## 🔍 搜索技巧

### 按功能搜索

如果你想查找某个功能：

- **消息传递**: 在文档中搜索 "skynet.send", "skynet.call", "skynet.ret"
- **协程**: 搜索 "skynet.fork", "skynet.sleep", "skynet.wait"
- **网络**: 搜索 "socket", "tcp", "udp", "http", "websocket"
- **集群**: 搜索 "cluster.call", "cluster.send"
- **协议**: 搜索 "sproto", "encode", "decode"
- **调试**: 搜索 "skynet.error", "skynet.trace", "skynet.task"

### 按模块搜索

- **核心功能**: 查找 `skynet.lua` 部分
- **Actor 模式**: 查找 `snax/` 部分
- **网络编程**: 查找 `http/` 和 `skynet/socket.lua` 部分
- **集群**: 查找 `skynet/cluster.lua` 部分
- **协议**: 查找 `sproto` 部分

---

## 💡 最佳实践

### 1. 选择合适的模块

| 需求 | 推荐模块 | 说明 |
|------|----------|------|
| 基本服务开发 | `skynet.lua` | 核心 API，满足大多数需求 |
| Actor 模式 | `snax/` | 更简洁的 Actor 框架 |
| 高性能网络 | `skynet/socket.lua` | 直接控制 socket |
| Web 服务 | `http/` | HTTP 客户端/服务器 |
| 实时通信 | `http/websocket.lua` | WebSocket 支持 |
| 分布式系统 | `skynet/cluster.lua` | 跨节点通信 |
| 高效序列化 | `sproto/` | 二进制协议 |
| 数据库访问 | `skynet/db/` | MySQL/Redis/MongoDB |

### 2. 性能优化建议

1. **减少同步调用**: 优先使用 `skynet.send` 而非 `skynet.call`
2. **使用协程池**: 避免频繁创建/销毁协程
3. **批量操作**: 使用 `skynet.request` 批量发送请求
4. **内存管理**: 大消息使用后及时调用 `skynet.trash`
5. **连接复用**: 使用连接池复用网络连接
6. **缓存策略**: 合理使用集群缓存

### 3. 错误处理

```lua
-- 使用 pcall 包装可能出错的代码
local ok, result = pcall(skynet.call, service, "lua", "cmd", ...)
if not ok then
    skynet.error("调用失败:", result)
    return
end

-- 设置超时避免死锁
local resp = skynet.response()
skynet.fork(function()
    skynet.sleep(500)  -- 5 秒超时
    resp(false, "timeout")
end)
```

### 4. 调试技巧

```lua
-- 输出日志
skynet.error("调试信息:", var)

-- 开启消息跟踪
skynet.trace("操作描述")

-- 查看协程状态
skynet.task()

-- 查看服务状态
skynet.mqlen()
skynet.endless()
```

---

## 📝 更新日志

- **2025-11-10**: 初始版本发布
  - 完成详细 API 文档
  - 完成快速参考指南
  - 完成使用示例集
  - 涵盖 lualib 目录下的所有主要模块

---

## 🤝 贡献指南

如果你发现文档中的错误或有改进建议：

1. 确认问题
2. 提供修正建议
3. 提交反馈

---

## 📞 支持与帮助

- **官方 Wiki**: https://github.com/cloudwu/skynet/wiki
- **源码仓库**: https://github.com/cloudwu/skynet
- **问题反馈**: https://github.com/cloudwu/skynet/issues

---

## 📜 许可证

本文档集遵循 Skynet 框架的开源许可证（MIT）。

---

## 🙏 致谢

感谢 Skynet 框架的作者 cloudwu 和所有贡献者，为我们提供了这个优秀的多线程服务器框架。

---

**开始使用吧！** 🚀

选择适合你的文档，开始你的 Skynet 开发之旅！

1. [快速开始](LUALIB_QUICK_REFERENCE.md) - 5 分钟上手
2. [深入学习](LUALIB_API_REFERENCE.md) - 全面掌握
3. [实战项目](LUALIB_EXAMPLES.md) - 边学边做
