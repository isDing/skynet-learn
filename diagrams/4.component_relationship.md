# Skynet Component Relationship Diagram

```mermaid
erDiagram
    %% Core C Components
    SKYNET_MAIN {
        int thread_count
        string config_path
        string log_path
    }
    
    SKYNET_SERVER {
        string contexts
        string global_queue
        int service_count
    }
    
    SKYNET_MQ {
        string messages
        int queue_size
        int capacity
    }
    
    SKYNET_HANDLE {
        uint32_t handle_counter
        string handle_table
        int handle_size
    }
    
    SKYNET_SOCKET {
        int socket_fd
        string socket_server
        int event_count
    }
    
    SKYNET_TIMER {
        uint32_t time_counter
        string timer_list
        int timeout_count
    }
    
    SKYNET_MODULE {
        string module_name
        string module_handle
        string module_api
    }
    
    %% Service Structures
    SKYNET_CONTEXT {
        uint32_t handle
        string instance
        string module
        string queue
        string callback
        string callback_ud
    }
    
    MESSAGE {
        uint32_t source
        uint32_t destination
        int session
        int type
        string data
        int size
    }
    
    %% C Services
    SNLUA_SERVICE {
        string lua_state
        string service_path
        int service_id
    }
    
    GATE_SERVICE {
        int listen_port
        int max_connections
        string connections
    }
    
    LOGGER_SERVICE {
        string log_file
        int log_level
        string log_handle
    }
    
    HARBOR_SERVICE {
        int harbor_id
        string master_address
        string nodes
    }
    
    %% Lua Services
    BOOTSTRAP_SERVICE {
        string config
        string start_service
        boolean standalone
    }
    
    LAUNCHER_SERVICE {
        string services
        int service_count
        uint32_t next_handle
    }
    
    CONSOLE_SERVICE {
        int console_fd
        boolean running
    }
    
    CLUSTERD_SERVICE {
        string cluster_name
        string cluster_nodes
    }
    
    %% Relationships between Core Components
    SKYNET_MAIN ||--o{ SKYNET_SERVER : "creates"
    SKYNET_SERVER ||--o{ SKYNET_CONTEXT : "manages"
    SKYNET_SERVER ||--o{ SKYNET_MQ : "uses"
    SKYNET_SERVER ||--o{ SKYNET_HANDLE : "uses"
    SKYNET_SERVER ||--o{ SKYNET_SOCKET : "uses"
    SKYNET_SERVER ||--o{ SKYNET_TIMER : "uses"
    SKYNET_SERVER ||--o{ SKYNET_MODULE : "loads"
    
    %% Context relationships
    SKYNET_CONTEXT ||--|| SKYNET_HANDLE : "has"
    SKYNET_CONTEXT ||--|| SKYNET_MQ : "has"
    SKYNET_CONTEXT ||--o{ SKYNET_MODULE : "uses"
    SKYNET_CONTEXT ||--o{ MESSAGE : "processes"
    
    %% Message relationships
    SKYNET_MQ ||--o{ MESSAGE : "contains"
    MESSAGE }|--|| SKYNET_CONTEXT : "from"
    MESSAGE }|--|| SKYNET_CONTEXT : "to"
    
    %% C Service relationships
    SKYNET_CONTEXT ||--|| SNLUA_SERVICE : "can be"
    SKYNET_CONTEXT ||--|| GATE_SERVICE : "can be"
    SKYNET_CONTEXT ||--|| LOGGER_SERVICE : "can be"
    SKYNET_CONTEXT ||--|| HARBOR_SERVICE : "can be"
    
    %% Lua Service relationships (through SNLUA)
    SNLUA_SERVICE ||--|| BOOTSTRAP_SERVICE : "hosts"
    SNLUA_SERVICE ||--|| LAUNCHER_SERVICE : "hosts"
    SNLUA_SERVICE ||--|| CONSOLE_SERVICE : "hosts"
    SNLUA_SERVICE ||--|| CLUSTERD_SERVICE : "hosts"
    
    %% Service dependencies
    BOOTSTRAP_SERVICE ||--|| LAUNCHER_SERVICE : "starts"
    LAUNCHER_SERVICE ||--o{ SKYNET_CONTEXT : "creates"
    LAUNCHER_SERVICE ||--|| CONSOLE_SERVICE : "manages"
    LAUNCHER_SERVICE ||--|| CLUSTERD_SERVICE : "manages"
    
    %% Socket relationships
    SKYNET_SOCKET ||--|| GATE_SERVICE : "supports"
    GATE_SERVICE ||--o{ SNLUA_SERVICE : "proxies to"
    
    %% Harbor relationships
    HARBOR_SERVICE ||--|| CLUSTERD_SERVICE : "supports"
    HARBOR_SERVICE ||--o{ SKYNET_SOCKET : "uses for network"
    
    %% Logger relationships
    LOGGER_SERVICE ||--o{ SKYNET_CONTEXT : "serves all"
    
    %% Timer relationships
    SKYNET_TIMER ||--o{ SKYNET_CONTEXT : "triggers"
    
    %% Module relationships
    SKYNET_MODULE ||--o{ SNLUA_SERVICE : "loads"
    SKYNET_MODULE ||--o{ GATE_SERVICE : "loads"
    SKYNET_MODULE ||--o{ LOGGER_SERVICE : "loads"
    SKYNET_MODULE ||--o{ HARBOR_SERVICE : "loads"
```

## Component Relationships Explained

### Core System Components
- **skynet_main**: Entry point that initializes and manages the entire system
- **skynet_server**: Central service management and message dispatch
- **skynet_mq**: Message queue implementation for inter-service communication
- **skynet_handle**: Service handle management and lookup
- **skynet_socket**: Network socket handling and I/O operations
- **skynet_timer**: Timer system for scheduled operations
- **skynet_module**: Dynamic module loading system

### Service Context
- **skynet_context**: Represents a running service instance
- **message**: Data structure for inter-service communication
- Each context has its own message queue, handle, and callback functions

### C Services
- **snlua**: Lua container service that hosts Lua services
- **gate**: Network gateway for client connections
- **logger**: Centralized logging service
- **harbor**: Multi-node coordination service

### Lua Services
- **bootstrap**: Initial service launcher
- **launcher**: Service creation and management hub
- **console**: Debug console service
- **clusterd**: Cluster management service

### Key Relationships

#### Management Relationships
- skynet_main creates and manages skynet_server
- skynet_server manages all service contexts
- launcher creates and manages other services
- bootstrap starts the launcher service

#### Communication Relationships
- Services communicate through message queues
- Each service has its own dedicated message queue
- Messages are routed through the global queue system

#### Dependencies
- C services depend on core C components
- Lua services run within snlua containers
- All services can use the logger service
- Harbor service enables cluster communication

#### Resource Management
- Timer system triggers timed events for services
- Socket system handles network I/O
- Handle system provides unique service identifiers
- Module system loads service implementations

## Architecture Benefits

### Isolation
- Each service runs in its own context
- No shared memory between services
- Communication only through message passing

### Scalability
- Lightweight service creation
- Thousands of services can run simultaneously
- Efficient message routing

### Fault Tolerance
- Service isolation prevents cascading failures
- Error handling at service level
- Graceful service shutdown

### Extensibility
- Dynamic module loading
- Hot-reload capability
- Easy to add new service types