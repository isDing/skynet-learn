# Skynet 文档中心

欢迎访问Skynet游戏服务器框架的文档中心。本目录包含了Skynet的架构分析、设计文档和学习指南。

## 📖 文档目录

### 核心架构文档

#### 🌐 [网络层文档](./network-layer-index.md)
Skynet网络层的完整文档集，包括：
- [网络层架构详解](./skynet-network-layer-architecture.md) - 深入解析网络层设计与实现
- [架构图表集合](./diagrams/network/) - 8个详细的Mermaid架构图
  - 网络层整体架构
  - Socket状态机
  - 数据收发流程
  - 线程交互机制
  - 内存管理策略

#### 🏗 [完整架构分析](./skynet-complete-architecture-analysis.md)
Skynet整体架构的全面分析，涵盖：
- Actor模型实现
- 消息队列机制
- 服务管理系统
- 多线程调度

### 开发指南

#### 📦 [模块系统](./require_module_lookup_guide.md)
详细解释Skynet的模块加载和查找机制：
- Lua require机制
- 模块路径配置
- 自定义加载器

#### 💻 [模块示例](./skynet_module_examples.md)
实用的Skynet模块开发示例：
- 服务创建模板
- 消息处理示例
- 常用API演示

### 架构图表

#### 📊 [图表总览](./diagrams/)
所有架构图表的集中存放地：
- `/network/` - 网络层架构图(9个文件)
- `/architecture/` - 整体架构图(待补充)
- `/service/` - 服务架构图(待补充)

## 🚀 快速开始

### 新手学习路径
1. **了解整体架构** - 阅读[完整架构分析](./skynet-complete-architecture-analysis.md)
2. **深入网络层** - 学习[网络层文档](./network-layer-index.md)
3. **实践开发** - 参考[模块示例](./skynet_module_examples.md)

### 架构师路径
1. **架构设计** - 研究各类架构图表
2. **性能优化** - 关注网络层和消息队列优化
3. **扩展开发** - 基于模块系统进行功能扩展

## 🔧 文档维护

### 文档规范
- 使用Markdown格式
- 架构图采用Mermaid绘制
- 代码示例包含完整注释

### 更新记录
- 2024-09-27: 添加网络层完整文档集
- 2024-09-25: 创建架构分析文档
- 2024-09-22: 初始化文档结构

## 📚 相关资源

### 官方资源
- [Skynet GitHub](https://github.com/cloudwu/skynet)
- [云风的博客](https://blog.codingnow.com/)

### 社区资源
- Skynet Wiki
- 相关论坛讨论

## 🤝 贡献指南

欢迎贡献文档和示例代码。请确保：
1. 文档内容准确、清晰
2. 代码示例可运行
3. 图表格式正确

---

*本文档中心持续更新，致力于提供最全面的Skynet学习资源。*