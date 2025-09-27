# Skynet 架构图表集合

本文档包含 Skynet 框架的核心架构图表，用于理解系统的设计原理和运行机制。

## 1. 整体架构图

展示 Skynet 的分层架构设计，从底层 C 核心到上层业务逻辑。

```mermaid
graph TB
    subgraph "业务层 - Business Layer"
        App[业务应用<br/>Game Logic/Web Service]
        Custom[自定义服务<br/>Custom Services]
    end
    
    subgraph "Lua 服务层 - Lua Service Layer"
        Bootstrap[bootstrap<br/>启动服务]
        Launcher[launcher<br/>服务管理]
        Console[console<br/>调试控制台]
        Gate[gate<br/>网关服务]
        Logger[logger<br/>日志服务]
        Clusterd[clusterd<br/>集群管理]
    end
    
    subgraph "桥接层 - Bridge Layer"
        LualibSrc[lualib-src<br/>C-Lua接口]
        Skynet_lua[skynet.lua<br/>核心API]
        Snax[snax<br/>Actor框架]
        Sproto[sproto<br/>协议处理]
    end
    
    subgraph "C 核心层 - C Core Layer"
        subgraph "核心组件"
            SkynetMain[skynet_main.c<br/>主控制器]
            SkynetServer[skynet_server.c<br/>服务管理]
            SkynetMQ[skynet_mq.c<br/>消息队列]
            SkynetHandle[skynet_handle.c<br/>句柄管理]
        end
        
        subgraph "网络子系统"
            SkynetSocket[skynet_socket.c<br/>Socket封装]
            SocketServer[socket_server.c<br/>底层Socket]
        end
        
        subgraph "调度子系统"
            SkynetTimer[skynet_timer.c<br/>定时器系统]
            SkynetMonitor[skynet_monitor.c<br/>监控线程]
        end
        
        subgraph "C服务模块"
            Snlua[snlua<br/>Lua容器]
            GateC[gate<br/>网络网关]
            LoggerC[logger<br/>日志模块]
        end
    end
    
    subgraph "系统层 - System Layer"
        Lua[Lua 5.4.7<br/>脚本引擎]
        Jemalloc[jemalloc<br/>内存管理]
        OS[操作系统<br/>Linux/macOS/FreeBSD]
    end
    
    %% 连接关系
    App --> Custom
    Custom --> Bootstrap
    Custom --> Gate
    Bootstrap --> Launcher
    Launcher --> Console
    Gate --> Logger
    
    Bootstrap --> Skynet_lua
    Launcher --> Skynet_lua
    Console --> Skynet_lua
    Gate --> Snax
    Logger --> Sproto
    
    Skynet_lua --> LualibSrc
    Snax --> LualibSrc
    Sproto --> LualibSrc
    
    LualibSrc --> SkynetServer
    LualibSrc --> SkynetMQ
    SkynetServer --> SkynetHandle
    SkynetServer --> SkynetSocket
    SkynetMQ --> SkynetTimer
    
    SkynetSocket --> SocketServer
    SkynetTimer --> SkynetMonitor
    
    SkynetServer --> Snlua
    SkynetSocket --> GateC
    SkynetTimer --> LoggerC
    
    Snlua --> Lua
    SkynetMain --> Jemalloc
    SocketServer --> OS
    
    %% 样式设置
    classDef businessLayer fill:#e1f5fe,stroke:#0277bd,stroke-width:2px
    classDef luaLayer fill:#f3e5f5,stroke:#7b1fa2,stroke-width:2px
    classDef bridgeLayer fill:#fff3e0,stroke:#ef6c00,stroke-width:2px
    classDef coreLayer fill:#e8f5e8,stroke:#2e7d32,stroke-width:2px
    classDef systemLayer fill:#fce4ec,stroke:#c2185b,stroke-width:2px
    
    class App,Custom businessLayer
    class Bootstrap,Launcher,Console,Gate,Logger,Clusterd luaLayer
    class LualibSrc,Skynet_lua,Snax,Sproto bridgeLayer
    class SkynetMain,SkynetServer,SkynetMQ,SkynetHandle,SkynetSocket,SocketServer,SkynetTimer,SkynetMonitor,Snlua,GateC,LoggerC coreLayer
    class Lua,Jemalloc,OS systemLayer
```

## 2. 启动流程图

展示从 main() 函数开始的完整启动序列。

```mermaid
flowchart TD
    Start([程序启动]) --> ParseArgs[解析命令行参数]
    ParseArgs --> LoadConfig[加载配置文件<br/>config.lua]
    LoadConfig --> InitEnv{初始化环境}
    
    InitEnv --> InitMemory[初始化内存管理<br/>jemalloc]
    InitMemory --> InitModule[初始化模块系统<br/>skynet_module_init]
    InitModule --> InitMQ[初始化全局消息队列<br/>skynet_mq_init]
    InitMQ --> InitHandle[初始化句柄系统<br/>skynet_handle_init]
    InitHandle --> InitSocket[初始化Socket系统<br/>skynet_socket_init]
    InitSocket --> InitTimer[初始化定时器系统<br/>skynet_timer_init]
    
    InitTimer --> CreateThreads[创建线程池]
    CreateThreads --> MonitorThread[监控线程<br/>thread_monitor]
    CreateThreads --> TimerThread[定时器线程<br/>thread_timer]
    CreateThreads --> SocketThread[网络线程<br/>thread_socket]
    CreateThreads --> WorkerThreads[工作线程池<br/>thread_worker x N]
    
    MonitorThread --> StartBootstrap[启动Bootstrap服务]
    TimerThread --> StartBootstrap
    SocketThread --> StartBootstrap
    WorkerThreads --> StartBootstrap
    
    StartBootstrap --> LoadBootstrap[加载bootstrap.lua]
    LoadBootstrap --> InitServices[初始化核心服务]
    
    InitServices --> LauncherService[启动launcher服务]
    LauncherService --> ConsoleService[启动console服务]
    ConsoleService --> LoggerService[启动logger服务]
    LoggerService --> OtherServices[启动其他配置服务]
    
    OtherServices --> MainLoop[进入主循环<br/>skynet_main_loop]
    MainLoop --> WaitMessage[等待消息处理]
    WaitMessage --> ProcessMessage[处理消息]
    ProcessMessage --> WaitMessage
    
    ProcessMessage --> Shutdown{收到退出信号?}
    Shutdown -->|是| Cleanup[清理资源]
    Shutdown -->|否| WaitMessage
    
    Cleanup --> StopServices[停止所有服务]
    StopServices --> StopThreads[停止所有线程]
    StopThreads --> FreeMemory[释放内存]
    FreeMemory --> Exit([程序退出])
    
    %% 样式设置
    classDef startEnd fill:#ffcdd2,stroke:#d32f2f,stroke-width:2px
    classDef process fill:#c8e6c9,stroke:#388e3c,stroke-width:2px
    classDef decision fill:#fff9c4,stroke:#f57f17,stroke-width:2px
    classDef thread fill:#e1bee7,stroke:#8e24aa,stroke-width:2px
    
    class Start,Exit startEnd
    class ParseArgs,LoadConfig,InitMemory,InitModule,InitMQ,InitHandle,InitSocket,InitTimer,LoadBootstrap,InitServices,LauncherService,ConsoleService,LoggerService,OtherServices,MainLoop,WaitMessage,ProcessMessage,Cleanup,StopServices,StopThreads,FreeMemory process
    class InitEnv,Shutdown decision
    class CreateThreads,MonitorThread,TimerThread,SocketThread,WorkerThreads,StartBootstrap thread
```

## 3. 消息传递序列图

展示服务间消息传递的完整流程。

```mermaid
sequenceDiagram
    participant Client as 客户端服务
    participant MQ as 消息队列系统
    participant Scheduler as 调度器
    participant Target as 目标服务
    participant Timer as 定时器系统
    
    Note over Client, Timer: skynet.send 异步消息发送
    
    Client->>+MQ: skynet.send(target, type, msg)
    MQ->>MQ: 打包消息
    MQ->>MQ: 获取目标服务队列
    MQ->>-Scheduler: 将消息放入目标队列
    
    Scheduler->>+Target: 调度执行
    Target->>Target: 处理消息
    Target->>-Scheduler: 处理完成
    
    Note over Client, Timer: skynet.call 同步消息调用
    
    Client->>+MQ: skynet.call(target, type, msg)
    MQ->>MQ: 生成session ID
    MQ->>MQ: 打包消息和session
    MQ->>Scheduler: 将消息放入目标队列
    
    Client->>+Timer: 设置超时定时器
    
    Scheduler->>+Target: 调度执行
    Target->>Target: 处理消息
    Target->>MQ: skynet.ret(response)
    Target->>-Scheduler: 处理完成
    
    MQ->>MQ: 根据session ID路由
    MQ->>-Client: 返回响应消息
    
    Timer->>-Client: 取消超时定时器
    
    Note over Client, Timer: 跨节点消息传递 (Harbor)
    
    Client->>+MQ: skynet.send(remote_addr, type, msg)
    MQ->>MQ: 检测远程地址
    MQ->>+Scheduler: 路由到harbor服务
    
    Scheduler->>+Target: harbor服务处理
    Target->>Target: 序列化消息
    Target->>Target: 通过网络发送
    Target->>-Scheduler: 发送完成
    
    Note over Target: 远程节点接收
    Target->>Target: 反序列化消息
    Target->>MQ: 投递到本地服务
    MQ->>-Scheduler: 本地调度处理
    
    Note over Client, Timer: 错误处理流程
    
    Client->>+MQ: 发送消息
    MQ->>MQ: 检查目标服务
    
    alt 服务不存在
        MQ->>Client: 返回错误
    else 服务队列满
        MQ->>Client: 返回队列满错误
    else 消息格式错误
        MQ->>-Client: 返回格式错误
    end
```

## 4. 线程模型和调度图

展示各种线程类型的关系和交互。

```mermaid
graph TB
    subgraph "主线程 - Main Thread"
        MainLoop[主循环<br/>skynet_main_loop]
        Scheduler[消息调度器<br/>Scheduler]
    end
    
    subgraph "监控线程 - Monitor Thread"
        Monitor[监控线程<br/>thread_monitor]
        CheckDead[检查死锁服务]
        KillDead[清理死锁服务]
    end
    
    subgraph "定时器线程 - Timer Thread"
        TimerLoop[定时器循环<br/>thread_timer]
        TimeWheel[时间轮调度<br/>Time Wheel]
        TimerEvent[触发定时事件]
    end
    
    subgraph "网络线程 - Socket Thread"
        SocketLoop[Socket循环<br/>thread_socket]
        EpollWait[epoll_wait监听]
        NetworkEvent[网络事件处理]
    end
    
    subgraph "工作线程池 - Worker Thread Pool"
        Worker1[工作线程1<br/>thread_worker]
        Worker2[工作线程2<br/>thread_worker]
        WorkerN[工作线程N<br/>thread_worker]
    end
    
    subgraph "全局资源 - Global Resources"
        GlobalMQ[全局消息队列<br/>Global Message Queue]
        ServiceMQ[服务消息队列<br/>Service Message Queue]
        HandleMgr[句柄管理器<br/>Handle Manager]
        TimerMgr[定时器管理<br/>Timer Manager]
        SocketMgr[Socket管理器<br/>Socket Manager]
    end
    
    %% 主线程交互
    MainLoop --> Scheduler
    Scheduler --> GlobalMQ
    Scheduler --> ServiceMQ
    Scheduler --> HandleMgr
    
    %% 监控线程交互
    Monitor --> CheckDead
    CheckDead --> KillDead
    KillDead --> HandleMgr
    Monitor -.->|检查服务状态| ServiceMQ
    
    %% 定时器线程交互
    TimerLoop --> TimeWheel
    TimeWheel --> TimerEvent
    TimerEvent --> TimerMgr
    TimerMgr --> GlobalMQ
    
    %% 网络线程交互
    SocketLoop --> EpollWait
    EpollWait --> NetworkEvent
    NetworkEvent --> SocketMgr
    SocketMgr --> GlobalMQ
    
    %% 工作线程交互
    Worker1 --> GlobalMQ
    Worker2 --> GlobalMQ
    WorkerN --> GlobalMQ
    
    Worker1 --> ServiceMQ
    Worker2 --> ServiceMQ
    WorkerN --> ServiceMQ
    
    %% 线程间通信
    Scheduler -.->|分配任务| Worker1
    Scheduler -.->|分配任务| Worker2
    Scheduler -.->|分配任务| WorkerN
    
    TimerMgr -.->|定时消息| Scheduler
    SocketMgr -.->|网络消息| Scheduler
    Monitor -.->|监控消息| Scheduler
    
    %% 样式设置
    classDef mainThread fill:#e3f2fd,stroke:#1976d2,stroke-width:2px
    classDef monitorThread fill:#f3e5f5,stroke:#7b1fa2,stroke-width:2px
    classDef timerThread fill:#e8f5e8,stroke:#2e7d32,stroke-width:2px
    classDef socketThread fill:#fff3e0,stroke:#ef6c00,stroke-width:2px
    classDef workerThread fill:#fce4ec,stroke:#c2185b,stroke-width:2px
    classDef globalResource fill:#f9fbe7,stroke:#689f38,stroke-width:2px
    
    class MainLoop,Scheduler mainThread
    class Monitor,CheckDead,KillDead monitorThread
    class TimerLoop,TimeWheel,TimerEvent timerThread
    class SocketLoop,EpollWait,NetworkEvent socketThread
    class Worker1,Worker2,WorkerN workerThread
    class GlobalMQ,ServiceMQ,HandleMgr,TimerMgr,SocketMgr globalResource
```

## 5. 服务生命周期状态图

展示服务从创建到销毁的完整生命周期。

```mermaid
stateDiagram-v2
    [*] --> Created : 创建服务请求
    
    Created --> Loading : 加载服务模块
    Loading --> LoadFailed : 模块加载失败
    LoadFailed --> [*] : 清理资源
    
    Loading --> Initializing : 模块加载成功
    Initializing --> InitFailed : 初始化失败
    InitFailed --> [*] : 清理资源
    
    Initializing --> Ready : 初始化成功
    Ready --> Running : 开始处理消息
    
    state Running {
        [*] --> Idle : 等待消息
        Idle --> Processing : 接收消息
        Processing --> Idle : 消息处理完成
        Processing --> Blocked : 等待响应
        Blocked --> Processing : 收到响应
        Blocked --> Timeout : 超时
        Timeout --> Processing : 继续处理
        
        Processing --> Error : 处理错误
        Error --> Processing : 错误恢复
        Error --> Dying : 严重错误
    }
    
    Running --> Suspending : 暂停服务
    Suspending --> Suspended : 暂停完成
    Suspended --> Running : 恢复服务
    
    Running --> Dying : 服务退出请求
    Suspended --> Dying : 服务退出请求
    
    state Dying {
        [*] --> Cleanup : 清理资源
        Cleanup --> CloseSocket : 关闭网络连接
        CloseSocket --> CancelTimer : 取消定时器
        CancelTimer --> FlushMessage : 处理剩余消息
        FlushMessage --> ReleaseMemory : 释放内存
        ReleaseMemory --> [*]
    }
    
    Dying --> Dead : 清理完成
    Dead --> [*] : 服务销毁
    
    note right of Created
        服务句柄分配
        模块查找
    end note
    
    note right of Loading
        加载.so/.lua文件
        符号解析
    end note
    
    note right of Initializing
        调用init函数
        注册消息处理器
    end note
    
    note right of Running
        消息循环处理
        协程调度
    end note
    
    note right of Dying
        优雅关闭流程
        资源释放
    end note
```

## 6. 网络架构图

展示 Socket Server、Gate、Agent 的关系和数据流。

```mermaid
graph TB
    subgraph "客户端层 - Client Layer"
        Client1[客户端1<br/>TCP连接]
        Client2[客户端2<br/>TCP连接]
        ClientN[客户端N<br/>TCP连接]
    end
    
    subgraph "网络接入层 - Network Access Layer"
        subgraph "Socket Server"
            SocketFD1[Socket FD 1]
            SocketFD2[Socket FD 2]
            SocketFDN[Socket FD N]
            EpollMgr[Epoll管理器<br/>事件监听]
        end
        
        subgraph "Gate Service"
            GateMain[Gate主服务<br/>连接管理]
            ConnMgr[连接管理器<br/>Connection Manager]
            Protocol[协议处理<br/>Protocol Handler]
        end
    end
    
    subgraph "业务处理层 - Business Logic Layer"
        subgraph "Agent Pool"
            Agent1[Agent1<br/>用户会话1]
            Agent2[Agent2<br/>用户会话2]
            AgentN[AgentN<br/>用户会话N]
        end
        
        subgraph "Game Services"
            LoginSvc[登录服务<br/>Login Service]
            GameSvc[游戏服务<br/>Game Service]
            ChatSvc[聊天服务<br/>Chat Service]
        end
    end
    
    subgraph "数据存储层 - Data Layer"
        Database[(数据库<br/>Database)]
        Redis[(Redis<br/>缓存)]
        FileStore[(文件存储<br/>File Storage)]
    end
    
    %% 网络数据流
    Client1 -.->|TCP连接| SocketFD1
    Client2 -.->|TCP连接| SocketFD2
    ClientN -.->|TCP连接| SocketFDN
    
    SocketFD1 --> EpollMgr
    SocketFD2 --> EpollMgr
    SocketFDN --> EpollMgr
    
    EpollMgr -->|网络事件| GateMain
    GateMain --> ConnMgr
    ConnMgr --> Protocol
    
    %% 连接到Agent的映射
    Protocol -->|创建会话| Agent1
    Protocol -->|创建会话| Agent2
    Protocol -->|创建会话| AgentN
    
    %% Agent到业务服务
    Agent1 --> LoginSvc
    Agent1 --> GameSvc
    Agent1 --> ChatSvc
    
    Agent2 --> LoginSvc
    Agent2 --> GameSvc
    Agent2 --> ChatSvc
    
    AgentN --> LoginSvc
    AgentN --> GameSvc
    AgentN --> ChatSvc
    
    %% 业务服务到数据层
    LoginSvc --> Database
    LoginSvc --> Redis
    
    GameSvc --> Database
    GameSvc --> Redis
    GameSvc --> FileStore
    
    ChatSvc --> Redis
    ChatSvc --> Database
    
    %% 消息回流
    Agent1 -.->|响应消息| Protocol
    Agent2 -.->|响应消息| Protocol
    AgentN -.->|响应消息| Protocol
    
    Protocol -.->|数据包| EpollMgr
    EpollMgr -.->|发送数据| SocketFD1
    EpollMgr -.->|发送数据| SocketFD2
    EpollMgr -.->|发送数据| SocketFDN
    
    %% 广播和推送
    GameSvc -.->|广播消息| Agent1
    GameSvc -.->|广播消息| Agent2
    ChatSvc -.->|聊天消息| Agent1
    ChatSvc -.->|聊天消息| AgentN
    
    %% 样式设置
    classDef clientLayer fill:#ffebee,stroke:#c62828,stroke-width:2px
    classDef networkLayer fill:#e8eaf6,stroke:#3f51b5,stroke-width:2px
    classDef businessLayer fill:#e0f2e1,stroke:#388e3c,stroke-width:2px
    classDef dataLayer fill:#fff3e0,stroke:#f57c00,stroke-width:2px
    
    class Client1,Client2,ClientN clientLayer
    class SocketFD1,SocketFD2,SocketFDN,EpollMgr,GateMain,ConnMgr,Protocol networkLayer
    class Agent1,Agent2,AgentN,LoginSvc,GameSvc,ChatSvc businessLayer
    class Database,Redis,FileStore dataLayer
```

## 7. 核心组件关系图

展示核心数据结构之间的关系。

```mermaid
erDiagram
    skynet_context {
        uint32_t handle "服务句柄"
        struct_skynet_module module "服务模块"
        void_pointer instance "服务实例"
        struct_message_queue queue "消息队列"
        int ref "引用计数"
        int message_count "消息计数"
        bool init "是否已初始化"
        bool endless "是否无限循环"
        uint64_t cpu_cost "CPU消耗统计"
        uint64_t cpu_start "CPU开始时间"
        char result[32] "结果缓存"
    }
    
    message_queue {
        struct_spinlock lock "自旋锁"
        uint32_t handle "所属服务句柄"
        int cap "队列容量"
        int head "队列头"
        int tail "队列尾"
        int release "释放标志"
        int in_global "是否在全局队列"
        struct_skynet_message queue "消息数组"
    }
    
    skynet_message {
        uint32_t source "发送方句柄"
        int session "会话ID"
        int type "消息类型"
        size_t sz "消息大小"
        void_pointer data "消息数据"
    }
    
    skynet_module {
        char name[32] "模块名称"
        void_pointer module "动态库句柄"
        skynet_dl_create create "创建函数"
        skynet_dl_init init "初始化函数"
        skynet_dl_release release "释放函数"
        skynet_dl_signal signal "信号函数"
    }
    
    skynet_handle {
        rwlock_t lock "读写锁"
        uint32_t harbor "Harbor节点ID"
        uint32_t handle_index "句柄索引"
        struct_handle_storage storage "存储结构"
    }
    
    handle_storage {
        struct_rwlock lock "读写锁"
        uint32_t slot_size "槽位大小"
        struct_skynet_context slots "上下文槽位"
    }
    
    global_queue {
        struct_message_queue head "队列头指针"
        struct_message_queue tail "队列尾指针" 
        struct_spinlock lock "自旋锁"
    }
    
    socket_server {
        int recvctrl_fd "接收控制描述符"
        int sendctrl_fd "发送控制描述符"
        int checkctrl "检查控制"
        poll_fd event_fd "事件文件描述符"
        int alloc_id "分配ID"
        int event_n "事件数量"
        int event_index "事件索引"
        struct_socket slot "Socket槽位"
    }
    
    timer_node {
        struct_timer_event event "定时器事件"
        uint32_t handle "服务句柄"
        int session "会话ID"
        uint64_t expire "过期时间"
    }
    
    %% 关系定义
    skynet_context ||--|| skynet_module : "belongs_to"
    skynet_context ||--|| message_queue : "owns"
    skynet_context }|--|| skynet_handle : "managed_by"
    
    message_queue ||--o{ skynet_message : "contains"
    message_queue }|--|| global_queue : "linked_to"
    
    skynet_handle ||--|| handle_storage : "uses"
    handle_storage ||--o{ skynet_context : "stores"
    
    timer_node }|--|| skynet_context : "targets"
    
    socket_server ||--o{ skynet_context : "serves"
```

## 8. 消息队列架构图

展示二级队列架构的设计。

```mermaid
graph TB
    subgraph "发送端 - Sender Side"
        Service1[服务1<br/>Service 1]
        Service2[服务2<br/>Service 2]
        ServiceN[服务N<br/>Service N]
    end
    
    subgraph "全局队列层 - Global Queue Layer"
        GlobalQueue[全局消息队列<br/>Global Message Queue]
        
        subgraph "队列操作"
            Push[入队操作<br/>skynet_globalmq_push]
            Pop[出队操作<br/>skynet_globalmq_pop]
            Length[队列长度<br/>skynet_globalmq_length]
        end
        
        QueueLock[全局队列锁<br/>Spinlock]
    end
    
    subgraph "服务队列层 - Service Queue Layer"
        subgraph "目标服务A"
            ServiceQueueA[服务队列A<br/>Message Queue A]
            ServiceLockA[队列锁A<br/>Spinlock A]
        end
        
        subgraph "目标服务B"
            ServiceQueueB[服务队列B<br/>Message Queue B]
            ServiceLockB[队列锁B<br/>Spinlock B]
        end
        
        subgraph "目标服务C"
            ServiceQueueC[服务队列C<br/>Message Queue C]
            ServiceLockC[队列锁C<br/>Spinlock C]
        end
    end
    
    subgraph "调度器 - Scheduler"
        MainScheduler[主调度器<br/>Main Scheduler]
        WorkerPool[工作线程池<br/>Worker Thread Pool]
        
        subgraph "调度策略"
            RoundRobin[轮询调度<br/>Round Robin]
            Priority[优先级调度<br/>Priority Based]
            Weight[权重调度<br/>Weight Based]
        end
    end
    
    subgraph "消息处理 - Message Processing"
        MessageHandler[消息处理器<br/>Message Handler]
        CoroutinePool[协程池<br/>Coroutine Pool]
        
        subgraph "处理类型"
            LuaMsg[Lua消息<br/>PTYPE_LUA]
            ResponseMsg[响应消息<br/>PTYPE_RESPONSE]  
            SystemMsg[系统消息<br/>PTYPE_SYSTEM]
            SocketMsg[Socket消息<br/>PTYPE_SOCKET]
        end
    end
    
    %% 消息流向
    Service1 -->|skynet.send| Push
    Service2 -->|skynet.send| Push  
    ServiceN -->|skynet.send| Push
    
    Push --> QueueLock
    QueueLock --> GlobalQueue
    
    Pop --> GlobalQueue
    GlobalQueue --> Pop
    
    %% 从全局队列到服务队列
    Pop -->|路由到目标服务| ServiceLockA
    Pop -->|路由到目标服务| ServiceLockB
    Pop -->|路由到目标服务| ServiceLockC
    
    ServiceLockA --> ServiceQueueA
    ServiceLockB --> ServiceQueueB
    ServiceLockC --> ServiceQueueC
    
    %% 调度器处理
    MainScheduler --> Pop
    MainScheduler --> RoundRobin
    MainScheduler --> Priority
    MainScheduler --> Weight
    
    RoundRobin --> WorkerPool
    Priority --> WorkerPool
    Weight --> WorkerPool
    
    %% 工作线程处理
    WorkerPool --> ServiceQueueA
    WorkerPool --> ServiceQueueB
    WorkerPool --> ServiceQueueC
    
    ServiceQueueA --> MessageHandler
    ServiceQueueB --> MessageHandler
    ServiceQueueC --> MessageHandler
    
    MessageHandler --> CoroutinePool
    MessageHandler --> LuaMsg
    MessageHandler --> ResponseMsg
    MessageHandler --> SystemMsg
    MessageHandler --> SocketMsg
    
    %% 队列状态监控
    Length -.-> GlobalQueue
    ServiceQueueA -.->|队列统计| MainScheduler
    ServiceQueueB -.->|队列统计| MainScheduler
    ServiceQueueC -.->|队列统计| MainScheduler
    
    %% 样式设置
    classDef sender fill:#ffcdd2,stroke:#d32f2f,stroke-width:2px
    classDef globalQueue fill:#c8e6c9,stroke:#388e3c,stroke-width:2px
    classDef serviceQueue fill:#bbdefb,stroke:#1976d2,stroke-width:2px
    classDef scheduler fill:#f8bbd9,stroke:#e91e63,stroke-width:2px
    classDef processing fill:#fff9c4,stroke:#f57f17,stroke-width:2px
    
    class Service1,Service2,ServiceN sender
    class GlobalQueue,Push,Pop,Length,QueueLock globalQueue
    class ServiceQueueA,ServiceLockA,ServiceQueueB,ServiceLockB,ServiceQueueC,ServiceLockC serviceQueue
    class MainScheduler,WorkerPool,RoundRobin,Priority,Weight scheduler
    class MessageHandler,CoroutinePool,LuaMsg,ResponseMsg,SystemMsg,SocketMsg processing
```

## 9. 定时器系统图

展示分层时间轮算法的实现（Skynet使用的是5级时间轮）。

```mermaid
graph TB
    subgraph "定时器接口层 - Timer Interface Layer"
        StartTimer[skynet.timeout<br/>启动定时器]
        CancelTimer[取消定时器<br/>内部管理]  
        SleepTimer[skynet.sleep<br/>睡眠等待]
        WakeupTimer[skynet.wakeup<br/>唤醒服务]
    end
    
    subgraph "时间轮管理器 - Time Wheel Manager"
        TimerMgr[定时器管理器<br/>struct timer]
        
        subgraph "五级时间轮结构"
            Near[near数组<br/>第0级: 256个槽位<br/>每个槽位=10ms]
            T1[t数组第0层<br/>第1级: 64个槽位<br/>每个槽位=2.56秒]
            T2[t数组第1层<br/>第2级: 64个槽位<br/>每个槽位=163.84秒]  
            T3[t数组第2层<br/>第3级: 64个槽位<br/>每个槽位=10485.76秒]
            T4[t数组第3层<br/>第4级: 64个槽位<br/>每个槽位=671088.64秒]
        end
        
        CurrentTime[time字段<br/>当前时间刻度]
        StartTime[starttime字段<br/>系统启动时间]
    end
    
    subgraph "定时器节点 - Timer Nodes"
        subgraph "timer_node结构"
            Handle[handle<br/>服务句柄]
            Session[session<br/>会话ID]
            ExpireNode[expire<br/>过期时间]
        end
        
        TimerList[timer_event链表<br/>Link List]
    end
    
    subgraph "定时器线程 - Timer Thread"
        TimerThread[thread_timer<br/>定时器线程]
        
        subgraph "主循环处理"
            SysSleep[系统睡眠<br/>2500us]
            UpdateTime[timer_update<br/>更新时间]
            Execute[timer_execute<br/>执行到期定时器]
            Shift[timer_shift<br/>时间轮级联]
        end
    end
    
    subgraph "消息系统集成"
        DispatchList[dispatch_list<br/>待分发链表]
        MessageSend[消息发送<br/>PTYPE_RESPONSE]
        TargetService[目标服务<br/>Target Service]
    end
    
    %% 定时器创建流程
    StartTimer --> TimerMgr
    TimerMgr --> |skynet_timer_add| Handle
    Handle --> Session
    Session --> ExpireNode
    
    %% 根据过期时间插入对应层级
    ExpireNode -->|计算间隔| Near
    ExpireNode -->|间隔大于256| T1
    ExpireNode -->|间隔大于16384| T2
    ExpireNode -->|间隔大于1048576| T3
    ExpireNode -->|间隔大于67108864| T4
    
    Near --> TimerList
    T1 --> TimerList
    T2 --> TimerList
    T3 --> TimerList
    T4 --> TimerList
    
    %% 定时器线程执行
    TimerThread --> SysSleep
    SysSleep --> UpdateTime
    UpdateTime --> CurrentTime
    
    CurrentTime --> Execute
    Execute --> |检查near索引| Near
    Near -->|到期节点| DispatchList
    
    %% 级联操作
    Execute --> Shift
    Shift -->|near满256槽| T1
    T1 -->|移动到near| Near
    
    Shift -->|T1满64槽| T2
    T2 -->|移动到T1| T1
    
    Shift -->|T2满64槽| T3
    T3 -->|移动到T2| T2
    
    Shift -->|T3满64槽| T4
    T4 -->|移动到T3| T3
    
    %% 消息发送
    DispatchList --> MessageSend
    MessageSend --> TargetService
    
    %% 更新循环
    Execute --> UpdateTime
    
    %% 样式设置
    classDef interface fill:#e1f5fe,stroke:#0277bd,stroke-width:2px
    classDef wheelMgr fill:#f3e5f5,stroke:#7b1fa2,stroke-width:2px
    classDef timerNode fill:#fff3e0,stroke:#ef6c00,stroke-width:2px
    classDef timerThread fill:#e8f5e8,stroke:#2e7d32,stroke-width:2px
    classDef messaging fill:#fce4ec,stroke:#c2185b,stroke-width:2px
    
    class StartTimer,CancelTimer,SleepTimer,WakeupTimer interface
    class TimerMgr,Near,T1,T2,T3,T4,CurrentTime,StartTime wheelMgr
    class Handle,Session,ExpireNode,TimerList timerNode
    class TimerThread,SysSleep,UpdateTime,Execute,Shift timerThread
    class DispatchList,MessageSend,TargetService messaging
```

## 10. 集群架构图

展示 Harbor 系统和多节点通信架构（Skynet的分布式实现）。

```mermaid
graph TB
    subgraph "节点1 - Node 1 (Harbor ID: 1)"
        subgraph "Master节点"
            Master[cmaster服务<br/>Harbor Master]
            NameServer[全局名字服务<br/>Name Server]
        end
        
        subgraph "Harbor层1"
            Harbor1[harbor服务<br/>节点间通信]
            HarborM1[harbor_master<br/>主节点管理]
        end
        
        subgraph "业务服务1"
            Service1A[服务1A<br/>handle: 0x01000001]
            Service1B[服务1B<br/>handle: 0x01000002]
        end
    end
    
    subgraph "节点2 - Node 2 (Harbor ID: 2)"
        subgraph "Slave节点"
            Slave2[cslave服务<br/>Harbor Slave]
        end
        
        subgraph "Harbor层2"
            Harbor2[harbor服务<br/>节点间通信]
            HarborM2[harbor_slave<br/>从节点管理]
        end
        
        subgraph "业务服务2"
            Service2A[服务2A<br/>handle: 0x02000001]
            Service2B[服务2B<br/>handle: 0x02000002]
        end
    end
    
    subgraph "节点3 - Node 3 (Harbor ID: 3)"
        subgraph "Slave节点3"
            Slave3[cslave服务<br/>Harbor Slave]
        end
        
        subgraph "Harbor层3"
            Harbor3[harbor服务<br/>节点间通信]
            HarborM3[harbor_slave<br/>从节点管理]
        end
        
        subgraph "业务服务3"
            Service3A[服务3A<br/>handle: 0x03000001]
            Service3B[服务3B<br/>handle: 0x03000002]
        end
    end
    
    subgraph "Harbor协议层 - Harbor Protocol"
        subgraph "消息类型"
            RemoteRequest[远程请求<br/>TYPE_REQUEST]
            RemoteResponse[远程响应<br/>TYPE_RESPONSE]
            RemoteError[远程错误<br/>TYPE_ERROR]
        end
        
        subgraph "名字服务"
            NameQuery[名字查询<br/>QUERYNAME]
            NameUpdate[名字更新<br/>UPDATE]
            NameReg[名字注册<br/>REGISTER]
        end
    end
    
    subgraph "传输层 - Transport Layer"
        TCPChannel[TCP通道<br/>可靠传输]
        MsgPack[消息打包<br/>skynet_pack]
        MsgUnpack[消息解包<br/>skynet_unpack]
    end
    
    %% Master-Slave连接
    Master -->|控制连接| HarborM1
    HarborM1 <--> TCPChannel
    TCPChannel <--> HarborM2
    HarborM2 -->|状态上报| Slave2
    
    TCPChannel <--> HarborM3
    HarborM3 -->|状态上报| Slave3
    
    %% Harbor间通信
    Harbor1 <-->|节点间消息| Harbor2
    Harbor2 <-->|节点间消息| Harbor3
    Harbor3 <-->|节点间消息| Harbor1
    
    %% 本地服务到Harbor
    Service1A -->|远程调用| Harbor1
    Service1B -->|远程调用| Harbor1
    
    Service2A -->|远程调用| Harbor2
    Service2B -->|远程调用| Harbor2
    
    Service3A -->|远程调用| Harbor3
    Service3B -->|远程调用| Harbor3
    
    %% Harbor到远程服务
    Harbor1 -->|路由到目标| Service2A
    Harbor2 -->|路由到目标| Service3A
    Harbor3 -->|路由到目标| Service1A
    
    %% 名字服务流程
    Service1A -.->|注册名字| NameServer
    NameServer --> NameReg
    NameReg --> Master
    
    Service2A -.->|查询名字| NameServer
    NameServer --> NameQuery
    NameQuery --> NameUpdate
    
    %% 协议处理
    Harbor1 --> MsgPack
    MsgPack --> RemoteRequest
    RemoteRequest --> TCPChannel
    
    TCPChannel --> MsgUnpack
    MsgUnpack --> RemoteResponse
    RemoteResponse --> Harbor2
    
    %% 错误处理
    Harbor3 -.->|连接断开| RemoteError
    RemoteError -.->|错误传播| Service3A
    
    %% 样式设置
    classDef master fill:#ffebee,stroke:#c62828,stroke-width:3px
    classDef slave fill:#e8f5e9,stroke:#2e7d32,stroke-width:2px
    classDef harbor fill:#e3f2fd,stroke:#1565c0,stroke-width:2px
    classDef protocol fill:#fff3e0,stroke:#ef6c00,stroke-width:2px
    classDef transport fill:#f3e5f5,stroke:#7b1fa2,stroke-width:2px
    classDef service fill:#fafafa,stroke:#616161,stroke-width:1px
    
    class Master,NameServer,HarborM1 master
    class Slave2,Slave3,HarborM2,HarborM3 slave
    class Harbor1,Harbor2,Harbor3 harbor
    class RemoteRequest,RemoteResponse,RemoteError,NameQuery,NameUpdate,NameReg protocol
    class TCPChannel,MsgPack,MsgUnpack transport
    class Service1A,Service1B,Service2A,Service2B,Service3A,Service3B service
```

## 11. 全组件依赖关系图

展示 Skynet 所有核心组件之间的详细依赖关系。

```mermaid
graph LR
    subgraph "C 核心组件依赖"
        skynet_main[skynet_main.c<br/>主入口]
        skynet_start[skynet_start.c<br/>启动管理]
        skynet_server[skynet_server.c<br/>服务管理]
        skynet_context[skynet_context<br/>服务上下文]
        skynet_mq[skynet_mq.c<br/>消息队列]
        skynet_handle[skynet_handle.c<br/>句柄管理]
        skynet_module[skynet_module.c<br/>模块管理]
        skynet_timer[skynet_timer.c<br/>定时器]
        skynet_socket[skynet_socket.c<br/>Socket封装]
        socket_server[socket_server.c<br/>底层Socket]
        skynet_monitor[skynet_monitor.c<br/>监控]
        skynet_env[skynet_env.c<br/>环境变量]
        skynet_malloc[skynet_malloc.h<br/>内存管理]
        skynet_log[skynet_log.c<br/>日志系统]
    end
    
    subgraph "C 服务模块"
        service_snlua[service_snlua.c<br/>Lua容器]
        service_gate[service_gate.c<br/>网关服务]
        service_logger[service_logger.c<br/>日志服务]
        service_harbor[service_harbor.c<br/>集群服务]
    end
    
    subgraph "Lua-C 桥接层"
        lua_skynet[lua-skynet.c<br/>Skynet API]
        lua_socket[lua-socket.c<br/>Socket API]
        lua_memory[lua-memory.c<br/>内存API]
        lua_sharedata[lua-sharedata.c<br/>共享数据]
        lua_multicast[lua-multicast.c<br/>多播]
        lua_cluster[lua-cluster.c<br/>集群API]
        lua_netpack[lua-netpack.c<br/>网络包]
    end
    
    subgraph "Lua 核心库"
        skynet_lua[skynet.lua<br/>核心API]
        bootstrap[bootstrap.lua<br/>启动脚本]
        launcher[launcher.lua<br/>服务启动器]
        manager[manager.lua<br/>服务管理器]
        gate_lua[gate.lua<br/>网关实现]
        console[console.lua<br/>调试控制台]
    end
    
    subgraph "第三方依赖"
        lua54[Lua 5.4.7<br/>脚本引擎]
        jemalloc[jemalloc<br/>内存分配器]
        pthread[系统线程库<br/>pthread]
        epoll[epoll/kqueue<br/>事件驱动]
    end
    
    %% 主启动依赖
    skynet_main --> skynet_env
    skynet_main --> skynet_start
    skynet_main --> lua54
    
    %% 启动管理依赖
    skynet_start --> skynet_server
    skynet_start --> skynet_mq
    skynet_start --> skynet_handle
    skynet_start --> skynet_module
    skynet_start --> skynet_timer
    skynet_start --> skynet_socket
    skynet_start --> skynet_monitor
    skynet_start --> pthread
    
    %% 服务管理依赖
    skynet_server --> skynet_context
    skynet_server --> skynet_mq
    skynet_server --> skynet_handle
    skynet_server --> skynet_module
    skynet_server --> skynet_log
    skynet_context --> skynet_malloc
    
    %% 消息队列依赖
    skynet_mq --> skynet_context
    skynet_mq --> skynet_malloc
    
    %% Socket依赖
    skynet_socket --> socket_server
    socket_server --> epoll
    socket_server --> skynet_malloc
    
    %% 定时器依赖
    skynet_timer --> skynet_mq
    skynet_timer --> pthread
    
    %% 监控依赖
    skynet_monitor --> skynet_context
    skynet_monitor --> pthread
    
    %% C服务依赖
    service_snlua --> lua54
    service_snlua --> skynet_server
    service_gate --> skynet_socket
    service_logger --> skynet_log
    service_harbor --> skynet_socket
    
    %% Lua-C桥接依赖
    lua_skynet --> skynet_server
    lua_skynet --> skynet_mq
    lua_socket --> skynet_socket
    lua_memory --> skynet_malloc
    lua_sharedata --> skynet_malloc
    lua_multicast --> skynet_mq
    lua_cluster --> skynet_socket
    lua_netpack --> skynet_socket
    
    %% Lua核心库依赖
    skynet_lua --> lua_skynet
    bootstrap --> skynet_lua
    launcher --> skynet_lua
    manager --> skynet_lua
    gate_lua --> lua_socket
    console --> skynet_lua
    
    %% 内存管理依赖
    skynet_malloc --> jemalloc
    
    %% 样式设置
    classDef coreComp fill:#ffebee,stroke:#d32f2f,stroke-width:2px
    classDef cService fill:#e8f5e9,stroke:#388e3c,stroke-width:2px
    classDef bridge fill:#e3f2fd,stroke:#1976d2,stroke-width:2px
    classDef luaLib fill:#fce4ec,stroke:#c2185b,stroke-width:2px
    classDef thirdParty fill:#fff3e0,stroke:#f57c00,stroke-width:2px
    
    class skynet_main,skynet_start,skynet_server,skynet_context,skynet_mq,skynet_handle,skynet_module,skynet_timer,skynet_socket,socket_server,skynet_monitor,skynet_env,skynet_malloc,skynet_log coreComp
    class service_snlua,service_gate,service_logger,service_harbor cService
    class lua_skynet,lua_socket,lua_memory,lua_sharedata,lua_multicast,lua_cluster,lua_netpack bridge
    class skynet_lua,bootstrap,launcher,manager,gate_lua,console luaLib
    class lua54,jemalloc,pthread,epoll thirdParty
```

## 总结

以上10个架构图表从不同维度展示了Skynet框架的设计原理：

1. **整体架构图**：展现了分层设计思想，从底层C核心到上层业务逻辑的完整技术栈
2. **启动流程图**：详细描述了系统初始化的各个阶段和关键步骤
3. **消息传递序列图**：展示了异步/同步消息机制的实现原理
4. **线程模型图**：说明了多线程协作和资源共享的设计
5. **服务生命周期图**：描述了服务状态转换和管理机制
6. **网络架构图**：展现了从网络连接到业务处理的完整数据流
7. **核心组件关系图**：展示了关键数据结构之间的关联关系
8. **消息队列架构图**：详细说明了二级队列系统的设计理念
9. **定时器系统图**：展现了高效的分层时间轮算法实现
10. **集群架构图**：描述了分布式部署和节点间通信机制

这些图表为理解Skynet的架构设计和运行原理提供了可视化的参考资料，有助于开发者深入学习和使用这个优秀的游戏服务器框架。