# Skynet Lua 库 API 文档

欢迎使用 Skynet Lua 库 API 文档集！本文档集合为 Skynet 框架 lualib 目录中的所有 Lua 模块提供了完整的 API 参考。

---

## 📚 文档导航

### 🔗 [API 索引入口](./index.md) ⭐
**快速查找 API 接口**

- 361 行简洁索引
- 200+ 个 API 接口列表
- 按模块分类组织
- **每个接口名可点击跳转到详细文档**
- 支持 IDE Markdown 点击跳转

**推荐用途**: 快速查找和定位 API 接口

---

### 1. [API 参考手册](./LUALIB_API_REFERENCE.md)
**最详细的 API 文档**

- 2282 行完整文档
- 覆盖 30+ 个模块
- 200+ 个 API 函数
- 函数签名、参数说明、返回值、示例代码
- 使用注意事项和最佳实践

**推荐用途**: 深入学习各模块的 API 使用方法

---

### 2. [快速参考指南](./LUALIB_QUICK_REFERENCE.md)
**常用 API 快速参考**

- 612 行核心内容
- 常用 API 速查
- 代码片段和使用模式
- 设计模式示例
- 调试和优化技巧

**推荐用途**: 开发时快速查找常用 API

---

### 3. [代码示例集](./LUALIB_EXAMPLES.md)
**实战代码示例**

- 1411 行代码示例
- 20+ 个实际应用场景
- 完整可运行的项目代码
- 综合应用案例（聊天服务、游戏网关、分布式数据库）

**推荐用途**: 学习实际项目中的用法

---

### 4. [文档索引和学习指南](./LUALIB_README.md)
**文档导航和学习路径**

- 366 行完整指南
- 新手学习路径
- 开发工作流指导
- 核心概念解释
- 最佳实践汇总

**推荐用途**: 了解文档结构，选择合适的学习路径

---

## 📖 涵盖的模块

### 核心模块
- **skynet.lua** - 核心 API（50+ 函数）
  - 服务管理：newservice, uniqueservice, queryservice
  - 消息传递：send, call, ret, response
  - 协程调度：fork, sleep, wait, wakeup
  - 定时器：timeout, now, time
  - 内存管理：pack, unpack, trash
  - 调试工具：trace, error, task

### 功能模块
- **snax/** - Snax actor 框架（15+ 函数）
  - 服务管理、接口定义、热更新、性能分析

- **sproto/** - 协议序列化（20+ 函数）
  - sproto.lua：核心序列化
  - sprotoparser.lua：协议解析
  - sprotoloader.lua：协议加载

- **http/** - HTTP 和 WebSocket（15+ 函数）
  - httpd.lua：HTTP 服务器
  - httpc.lua：HTTP 客户端
  - websocket.lua：WebSocket 支持

- **skynet/socket.lua** - Socket API（25+ 函数）
  - TCP/UDP 连接、数据读写、连接管理

- **skynet/cluster.lua** - 集群通信（10+ 函数）
  - 跨节点调用、服务注册、集群管理

- **skynet/dns.lua** - DNS 解析（5+ 函数）
  - 异步 DNS 解析、域名查询

### 工具模块（60+ 函数）
- **skynet/crypt.lua** - 加密工具
  - Base64、MD5、SHA1、DES、HMAC
- **skynet/db/** - 数据库客户端
  - redis.lua、mongo.lua、mysql.lua
- **skynet/sharedata.lua** - 共享数据
- **skynet/sharetable.lua** - 共享表
- **skynet/sharemap.lua** - 共享映射
- **skynet/multicast.lua** - 多播服务
- **skynet/queue.lua** - 队列服务
- **skynet/harbor.lua** - Harbor 管理
- **md5.lua** - MD5 哈希算法

---

## 🚀 快速开始

### 新手学习路径

1. **第一步**: 阅读 [文档索引和学习指南](./LUALIB_README.md)
   - 了解 Skynet 核心概念
   - 学习整体架构

2. **第二步**: 浏览 [API 索引入口](./index.md)
   - 快速了解有哪些 API
   - 按需选择感兴趣的模块

3. **第三步**: 查阅 [快速参考指南](./LUALIB_QUICK_REFERENCE.md)
   - 学习常用 API
   - 掌握基本使用模式

4. **第四步**: 参考 [代码示例集](./LUALIB_EXAMPLES.md)
   - 实践示例代码
   - 理解实际应用场景

5. **第五步**: 深入 [API 参考手册](./LUALIB_API_REFERENCE.md)
   - 详细了解每个 API
   - 学习高级特性

### 开发工作流

#### 需求分析阶段
```
参考: LUALIB_EXAMPLES.md
查找类似场景的示例代码
确定需要使用的模块和 API
```

#### 设计阶段
```
参考: LUALIB_QUICK_REFERENCE.md
确认 API 列表和调用方式
设计服务架构和消息流
```

#### 开发阶段
```
参考: LUALIB_API_REFERENCE.md
查看函数参数和返回值
了解注意事项和限制
```

#### 调试阶段
```
参考: LUALIB_QUICK_REFERENCE.md 的"调试工具"部分
使用 skynet.error, skynet.trace, skynet.task 等
```

#### 优化阶段
```
参考: LUALIB_API_REFERENCE.md 的"性能建议"
使用批量请求、协程池、内存管理
```

---

## 📊 文档统计

| 文档 | 行数 | 描述 |
|------|------|------|
| **index.md** | 361 | API 索引入口 ⭐ |
| **LUALIB_API_REFERENCE.md** | 2282 | 详细 API 参考 |
| **LUALIB_QUICK_REFERENCE.md** | 612 | 快速参考指南 |
| **LUALIB_EXAMPLES.md** | 1411 | 代码示例集 |
| **LUALIB_README.md** | 366 | 学习指南 |
| **README.md** | 108 | 本文档（导航中心） |
| **总计** | **5140+** | 完整文档集 |

### 覆盖范围
- **API 函数**: 200+ 个
- **代码示例**: 100+ 个
- **覆盖模块**: 30+ 个
- **文档语言**: 中文
- **支持平台**: VS Code、GitHub、任意 Markdown 阅读器

---

## 💡 使用建议

1. **按需阅读**: 不需要一次性阅读所有文档，从 index.md 开始浏览
2. **实践结合**: 边看示例边编码，理论结合实践
3. **参考查询**: 开发时可作为常备参考手册
4. **团队共享**: 适合团队培训和学习使用
5. **版本控制**: 文档跟随代码更新，保持同步

---

## 📝 文档特点

- ✅ **中文编写** - 便于中文开发者理解
- ✅ **结构清晰** - 层次分明，易于查找
- ✅ **内容完整** - 所有公开 API 均有文档
- ✅ **示例丰富** - 包含实际使用场景和完整案例
- ✅ **实用性强** - 提供最佳实践和性能建议
- ✅ **格式规范** - 统一 Markdown 格式，支持 IDE 点击跳转
- ✅ **索引优化** - index.md 提供可点击的 API 索引
- ✅ **渐进学习** - 从新手到专家的完整学习路径

---

## 🔗 相关链接

- [Skynet 官方仓库](https://github.com/cloudwu/skynet)
- [Skynet Wiki](https://github.com/cloudwu/skynet/wiki)
- [Sproto 协议库](https://github.com/cloudwu/sproto)
- [项目技术文档](../SKYNET-TECHNICAL-MANUAL.md)
- [架构概览文档](../14-architecture-overview.md)

---

## 📝 更新记录

- **2025-11-10**: 初始文档集创建
  - 添加 API 索引入口（index.md）
  - 创建详细 API 参考文档
  - 添加快速参考和代码示例
  - 完善学习指南和导航

---

**版本**: 基于 Skynet 最新版本
**更新日期**: 2025-11-10
**维护者**: Claude Code (Anthropic)
**文档总量**: 5140+ 行
