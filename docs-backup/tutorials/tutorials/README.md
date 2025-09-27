# Skynet Tutorial Series

Welcome to the comprehensive Skynet tutorial series! This series will take you from beginner to advanced level in building applications with Skynet.

## Tutorial Series Overview

### 1. [Getting Started with Skynet](./01_getting_started.md)
**Beginner Level** - 30 minutes

Learn the fundamentals of Skynet:
- What is Skynet and its core concepts
- Setting up the development environment
- Running your first Skynet application
- Understanding project structure

### 2. [Understanding Skynet Architecture](./02_architecture.md)
**Beginner Level** - 45 minutes

Dive deep into Skynet's architecture:
- The actor model implementation
- Service lifecycle and management
- Message passing mechanisms
- Thread scheduling and concurrency

### 3. [Creating Your First Service](./03_first_service.md)
**Intermediate Level** - 60 minutes

Build your first practical service:
- Service structure patterns
- State management
- Error handling
- Building a complete chat service

### 4. [Message Passing and Communication](./04_message_passing.md)
**Intermediate Level** - 50 minutes

Master inter-service communication:
- Advanced message patterns
- Request-response protocols
- Event-driven communication
- Performance optimization

### 5. [Working with Lua Services](./05_lua_services.md)
**Intermediate Level** - 55 minutes

Learn advanced Lua service development:
- Service composition patterns
- Hot-reloading services
- Memory management
- Performance optimization

### 6. [Network Programming with Skynet](./06_network_programming.md)
**Advanced Level** - 60 minutes

Build networked applications:
- Socket API and network programming
- TCP servers with gate service
- WebSocket and HTTP support
- Network security

### 7. [Distributed Skynet Applications](./07_distributed.md)
**Advanced Level** - 70 minutes

Create distributed systems:
- Cluster configuration and setup
- Inter-node communication
- Load balancing
- Fault tolerance and failover

### 8. [Advanced Topics](./08_advanced.md)
**Expert Level** - 80 minutes

Master production-ready development:
- Hot-reloading without downtime
- Advanced debugging techniques
- Performance optimization
- Security and monitoring

## Learning Path

### For Beginners
1. Start with Tutorial 1 to get Skynet running
2. Move to Tutorial 2 to understand how it works
3. Build your first service in Tutorial 3

### For Intermediate Developers
1. Master message passing in Tutorial 4
2. Learn advanced Lua patterns in Tutorial 5
3. Build network services in Tutorial 6

### For Advanced Developers
1. Create distributed systems in Tutorial 7
2. Master production techniques in Tutorial 8

## Prerequisites

### Before Starting
- Linux, macOS, or FreeBSD system
- Basic Lua programming knowledge
- Command-line proficiency
- Git installed

### For Advanced Topics
- Understanding of distributed systems
- Network programming concepts
- Concurrent programming experience

## Code Examples

Each tutorial includes:
- Complete, runnable code examples
- Step-by-step explanations
- Common pitfalls and solutions
- Exercises for practice

## Getting Help

### Resources
- [Skynet GitHub Repository](https://github.com/cloudwu/skynet)
- [Skynet Wiki](https://github.com/cloudwu/skynet/wiki)
- [Community Discussions](https://github.com/cloudwu/skynet/discussions)

### Common Issues
1. **Build Errors**: Ensure you have build tools installed
2. **Port Conflicts**: Check if ports are already in use
3. **Lua Version**: Skynet uses Lua 5.4.7 by default

## Contributing

Found an error or want to improve these tutorials?
1. Check the [Issues](https://github.com/your-repo/issues)
2. Submit a Pull Request
3. Help others in the community

## Quick Start

1. Clone Skynet:
```bash
git clone https://github.com/cloudwu/skynet.git
cd skynet
make linux
```

2. Run the example:
```bash
./skynet examples/config
```

3. Start learning with Tutorial 1!

Happy coding with Skynet! 🚀