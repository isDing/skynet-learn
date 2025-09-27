# Skynet 文档中心

欢迎访问 Skynet 游戏服务器框架的文档中心。本目录包含了 Skynet 的架构分析、开发指南和学习资源。

## 📁 文档结构

```
docs/
├── README.md                    # 本文件
├── tutorials/                   # 教程和学习资源
│   ├── learning-path-guide.md  # 完整学习路径（8-12周）
│   ├── module-analysis-guide.md # 模块深度解析
│   └── practice-exercises.md   # 11个渐进式练习
├── architecture/                # 架构分析文档
│   ├── skynet-network-layer-architecture.md      # 网络层架构详解
│   ├── skynet-complete-architecture-analysis.md  # 完整架构分析
│   └── network-layer-index.md                    # 网络层文档索引
├── guides/                      # 开发指南
│   ├── require_module_lookup_guide.md  # 模块加载机制
│   └── skynet_module_examples.md       # 模块开发示例
└── diagrams/                    # 架构图表
    ├── network/                 # 网络层图表（8个）
    └── 详细图表/                # 整体架构图（11个）
```

## 🎯 快速导航

### 📚 学习资源（推荐入口）

#### 🌟 [完整学习路径](./tutorials/learning-path-guide.md)
**适合：零基础到高级开发者**
- 8-12周系统化学习计划
- 7个学习阶段（基础→分布式）
- 每阶段配备实践项目
- 常见问题和调试技巧

#### 📖 [模块分析指南](./tutorials/module-analysis-guide.md)
**适合：需要深入理解架构的开发者**
- C层核心模块详解（11个）
- Lua服务层分析
- 学习重点和难度评估
- 三条学习路径选择

#### 💻 [实践练习手册](./tutorials/practice-exercises.md)
**适合：动手实践学习者**
- 11个渐进式编程练习
- 从 Hello World 到分布式系统
- 完整参考答案和测试代码
- 压力测试工具实现

### 🏗 架构文档

#### 🌐 [网络层架构详解](./architecture/skynet-network-layer-architecture.md)
深入解析 Skynet 网络层设计：
- 单线程IO多路复用模型
- Socket管理和状态机
- 数据收发流程
- 并发安全设计
- 性能优化策略

#### 🔧 [完整架构分析](./architecture/skynet-complete-architecture-analysis.md)
Skynet 整体架构全面分析：
- Actor 模型实现
- 消息队列机制
- 服务管理系统
- 多线程调度策略

#### 📑 [网络层文档索引](./architecture/network-layer-index.md)
网络层相关文档和图表的导航页面

### 📖 开发指南

#### 📦 [模块系统指南](./guides/require_module_lookup_guide.md)
Skynet 模块加载机制详解：
- Lua require 工作原理
- 模块路径配置
- 自定义加载器实现
- 最佳实践

#### 💡 [模块开发示例](./guides/skynet_module_examples.md)
实用的开发模板和示例：
- 服务创建模板
- 消息处理示例
- 常用 API 演示

### 📊 架构图表

#### [网络层图表集](./diagrams/network/)
8个详细的 Mermaid 架构图：
- 网络层整体架构
- Socket 状态机
- 数据接收/发送流程
- 线程交互机制
- Socket ID 管理
- 写缓冲区管理
- Socket Server 数据结构

#### [整体架构图表集](./diagrams/详细图表/)
11个系统架构图：
- 整体架构图
- 启动流程图
- 消息传递序列图
- 线程模型和调度
- 服务生命周期
- 核心组件关系
- 消息队列架构
- 定时器系统
- 集群架构
- 全组件依赖关系

## 🚀 推荐学习路径

### 初学者路线（3-4周）
1. [完整学习路径](./tutorials/learning-path-guide.md) - 阅读第1-3章
2. [实践练习](./tutorials/practice-exercises.md) - 完成练习1-5
3. [模块示例](./guides/skynet_module_examples.md) - 运行基础示例

### 进阶开发者（4-5周）
1. [模块分析指南](./tutorials/module-analysis-guide.md) - 深入理解核心模块
2. [网络层架构](./architecture/skynet-network-layer-architecture.md) - 掌握网络编程
3. [实践练习](./tutorials/practice-exercises.md) - 完成练习6-9

### 架构师/专家（6-8周）
1. [完整架构分析](./architecture/skynet-complete-architecture-analysis.md) - 全面架构理解
2. [源码分析](./tutorials/module-analysis-guide.md) - C层深度研究
3. [高级练习](./tutorials/practice-exercises.md) - 练习10-11及进阶项目

## 🎓 学习检查清单

### 基础阶段
- [ ] 能够编译和运行 Skynet
- [ ] 理解 Actor 模型概念
- [ ] 会创建简单的 Lua 服务
- [ ] 掌握基本的服务间通信

### 进阶阶段
- [ ] 理解消息队列机制
- [ ] 掌握网络编程接口
- [ ] 能实现完整的网络服务
- [ ] 理解协程和异步编程

### 高级阶段
- [ ] 理解 C 层核心实现
- [ ] 掌握性能优化技巧
- [ ] 能设计分布式架构
- [ ] 完成至少一个完整项目

## 🔧 文档维护

### 更新记录
- 2024-09-27: 整理文档结构，新增教程和学习资源
- 2024-09-27: 添加网络层完整文档集
- 2024-09-25: 创建架构分析文档
- 2024-09-22: 初始化文档结构

### 文档规范
- 使用 Markdown 格式
- 架构图采用 Mermaid 绘制
- 代码示例包含完整注释
- 保持中文简体一致性

## 📚 外部资源

### 官方资源
- [Skynet GitHub](https://github.com/cloudwu/skynet) - 官方源码仓库
- [云风的博客](https://blog.codingnow.com/) - 作者技术博客

### 社区资源
- [Skynet Wiki](https://github.com/cloudwu/skynet/wiki) - 官方 Wiki
- 相关技术论坛和讨论组

## 🤝 贡献指南

欢迎贡献文档和示例代码！请确保：
1. 文档内容准确、清晰
2. 代码示例可运行
3. 图表格式正确
4. 遵循现有的文档结构和风格

---

*Skynet 文档中心持续更新，致力于提供最全面的学习资源。建议从 [完整学习路径](./tutorials/learning-path-guide.md) 开始你的 Skynet 之旅！*