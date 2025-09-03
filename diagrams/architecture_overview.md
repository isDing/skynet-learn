# Skynet Architecture Overview Diagram

```mermaid
graph TB
    %% C Layer (Core Infrastructure)
    subgraph "C Layer (Core Infrastructure)"
        C1[skynet_main.c<br/>Entry Point & Main Loop]
        C2[skynet_server.c<br/>Service Management]
        C3[skynet_mq.c<br/>Message Queue]
        C4[skynet_handle.c<br/>Service Handle Mgmt]
        C5[skynet_socket.c<br/>Network I/O]
        C6[skynet_timer.c<br/>Timer System]
        C7[socket_server.c<br/>Socket Server]
        C8[skynet_module.c<br/>Module Loading]
        
        C1 --> C2
        C2 --> C3
        C2 --> C4
        C2 --> C5
        C2 --> C6
        C5 --> C7
        C2 --> C8
    end
    
    %% C Services
    subgraph "C Services"
        CS1[snlua<br/>Lua Container]
        CS2[gate<br/>Network Gateway]
        CS3[logger<br/>Logging Service]
        CS4[harbor<br/>Multi-node Coord]
        
        CS1 -.->|uses| C2
        CS2 -.->|uses| C5
        CS3 -.->|uses| C2
        CS4 -.->|uses| C2
    end
    
    %% Bridge Layer (Lua-C Interface)
    subgraph "Bridge Layer (Lua-C Interface)"
        B1[lualib-src/*<br/>Lua-C APIs]
        B2[skynet.core<br/>Core Lua API]
        B3[socket.lua<br/>Socket API]
        B4[timer.lua<br/>Timer API]
        
        B1 -.->|binds| C2
        B1 -.->|binds| C5
        B1 -.->|binds| C6
        B2 --> B1
        B3 --> B1
        B4 --> B1
    end
    
    %% Lua Layer (Business Logic)
    subgraph "Lua Layer (Business Logic)"
        L1[bootstrap.lua<br/>Service Launcher]
        L2[launcher<br/>Service Manager]
        L3[console<br/>Debug Console]
        L4[gate.lua<br/>Lua Gate Service]
        L5[clusterd<br/>Cluster Mgmt]
        L6[datacenterd<br/>Data Center]
        L7[User Services<br/>Custom Logic]
        
        L1 --> L2
        L2 --> L3
        L2 --> L4
        L2 --> L5
        L2 --> L6
        L2 --> L7
    end
    
    %% Lua Libraries
    subgraph "Lua Libraries"
        LL1[skynet.lua<br/>Core Skynet API]
        LL2[snax<br/>Actor Framework]
        LL3[sproto<br/>Protocol Buffers]
        LL4[http<br/>HTTP Utils]
        LL5[sharedata<br/>Shared Data]
        
        LL1 --> B2
        LL2 --> LL1
        LL3 --> LL1
        LL4 --> LL1
        LL5 --> LL1
    end
    
    %% Connections between layers
    C1 -.->|starts| CS1
    CS1 -->|hosts| L1
    B1 -->|enables| L1
    B1 -->|enables| L2
    B1 -->|enables| L3
    LL1 -->|used by| L1
    LL1 -->|used by| L2
    LL1 -->|used by| L3
    
    %% Styling
    classDef cLayer fill:#e1f5fe,stroke:#01579b,stroke-width:2px
    classDef cService fill:#f3e5f5,stroke:#4a148c,stroke-width:2px
    classDef bridgeLayer fill:#e8f5e8,stroke:#1b5e20,stroke-width:2px
    classDef luaLayer fill:#fff3e0,stroke:#e65100,stroke-width:2px
    classDef luaLib fill:#fce4ec,stroke:#880e4f,stroke-width:2px
    
    class C1,C2,C3,C4,C5,C6,C7,C8 cLayer
    class CS1,CS2,CS3,CS4 cService
    class B1,B2,B3,B4 bridgeLayer
    class L1,L2,L3,L4,L5,L6,L7 luaLayer
    class LL1,LL2,LL3,LL4,LL5 luaLib
```

## Key Components

### C Layer (Core Infrastructure)
- **skynet_main.c**: Entry point and main event loop
- **skynet_server.c**: Service management and message dispatch
- **skynet_mq.c**: Message queue implementation
- **skynet_handle.c**: Service handle management
- **skynet_socket.c**: Network socket handling
- **skynet_timer.c**: Timer and scheduling system

### C Services
- **snlua**: Lua container service that hosts Lua services
- **gate**: Network gateway for client connections
- **logger**: Centralized logging service
- **harbor**: Multi-node coordination for clustering

### Bridge Layer
- **lualib-src**: C-Lua interface implementations
- **skynet.core**: Core Lua API binding to C functions
- **socket.lua**: Lua socket API
- **timer.lua**: Lua timer API

### Lua Layer
- **bootstrap**: Initial service launcher
- **launcher**: Service creation and management
- **console**: Debug console service
- **gate.lua**: Lua-level gate service
- **clusterd**: Cluster management service
- **datacenterd**: Data center service

### Lua Libraries
- **skynet.lua**: Core skynet API for Lua services
- **snax**: Actor model framework
- **sproto**: Protocol buffer implementation
- **http**: HTTP client and server utilities
- **sharedata**: Shared data management