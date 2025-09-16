# Distributed Skynet Applications

## What You'll Learn
- Building distributed systems with Skynet clusters
- Harbor service for node discovery
- Inter-node communication
- Service discovery and registration
- Load balancing across nodes
- Fault tolerance and recovery

## Prerequisites
- Completed Tutorial 6: Network Programming with Skynet
- Understanding of distributed systems concepts
- Network configuration knowledge

## Time Estimate
70 minutes

## Final Result
Ability to build scalable, fault-tolerant distributed applications using Skynet's clustering capabilities

---

## 1. Skynet Cluster Architecture

### 1.1 Cluster Overview

Skynet cluster allows multiple Skynet nodes to work together as a unified system:

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│    Node 1       │    │    Node 2       │    │    Node 3       │
│                 │    │                 │    │                 │
│ ┌─────────────┐ │    │ ┌─────────────┐ │    │ ┌─────────────┐ │
│ │   Harbor    │◄┼────┼─│   Harbor    │◄┼────┼─│   Harbor    │ │
│ │   Service   │ │    │ │   Service   │ │    │ │   Service   │ │
│ └─────────────┘ │    │ └─────────────┘ │    │ └─────────────┘ │
│ ┌─────────────┐ │    │ ┌─────────────┐ │    │ ┌─────────────┐ │
│ │ Clusterd    │ │    │ │ Clusterd    │ │    │ │ Clusterd    │ │
│ │ Service     │ │    │ │ Service     │ │    │ │ Service     │ │
│ └─────────────┘ │    │ └─────────────┘ │    │ └─────────────┘ │
│ ┌─────────────┐ │    │ ┌─────────────┐ │    │ ┌─────────────┐ │
│ │ Application │ │    │ │ Application │ │    │ │ Application │ │
│ │ Services    │ │    │ │ Services    │ │    │ │ Services    │ │
│ └─────────────┘ │    │ └─────────────┘ │    │ └─────────────┘ │
└─────────────────┘    └─────────────────┘    └─────────────────┘
         │                       │                       │
         └───────────────────────┼───────────────────────┘
                                 │
                        ┌─────────────────┐
                        │   Master Node   │
                        │   (Optional)    │
                        └─────────────────┘
```

### 1.2 Key Components

- **Harbor Service**: Inter-node communication gateway
- **Clusterd Service**: Cluster management and service discovery
- **Master Node**: Centralized coordination (optional)

## 2. Setting Up a Cluster

### 2.1 Node Configuration

Create configuration files for each node:

**Node 1 Configuration (`config_node1.lua`)**:
```lua
-- config_node1.lua
thread = 8
logger = nil
logpath = "."
harbor = 1                    -- Harbor ID for this node
address = "127.0.0.1:2526"    -- This node's address
master = "127.0.0.1:2013"     -- Master node address
start = "main_node1"          -- Main service
bootstrap = "snlua bootstrap"
standalone = "0.0.0.0:2013"   -- This is also the master
cpath = root.."cservice/?.so"
```

**Node 2 Configuration (`config_node2.lua`)**:
```lua
-- config_node2.lua
thread = 8
logger = nil
logpath = "."
harbor = 2                    -- Different harbor ID
address = "127.0.0.1:2527"    -- Different port
master = "127.0.0.1:2013"     -- Same master
start = "main_node2"
bootstrap = "snlua bootstrap"
cpath = root.."cservice/?.so"
```

### 2.2 Starting the Cluster

```bash
# Terminal 1: Start node 1 (master)
./skynet config_node1

# Terminal 2: Start node 2
./skynet config_node2

# Terminal 3: Start node 3 (if needed)
./skynet config_node3
```

## 3. Cluster Communication

### 3.1 Basic Cluster Setup

**Main service for Node 1 (`main_node1.lua`)**:
```lua
-- main_node1.lua
local skynet = require "skynet"
local cluster = require "skynet.cluster"

skynet.start(function()
    -- Load cluster configuration
    cluster.reload({
        node2 = "127.0.0.1:2527",
        node3 = "127.0.0.1:2528"
    })
    
    -- Open cluster port
    cluster.open(2526)
    
    -- Start services
    local db_service = skynet.newservice("database_service")
    local cache_service = skynet.newservice("cache_service")
    
    -- Register services for cluster access
    cluster.register("database", db_service)
    cluster.register("cache", cache_service)
    
    skynet.error("Node 1 started with services registered")
end)
```

**Main service for Node 2 (`main_node2.lua`)**:
```lua
-- main_node2.lua
local skynet = require "skynet"
local cluster = require "skynet.cluster"

skynet.start(function()
    -- Load cluster configuration
    cluster.reload({
        node1 = "127.0.0.1:2526",
        node3 = "127.0.0.1:2528"
    })
    
    -- Open cluster port
    cluster.open(2527)
    
    -- Start application service
    local app_service = skynet.newservice("app_service")
    
    skynet.error("Node 2 started")
end)
```

### 3.2 Inter-Node Service Calls

**Application Service (`app_service.lua`)**:
```lua
-- app_service.lua
local skynet = require "skynet"
local cluster = require "skynet.cluster"

skynet.start(function()
    skynet.dispatch("lua", function(session, source, cmd, ...)
        if cmd == "get_user_data" then
            local user_id = ...
            
            -- Call database service on node1
            local ok, user_data = pcall(cluster.call, "node1", "database", 
                                       "get_user", user_id)
            if not ok then
                skynet.ret(skynet.pack(false, "Database error: " .. user_data))
                return
            end
            
            -- Get cached data from node1
            local cache_data = cluster.call("node1", "cache", "get", 
                                           "user_" .. user_id)
            
            -- Combine results
            local result = {
                user = user_data,
                cache = cache_data
            }
            
            skynet.ret(skynet.pack(true, result))
            
        elseif cmd == "set_user_data" then
            local user_id, data = ...
            
            -- Update database
            cluster.send("node1", "database", "update_user", user_id, data)
            
            -- Update cache
            cluster.send("node1", "cache", "set", "user_" .. user_id, data)
            
            skynet.ret(skynet.pack(true))
        end
    end)
    
    -- Register service
    cluster.register("app_service", skynet.self())
    
    skynet.exit()
end)
```

### 3.3 Service Discovery

```lua
-- Service discovery example
local skynet = require "skynet"
local cluster = require "skynet.cluster"

local service_cache = {}
local cache_timeout = 60  -- seconds

local function get_service_address(node, service_name)
    local cache_key = node .. ":" .. service_name
    
    -- Check cache first
    if service_cache[cache_key] then
        local cached = service_cache[cache_key]
        if skynet.time() - cached.timestamp < cache_timeout then
            return cached.address
        end
    end
    
    -- Query cluster
    local address = cluster.query(node, service_name)
    if address then
        -- Cache the result
        service_cache[cache_key] = {
            address = address,
            timestamp = skynet.time()
        }
        return address
    end
    
    return nil
end

-- Usage
local function call_remote_service(node, service_name, cmd, ...)
    local address = get_service_address(node, service_name)
    if not address then
        return false, "Service not found"
    end
    
    return cluster.call(node, address, cmd, ...)
end
```

## 4. Load Balancing

### 4.1 Round-Robin Load Balancer

```lua
-- load_balancer.lua
local skynet = require "skynet"
local cluster = require "skynet.cluster"

local nodes = {"node1", "node2", "node3"}
local current_index = 1

local function get_next_node()
    local node = nodes[current_index]
    current_index = current_index + 1
    if current_index > #nodes then
        current_index = 1
    end
    return node
end

local function distribute_request(service_name, cmd, ...)
    local selected_node = get_next_node()
    
    -- Check if service is available on selected node
    local address = cluster.query(selected_node, service_name)
    if not address then
        -- Try next node
        for i = 1, #nodes do
            selected_node = get_next_node()
            address = cluster.query(selected_node, service_name)
            if address then
                break
            end
        end
    end
    
    if address then
        return cluster.call(selected_node, address, cmd, ...)
    else
        return false, "No available service"
    end
end

skynet.start(function()
    skynet.dispatch("lua", function(session, source, cmd, ...)
        if cmd == "process" then
            local service_name, operation, args = ...
            local result = distribute_request(service_name, operation, args)
            skynet.ret(skynet.pack(result))
        end
    end)
    
    cluster.register("load_balancer", skynet.self())
end)
```

### 4.2 Weighted Load Balancing

```lua
-- weighted_load_balancer.lua
local nodes = {
    {name = "node1", weight = 3, current_load = 0},
    {name = "node2", weight = 2, current_load = 0},
    {name = "node3", weight = 1, current_load = 0}
}

local function get_best_node()
    -- Calculate weighted scores
    local best_node = nil
    local best_score = -1
    
    for _, node in ipairs(nodes) do
        -- Lower load is better
        local load_factor = 1 / (node.current_load + 1)
        local score = node.weight * load_factor
        
        if score > best_score then
            best_score = score
            best_node = node
        end
    end
    
    return best_node.name
end

local function update_node_load(node_name, delta)
    for _, node in ipairs(nodes) do
        if node.name == node_name then
            node.current_load = node.current_load + delta
            -- Ensure load doesn't go negative
            if node.current_load < 0 then
                node.current_load = 0
            end
            break
        end
    end
end
```

## 5. Fault Tolerance

### 5.1 Service Health Monitoring

```lua
-- health_monitor.lua
local skynet = require "skynet"
local cluster = require "skynet.cluster"

local health_status = {}
local check_interval = 5  -- seconds

local function check_node_health(node)
    local services = {"database", "cache", "app_service"}
    local node_healthy = true
    
    for _, service in ipairs(services) do
        local ok, result = pcall(cluster.call, node, ".service", 
                                  "QUERY", service)
        if not ok or not result then
            node_healthy = false
            break
        end
    end
    
    health_status[node] = {
        healthy = node_healthy,
        last_check = skynet.time()
    }
    
    return node_healthy
end

local function health_check_loop()
    local cluster_config = cluster.reload()
    
    for node, _ in pairs(cluster_config) do
        if node ~= "master" then
            check_node_health(node)
        end
    end
    
    skynet.timeout(check_interval * 100, health_check_loop)
end

local function get_healthy_nodes()
    local healthy_nodes = {}
    for node, status in pairs(health_status) do
        if status.healthy then
            table.insert(healthy_nodes, node)
        end
    end
    return healthy_nodes
end

skynet.start(function()
    -- Start health monitoring
    health_check_loop()
    
    skynet.dispatch("lua", function(session, source, cmd, ...)
        if cmd == "get_healthy_nodes" then
            skynet.ret(skynet.pack(get_healthy_nodes()))
        elseif cmd == "is_node_healthy" then
            local node = ...
            local status = health_status[node]
            skynet.ret(skynet.pack(status and status.healthy or false))
        end
    end)
    
    cluster.register("health_monitor", skynet.self())
end)
```

### 5.2 Failover Mechanism

```lua
-- failover_manager.lua
local skynet = require "skynet"
local cluster = require "skynet.cluster"

local primary_node = "node1"
local backup_nodes = {"node2", "node3"}
local current_primary = primary_node
local failover_in_progress = false

local function promote_backup()
    if failover_in_progress then return end
    failover_in_progress = true
    
    skynet.error("Initiating failover from", current_primary)
    
    -- Find healthy backup
    for _, node in ipairs(backup_nodes) do
        local healthy = cluster.call("health_monitor", "lua", 
                                    "is_node_healthy", node)
        if healthy then
            -- Promote this node
            current_primary = node
            skynet.error("Promoted", node, "as new primary")
            
            -- Notify all nodes
            local all_nodes = cluster.reload()
            for n, _ in pairs(all_nodes) do
                if n ~= "master" then
                    cluster.send(n, "failover_handler", "new_primary", node)
                end
            end
            
            break
        end
    end
    
    failover_in_progress = false
end

local function check_primary_health()
    local healthy = cluster.call("health_monitor", "lua", 
                                "is_node_healthy", current_primary)
    
    if not healthy then
        promote_backup()
    end
    
    skynet.timeout(1000, check_primary_health)
end

skynet.start(function()
    -- Start health monitoring
    check_primary_health()
    
    skynet.dispatch("lua", function(session, source, cmd, ...)
        if cmd == "get_primary" then
            skynet.ret(skynet.pack(current_primary))
        elseif cmd == "force_failover" then
            promote_backup()
            skynet.ret(skynet.pack(true))
        end
    end)
end)
```

## 6. Data Replication

### 6.1 Master-Slave Replication

```lua
-- replication_manager.lua
local skynet = require "skynet"
local cluster = require "skynet.cluster"

local master_node = "node1"
local slave_nodes = {"node2", "node3"}

local function replicate_to_slaves(operation, key, value)
    local replication_ops = {}
    
    for _, slave in ipairs(slave_nodes) do
        table.insert(replication_ops, function()
            return cluster.call(slave, "replication_slave", 
                               "replicate", operation, key, value)
        end)
    end
    
    -- Execute in parallel
    local results = {}
    for i, op in ipairs(replication_ops) do
        skynet.fork(function()
            results[i] = op()
        end)
    end
    
    -- Wait for all (with timeout)
    local deadline = skynet.time() + 5
    while skynet.time() < deadline do
        local all_complete = true
        for i = 1, #replication_ops do
            if results[i] == nil then
                all_complete = false
                break
            end
        end
        if all_complete then break end
        skynet.sleep(1)
    end
end

-- Master service
skynet.start(function()
    skynet.dispatch("lua", function(session, source, cmd, ...)
        if cmd == "set" then
            local key, value = ...
            
            -- Set locally first
            local_database.set(key, value)
            
            -- Replicate to slaves
            replicate_to_slaves("SET", key, value)
            
            skynet.ret(skynet.pack(true))
        elseif cmd == "get" then
            local key = ...
            local value = local_database.get(key)
            skynet.ret(skynet.pack(value))
        end
    end)
end)
```

### 6.2 Multi-Master Replication

```lua
-- multi_master_replication.lua
local node_id = skynet.getenv("node_id")
local other_nodes = {"node1", "node2", "node3"}
local operation_log = {}
local log_index = 0

local function broadcast_operation(op_type, key, value)
    log_index = log_index + 1
    local op_id = node_id .. "_" .. log_index
    
    operation_log[op_id] = {
        type = op_type,
        key = key,
        value = value,
        timestamp = skynet.time()
    }
    
    -- Broadcast to other nodes
    for _, node in ipairs(other_nodes) do
        if node ~= node_id then
            cluster.send(node, "replication", "receive_op", op_id, 
                         op_type, key, value)
        end
    end
end

local function apply_operation(op_id, op_type, key, value)
    -- Check if already applied
    if operation_log[op_id] then return end
    
    -- Apply operation
    if op_type == "SET" then
        local_database.set(key, value)
    elseif op_type == "DELETE" then
        local_database.delete(key)
    end
    
    -- Record in log
    operation_log[op_id] = {
        type = op_type,
        key = key,
        value = value,
        timestamp = skynet.time()
    }
end

-- Conflict resolution
local function resolve_conflict(op1, op2)
    -- Last writer wins
    if op1.timestamp > op2.timestamp then
        return op1
    else
        return op2
    end
end
```

## 7. Example: Distributed Chat System

### 7.1 Cluster Configuration

**Chat Node 1 (`chat_node1.lua`)**:
```lua
local skynet = require "skynet"
local cluster = require "skynet.cluster"

skynet.start(function()
    cluster.reload({
        chat_node2 = "127.0.0.1:2537",
        chat_node3 = "127.0.0.1:2538"
    })
    
    cluster.open(2536)
    
    -- Start chat services
    local room_service = skynet.newservice("chat_room_service")
    local user_service = skynet.newservice("user_service")
    
    cluster.register("chat_rooms", room_service)
    cluster.register("users", user_service)
    
    -- Start replication
    skynet.newservice("chat_replication")
end)
```

### 7.2 Distributed Room Service

```lua
-- chat_room_service.lua
local skynet = require "skynet"
local cluster = require "skynet.cluster"

local rooms = {}
local node_rooms = {}  -- Rooms hosted on this node

local function get_room_node(room_id)
    -- Consistent hashing for room distribution
    local hash = 0
    for i = 1, #room_id do
        hash = (hash * 31 + string.byte(room_id, i)) % 1000
    end
    local nodes = {"chat_node1", "chat_node2", "chat_node3"}
    return nodes[(hash % #nodes) + 1]
end

skynet.start(function()
    skynet.dispatch("lua", function(session, source, cmd, ...)
        if cmd == "join_room" then
            local user_id, room_id, user_name = ...
            local room_node = get_room_node(room_id)
            
            if room_node == cluster.self() then
                -- Local room
                if not rooms[room_id] then
                    rooms[room_id] = {
                        users = {},
                        messages = {},
                        node = cluster.self()
                    }
                    node_rooms[room_id] = true
                end
                
                rooms[room_id].users[user_id] = user_name
                
                -- Broadcast join to cluster
                for node, _ in pairs(cluster.reload()) do
                    if node ~= "master" and node ~= cluster.self() then
                        cluster.send(node, "chat_rooms", "remote_join", 
                                   user_id, room_id, user_name)
                    end
                end
                
                skynet.ret(skynet.pack(true))
            else
                -- Remote room
                local result = cluster.call(room_node, "chat_rooms", 
                                         "join_room", user_id, room_id, user_name)
                skynet.ret(skynet.pack(result))
            end
            
        elseif cmd == "send_message" then
            local user_id, room_id, message = ...
            local room_node = get_room_node(room_id)
            
            if room_node == cluster.self() then
                -- Local room
                local room = rooms[room_id]
                if room then
                    local msg = {
                        id = #room.messages + 1,
                        user = room.users[user_id],
                        text = message,
                        time = os.date("%H:%M:%S"),
                        node = cluster.self()
                    }
                    
                    table.insert(room.messages, msg)
                    
                    -- Broadcast to all nodes
                    for node, _ in pairs(cluster.reload()) do
                        if node ~= "master" then
                            cluster.send(node, "chat_rooms", "broadcast_message", 
                                       room_id, msg)
                        end
                    end
                end
            else
                -- Forward to room node
                cluster.send(room_node, "chat_rooms", "send_message", 
                           user_id, room_id, message)
            end
            
            skynet.ret(skynet.pack(true))
        end
    end)
    
    cluster.register("chat_rooms", skynet.self())
end)
```

## 8. Exercise: Distributed Game Server

Create a distributed game server with:
1. Multiple game instances running on different nodes
2. Player session migration between nodes
3. Distributed state synchronization
4. Load-aware instance allocation
5. Graceful node shutdown handling

**Features to implement**:
- Game instance replication
- Player position prediction
- Eventual consistency model
- Distributed lock management
- Cross-node event broadcasting

## Summary

In this tutorial, you learned:
- Setting up and configuring Skynet clusters
- Inter-node communication patterns
- Service discovery and registration
- Load balancing across nodes
- Fault tolerance and failover mechanisms
- Data replication strategies
- Building distributed applications

## Next Steps

Continue to [Tutorial 8: Advanced Topics](./tutorial8_advanced.md) to explore hot-reloading, debugging, performance optimization, and other advanced Skynet features.