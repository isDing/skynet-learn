# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

### Basic Build
```bash
make linux        # For Linux
make macosx       # For macOS
make freebsd       # For FreeBSD
```

### Alternative Build Method
```bash
export PLAT=linux
make
```

### Clean Commands
```bash
make clean        # Clean built files
make cleanall     # Clean everything including submodules
```

### Testing
```bash
./skynet examples/config    # Launch skynet node with gate server
./3rd/lua/lua examples/client.lua  # Launch test client
```

## Architecture Overview

Skynet is a lightweight, multi-threaded, actor-model-based framework written in C and Lua, designed primarily for game development but also used in other industries. The framework provides a distributed service architecture with message passing between services.

### Core Architecture Patterns

#### **Actor Model**
- Each service is an independent actor with its own state
- Services communicate exclusively through asynchronous message passing
- No shared memory between services, ensuring thread safety

#### **Multi-Layered Architecture**
- **C Layer (Bottom)**: Core runtime engine providing low-level services
- **Lua Layer (Top)**: Business logic and service implementation
- **Bridge Layer**: C/Lua interface for communication between layers

### Key Design Principles

#### **Message-Driven Architecture**
- All inter-service communication uses messages
- Support for multiple message types (Lua, socket, system, etc.)
- Asynchronous message processing with coroutines

#### **Service Isolation**
- Each service runs in its own Lua state
- Services are lightweight (thousands can run simultaneously)
- No direct memory sharing between services

#### **Coroutine-Based Concurrency**
- Each service uses coroutines for concurrent message handling
- Non-blocking I/O operations
- Cooperative multitasking within services

### Service Lifecycle

1. **Initialization**: `skynet_main.c` loads configuration
2. **Bootstrap**: `bootstrap.lua` starts core services
3. **Service Creation**: Via `launcher` service
4. **Message Processing**: Services register message handlers
5. **Shutdown**: Graceful service termination

### Key Features

#### **Distributed Support**
- Harbor system for multi-node clustering
- Service discovery across nodes
- Transparent remote service calls

#### **Hot-Reload Capability**
- Services can be updated without restarting
- Code caching for performance
- Dynamic module loading

#### **Debugging Support**
- Debug console service
- Message tracing
- Memory profiling tools

### Technology Stack

- **Language**: C (core), Lua 5.4.7 (services)
- **Memory Management**: jemalloc for efficient allocation
- **Networking**: Custom socket server with epoll/kqueue support
- **Build System**: Make-based with platform-specific configurations
- **Serialization**: Custom binary protocol (sproto)

### Directory Structure

- **skynet-src/**: Core runtime engine (message queues, timers, network I/O, service management)
- **service-src/**: C service modules (snlua, gate, logger)
- **lualib-src/**: Lua-C interface bridge layer
- **service/**: System-level Lua services (bootstrap, launcher, console, gate, etc.)
- **lualib/**: Lua libraries and utilities (skynet core, snax, sproto, etc.)
- **examples/**: Example applications and configurations
- **test/**: Test files for various components

### Key Components

#### Core C Components
- **skynet_main.c**: Entry point and main loop
- **skynet_server.c**: Service management and message dispatch
- **skynet_mq.c**: Message queue implementation
- **skynet_handle.c**: Service handle management
- **skynet_socket.c**: Network socket handling
- **socket_server.c**: Low-level socket server implementation
- **skynet_timer.c**: Timer and scheduling system

#### C Services
- **snlua**: Lua container service
- **gate**: Network gateway service
- **logger**: Logging service
- **harbor**: Multi-node coordination service

#### Lua Services
- **bootstrap**: Initial service launcher
- **launcher**: Service creation and management
- **console**: Debug console service
- **gate.lua**: Lua-level gate service
- **clusterd**: Cluster management service

#### Lua Libraries
- **skynet.lua**: Core skynet API for Lua
- **snax/**: Snax framework for actor model
- **sproto/**: Protocol buffer implementation
- **http/**: HTTP client and server utilities

### Configuration

Configuration files are Lua scripts that define:
- Service paths and modules
- Network addresses and ports
- Thread pool size
- Logging configuration
- Cluster settings

Key configuration files:
- `examples/config`: Main configuration example
- `examples/config.path`: Path configuration for services and modules

### Development Workflow

1. **Build**: Use `make <platform>` to compile the project
2. **Configure**: Edit configuration files in `examples/`
3. **Run**: Execute `./skynet examples/config` to start
4. **Test**: Use test files in `test/` directory for specific features

### Important Notes

- **3rd/ folder is excluded from management** - Contains third-party dependencies
- Uses modified Lua 5.4.7 for multiple Lua states
- Implements jemalloc for memory management (except on macOS)
- Supports both TCP and UDP networking
- Provides clustering capabilities for multi-node deployment
- Uses actor model with message passing between services