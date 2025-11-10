# Skynet Lua API 索引

> 点击接口名跳转到详细文档

---

## 核心模块 (skynet.lua)

### 常量
- [skynet.PTYPE_TEXT](./LUALIB_API_REFERENCE.md#消息类型常量)
- [skynet.PTYPE_RESPONSE](./LUALIB_API_REFERENCE.md#消息类型常量)
- [skynet.PTYPE_MULTICAST](./LUALIB_API_REFERENCE.md#消息类型常量)
- [skynet.PTYPE_CLIENT](./LUALIB_API_REFERENCE.md#消息类型常量)
- [skynet.PTYPE_SYSTEM](./LUALIB_API_REFERENCE.md#消息类型常量)
- [skynet.PTYPE_HARBOR](./LUALIB_API_REFERENCE.md#消息类型常量)
- [skynet.PTYPE_SOCKET](./LUALIB_API_REFERENCE.md#消息类型常量)
- [skynet.PTYPE_ERROR](./LUALIB_API_REFERENCE.md#消息类型常量)
- [skynet.PTYPE_QUEUE](./LUALIB_API_REFERENCE.md#消息类型常量)
- [skynet.PTYPE_DEBUG](./LUALIB_API_REFERENCE.md#消息类型常量)
- [skynet.PTYPE_LUA](./LUALIB_API_REFERENCE.md#消息类型常量)
- [skynet.PTYPE_SNAX](./LUALIB_API_REFERENCE.md#消息类型常量)
- [skynet.PTYPE_TRACE](./LUALIB_API_REFERENCE.md#消息类型常量)

### 协议管理
- [skynet.register_protocol](./LUALIB_API_REFERENCE.md#skynetregister_protocolclass)
- [skynet.dispatch](./LUALIB_API_REFERENCE.md#skynetdispatchtypename-func)

### 服务管理
- [skynet.self](./LUALIB_API_REFERENCE.md#skynetself)
- [skynet.localname](./LUALIB_API_REFERENCE.md#skynetlocalname-name)
- [skynet.newservice](./LUALIB_API_REFERENCE.md#skynetnewservice-name-)
- [skynet.uniqueservice](./LUALIB_API_REFERENCE.md#skynetuniqueservice-name-)
- [skynet.queryservice](./LUALIB_API_REFERENCE.md#skynetqueryservice-name)
- [skynet.exit](./LUALIB_API_REFERENCE.md#skynetexit)

### 消息传递
- [skynet.send](./LUALIB_API_REFERENCE.md#skynetsendaddr-typename-)
- [skynet.rawsend](./LUALIB_API_REFERENCE.md#skynetrawsendaddr-typename-msg-sz)
- [skynet.call](./LUALIB_API_REFERENCE.md#skynetcalladdr-typename-)
- [skynet.rawcall](./LUALIB_API_REFERENCE.md#skynetrawcalladdr-typename-msg-sz)
- [skynet.ret](./LUALIB_API_REFERENCE.md#skynetretmsg-sz)
- [skynet.response](./LUALIB_API_REFERENCE.md#skynetresponsepack)

### 协程与调度
- [skynet.fork](./LUALIB_API_REFERENCE.md#skynetforkfunc-)
- [skynet.yield](./LUALIB_API_REFERENCE.md#skynetyield)
- [skynet.sleep](./LUALIB_API_REFERENCE.md#skynetsleepti-token)
- [skynet.wait](./LUALIB_API_REFERENCE.md#skynetwaittoken)
- [skynet.wakeup](./LUALIB_API_REFERENCE.md#skynetwakeuptoken)
- [skynet.killthread](./LUALIB_API_REFERENCE.md#skynetkillthreadthread)

### 定时器
- [skynet.timeout](./LUALIB_API_REFERENCE.md#skynettimeoutti-func)
- [skynet.now](./LUALIB_API_REFERENCE.md#skynetnow)
- [skynet.starttime](./LUALIB_API_REFERENCE.md#skynetstarttime)
- [skynet.time](./LUALIB_API_REFERENCE.md#skynettime)

### 内存与性能
- [skynet.pack](./LUALIB_API_REFERENCE.md#skynetpack)
- [skynet.unpack](./LUALIB_API_REFERENCE.md#skynetunpackmsg-sz)
- [skynet.tostring](./LUALIB_API_REFERENCE.md#skynettostringmsg-sz)
- [skynet.trash](./LUALIB_API_REFERENCE.md#skynettrashmsg-sz)
- [skynet.memlimit](./LUALIB_API_REFERENCE.md#skynetmemlimitbytes)

### 调试与跟踪
- [skynet.trace](./LUALIB_API_REFERENCE.md#skynetraceinfo)
- [skynet.tracetag](./LUALIB_API_REFERENCE.md#skynettracetag)
- [skynet.traceproto](./LUALIB_API_REFERENCE.md#skynettraceprotoprototype-flag)
- [skynet.trace_timeout](./LUALIB_API_REFERENCE.md#skynetrace_timeouton)
- [skynet.error](./LUALIB_API_REFERENCE.md#skyneterror)
- [skynet.task](./LUALIB_API_REFERENCE.md#skynettaskret)
- [skynet.uniqtask](./LUALIB_API_REFERENCE.md#skynetuniqtask)

### 批量请求
- [skynet.request](./LUALIB_API_REFERENCE.md#skynetrequestobj)

### 环境变量
- [skynet.getenv](./LUALIB_API_REFERENCE.md#skynetgetenvkey)
- [skynet.setenv](./LUALIB_API_REFERENCE.md#skynetsetenvkey-value)

### 服务状态
- [skynet.endless](./LUALIB_API_REFERENCE.md#skynetendless)
- [skynet.mqlen](./LUALIB_API_REFERENCE.md#skynetmqlen)
- [skynet.stat](./LUALIB_API_REFERENCE.md#skynetstatwhat)

### 初始化
- [skynet.start](./LUALIB_API_REFERENCE.md#skynetstartstart_func)
- [skynet.init_service](./LUALIB_API_REFERENCE.md#skynetinit_servicestart)
- [skynet.init](./LUALIB_API_REFERENCE.md#skynetinitfunc)

### 消息重定向
- [skynet.redirect](./LUALIB_API_REFERENCE.md#skynetredirectdest-source-typename-)

### 错误处理
- [skynet.term](./LUALIB_API_REFERENCE.md#skynetermservice)
- [skynet.dispatch_unknown_request](./LUALIB_API_REFERENCE.md#skynetdispatch_unknown_requestunknown)
- [skynet.dispatch_unknown_response](./LUALIB_API_REFERENCE.md#skynetdispatch_unknown_responseunknown)

### 会话管理
- [skynet.genid](./LUALIB_API_REFERENCE.md#skynetgenid)
- [skynet.context](./LUALIB_API_REFERENCE.md#skynetcontext)
- [skynet.ignoreret](./LUALIB_API_REFERENCE.md#skynetignoreret)

### 消息ID生成与追踪
- [skynet.address](./LUALIB_API_REFERENCE.md#skynetaddressaddr)
- [skynet.harbor](./LUALIB_API_REFERENCE.md#skynetharboraddr)

---

## Snax 框架 (snax/)

### 核心接口
- [snax.interface](./LUALIB_API_REFERENCE.md#snaxinterfacename)
- [snax.newservice](./LUALIB_API_REFERENCE.md#snaxnewservice-name-)
- [snax.rawnewservice](./LUALIB_API_REFERENCE.md#snaxrawnewservice-name-)
- [snax.bind](./LUALIB_API_REFERENCE.md#snaxbindhandle-type)
- [snax.uniqueservice](./LUALIB_API_REFERENCE.md#snaxuniqueservice-name-)
- [snax.globalservice](./LUALIB_API_REFERENCE.md#snaxglobalservice-name-)
- [snax.queryservice](./LUALIB_API_REFERENCE.md#snaxqueryservicename)
- [snax.queryglobal](./LUALIB_API_REFERENCE.md#snaxqueryglobalname)
- [snax.kill](./LUALIB_API_REFERENCE.md#snaxkillobj-)
- [snax.exit](./LUALIB_API_REFERENCE.md#snaxexit-)
- [snax.self](./LUALIB_API_REFERENCE.md#snaxself)
- [snax.hotfix](./LUALIB_API_REFERENCE.md#snaxhotfixobj-source-)
- [snax.profile_info](./LUALIB_API_REFERENCE.md#snaxprofile_infoobj)
- [snax.printf](./LUALIB_API_REFERENCE.md#snaxprintffmt-)

### 服务对象方法
- [snax.post](./LUALIB_API_REFERENCE.md#service-object-方法)
- [snax.req](./LUALIB_API_REFERENCE.md#service-object-方法)

---

## 协议处理 (sproto)

### sproto.lua
- [sproto.new](./LUALIB_API_REFERENCE.md#sprotonewbin)
- [sproto.parse](./LUALIB_API_REFERENCE.md#sprotoparseptext)
- [sproto.sharenew](./LUALIB_API_REFERENCE.md#sprotosharenewcobj)

### sproto 对象方法
- [sproto:host](./LUALIB_API_REFERENCE.md#hostpackagename)
- [sproto:encode](./LUALIB_API_REFERENCE.md#encodetypename-tbl)
- [sproto:decode](./LUALIB_API_REFERENCE.md#decodetypename-)
- [sproto:pencode](./LUALIB_API_REFERENCE.md#pencodetypename-tbl)
- [sproto:pdecode](./LUALIB_API_REFERENCE.md#pdecodetypename-)
- [sproto:queryproto](./LUALIB_API_REFERENCE.md#querypropname)
- [sproto:exist_proto](./LUALIB_API_REFERENCE.md#exist_protopname)
- [sproto:request_encode](./LUALIB_API_REFERENCE.md#request_encodeprotoname-tbl)
- [sproto:response_encode](./LUALIB_API_REFERENCE.md#response_encodeprotoname-tbl)
- [sproto:request_decode](./LUALIB_API_REFERENCE.md#request_decodeprotoname-)
- [sproto:response_decode](./LUALIB_API_REFERENCE.md#response_decodeprotoname-)
- [sproto:exist_type](./LUALIB_API_REFERENCE.md#exist_typetypename)
- [sproto:default](./LUALIB_API_REFERENCE.md#defaulttypename-type)

### host 对象方法
- [host:dispatch](./LUALIB_API_REFERENCE.md#dispatch)
- [host:attach](./LUALIB_API_REFERENCE.md#attachsp)

### sprotoparser.lua
- [sparser.parse](./LUALIB_API_REFERENCE.md#sparserparsetext-name)
- [sparser.dump](./LUALIB_API_REFERENCE.md#sparserdumpstr)

### sprotoloader.lua
- [loader.register](./LUALIB_API_REFERENCE.md#loaderregisterfilename-index)
- [loader.save](./LUALIB_API_REFERENCE.md#loadersavebin-index)
- [loader.load](./LUALIB_API_REFERENCE.md#loaderloadindex)

---

## 网络通信 (http/)

### httpd.lua (服务器)
- [httpd.read_request](./LUALIB_API_REFERENCE.md#httpdread_requestreadbytes-bodylimit)
- [httpd.write_response](./LUALIB_API_REFERENCE.md#httpdwrite_responsewritestatuscode-bodyfunc-header)

### httpc.lua (客户端)
- [httpc.dns](./LUALIB_API_REFERENCE.md#httpcdnsserver-port)
- [httpc.request](./LUALIB_API_REFERENCE.md#httpcrequestmethod-hostname-url-recvheader-header-content)
- [httpc.get](./LUALIB_API_REFERENCE.md#httpcget-)
- [httpc.head](./LUALIB_API_REFERENCE.md#httpcheadhostname-url-recvheader-header-content)
- [httpc.post](./LUALIB_API_REFERENCE.md#httpcposthost-url-form-recvheader)
- [httpc.request_stream](./LUALIB_API_REFERENCE.md#httpcrequest_streammethod-hostname-url-recvheader-header-content)

### websocket.lua
- [websocket.accept](./LUALIB_API_REFERENCE.md#websocketacceptsocket_id-handle-protocol-addr-options)
- [websocket.connect](./LUALIB_API_REFERENCE.md#websocketconnecturl-header-timeout)
- [websocket.read](./LUALIB_API_REFERENCE.md#websocketreadid)
- [websocket.write](./LUALIB_API_REFERENCE.md#websocketwriteid-data-fmt-masking_key)
- [websocket.ping](./LUALIB_API_REFERENCE.md#websocketpingid)
- [websocket.close](./LUALIB_API_REFERENCE.md#websocketcloseid-code-reason)
- [websocket.addrinfo](./LUALIB_API_REFERENCE.md#websocketaddrinfoid)
- [websocket.real_ip](./LUALIB_API_REFERENCE.md#websocketreal_ipid)
- [websocket.is_close](./LUALIB_API_REFERENCE.md#websocketis_closeid)

---

## Socket API (skynet/socket.lua)

### TCP 连接
- [socket.open](./LUALIB_API_REFERENCE.md#socketopenaddr-port)
- [socket.bind](./LUALIB_API_REFERENCE.md#socketbindos_fd)
- [socket.stdin](./LUALIB_API_REFERENCE.md#socketstdin)
- [socket.start](./LUALIB_API_REFERENCE.md#socketstartid-func)
- [socket.listen](./LUALIB_API_REFERENCE.md#socketlisthost-port-backlog)

### 读取数据
- [socket.read](./LUALIB_API_REFERENCE.md#socketreadid-sz)
- [socket.readall](./LUALIB_API_REFERENCE.md#socketreadallid)
- [socket.readline](./LUALIB_API_REFERENCE.md#socketreadlineid-sep)
- [socket.block](./LUALIB_API_REFERENCE.md#socketblockid)

### 写入数据
- [socket.write](./LUALIB_API_REFERENCE.md#socketwriteid-data)
- [socket.lwrite](./LUALIB_API_REFERENCE.md#socketlwriteid-data)

### 关闭连接
- [socket.close](./LUALIB_API_REFERENCE.md#socketcloseid)
- [socket.shutdown](./LUALIB_API_REFERENCE.md#socketshutdownid)
- [socket.close_fd](./LUALIB_API_REFERENCE.md#socketclose_fdid)
- [socket.abandon](./LUALIB_API_REFERENCE.md#socketabandonid)

### 控制与状态
- [socket.pause](./LUALIB_API_REFERENCE.md#socketpauseid)
- [socket.warning](./LUALIB_API_REFERENCE.md#socketwarningid-callback)
- [socket.onclose](./LUALIB_API_REFERENCE.md#socketoncloseid-callback)
- [socket.invalid](./LUALIB_API_REFERENCE.md#socketinvalidid)
- [socket.disconnected](./LUALIB_API_REFERENCE.md#socketdisconnectedid)
- [socket.limit](./LUALIB_API_REFERENCE.md#socketlimitid-limit)

### UDP
- [socket.udp](./LUALIB_API_REFERENCE.md#socketudpcallback-host-port)
- [socket.udp_connect](./LUALIB_API_REFERENCE.md#socketudp_connectid-addr-port-callback)
- [socket.udp_listen](./LUALIB_API_REFERENCE.md#socketudp_listenaddr-port-callback)
- [socket.udp_dial](./LUALIB_API_REFERENCE.md#socketudp_dialaddr-port-callback)
- [socket.sendto](./LUALIB_API_REFERENCE.md#socketsendtoid-addr-port-data)
- [socket.udp_address](./LUALIB_API_REFERENCE.md#socketudp_addressid)
- [socket.netstat](./LUALIB_API_REFERENCE.md#socketnetstatid)
- [socket.resolve](./LUALIB_API_REFERENCE.md#socketresolvehost-port)

---

## 集群通信 (skynet/cluster.lua)

### 集群调用
- [cluster.call](./LUALIB_API_REFERENCE.md#clustercallnode-address-)
- [cluster.send](./LUALIB_API_REFERENCE.md#clustersendnode-address-)
- [cluster.query](./LUALIB_API_REFERENCE.md#clusterquerynode-name)

### 集群管理
- [cluster.open](./LUALIB_API_REFERENCE.md#clusteropenport-maxclient)
- [cluster.reload](./LUALIB_API_REFERENCE.md#clusterreloadconfig)
- [cluster.proxy](./LUALIB_API_REFERENCE.md#clusterproxynode-name)
- [cluster.snax](./LUALIB_API_REFERENCE.md#clustersnaxnode-name-address)

### 服务注册
- [cluster.register](./LUALIB_API_REFERENCE.md#clusterregistername-addr)
- [cluster.unregister](./LUALIB_API_REFERENCE.md#clusterunregistername)

### 内部方法
- [cluster.get_sender](./LUALIB_API_REFERENCE.md#clusterget_sendernode)

---

## DNS 解析 (skynet/dns.lua)

### 主要方法
- [dns.server](./LUALIB_API_REFERENCE.md#dnsserverserver-port)
- [dns.resolve](./LUALIB_API_REFERENCE.md#dnsresolvename-callback)
- [dns.resolve_sync](./LUALIB_API_REFERENCE.md#dnsresolve_syncname-timeout)
- [dns.ip_to_str](./LUALIB_API_REFERENCE.md#dnsip_to_strip)
- [dns.str_to_ip](./LUALIB_API_REFERENCE.md#dnsstr_to_ipstr)

---

## 其他工具模块

### md5.lua
- [md5.sumhexa](./LUALIB_API_REFERENCE.md#coresumhexak)
- [md5.sum](./LUALIB_API_REFERENCE.md#coresumk)
- [md5.hmacmd5](./LUALIB_API_REFERENCE.md#corehmacmd5data-key)

### skynet/coroutine.lua
- [skynet.coroutine.resume](./LUALIB_API_REFERENCE.md#skynetcorotineresumeco-)
- [skynet.coroutine.running](./LUALIB_API_REFERENCE.md#skynetcorotinerunning)
- [skynet.coroutine.create](./LUALIB_API_REFERENCE.md#skynetcoroutinecreatef)
- [skynet.coroutine.status](./LUALIB_API_REFERENCE.md#skynetcorentinestatusco)

### skynet/datacenter.lua
- [datacenter.call](./LUALIB_API_REFERENCE.md#datacentercallname-)
- [datacenter.acall](./LUALIB_API_REFERENCE.md#datacenteracallname-)
- [datacenter.map](./LUALIB_API_REFERENCE.md#datacentermapname-func)

### skynet/harbor.lua
- [harbor.queryname](./LUALIB_API_REFERENCE.md#harborquerynamename)
- [harbor.register](./LUALIB_API_REFERENCE.md#harborregistername-addr)
- [harbor.link](./LUALIB_API_REFERENCE.md#harborlinkid)
- [harbor.linkmaster](./LUALIB_API_REFERENCE.md#harborlinkmaster)
- [harbor.unlink](./LUALIB_API_REFERENCE.md#harborunlinkid)

### skynet/multicast.lua
- [multicast.create](./LUALIB_API_REFERENCE.md#multicastcreatechannel-group-member)
- [multicast.send](./LUALIB_API_REFERENCE.md#multicastsendchannel-data)
- [multicast.del_group](./LUALIB_API_REFERENCE.md#multicastdel_groupgroup)

### skynet/queue.lua
- [queue.create](./LUALIB_API_REFERENCE.md#queuecreate)
- [queue.push](./LUALIB_API_REFERENCE.md#queuepushq-data)
- [queue.pop](./LUALIB_API_REFERENCE.md#queuepopq-timeout)

### skynet/sharedata.lua
- [sharedata.query](./LUALIB_API_REFERENCE.md#sharedataqueryname)
- [sharedata.update](./LUALIB_API_REFERENCE.md#sharedataupdatename-value)
- [sharedata.delete](./LUALIB_API_REFERENCE.md#sharedatadeletename)

### skynet/sharemap.lua
- [sharemap.new](./LUALIB_API_REFERENCE.md#sharemapnew)
- [sharemap.update](./LUALIB_API_REFERENCE.md#sharemapupdatemap-data)
- [sharemap.get](./LUALIB_API_REFERENCE.md#sharemapgetmap-key)

### skynet/sharetable.lua
- [sharetable.load](./LUALIB_API_REFERENCE.md#sharetableloadfilename)
- [sharetable.update](./LUALIB_API_REFERENCE.md#sharetableupdatefilename-tbl)
- [sharetable.save](./LUALIB_API_REFERENCE.md#sharetablesavefilename-tbl)

### skynet/socketchannel.lua
- [socketchannel.new](./LUALIB_API_REFERENCE.md#channelnewconf)
- [socketchannel:connect](./LUALIB_API_REFERENCE.md#channelconnect)
- [socketchannel:close](./LUALIB_API_REFERENCE.md#channelclose)
- [socketchannel:change](./LUALIB_API_REFERENCE.md#channelchangef)

### skynet/crypt.lua
- [crypt.hexencode](./LUALIB_API_REFERENCE.md#crypthexencodes)
- [crypt.hexdecode](./LUALIB_API_REFERENCE.md#crypthexdecodes)
- [crypt.base64encode](./LUALIB_API_REFERENCE.md#cryptbase64encodes)
- [crypt.base64decode](./LUALIB_API_REFERENCE.md#cryptbase64decodes)
- [crypt.xor_str](./LUALIB_API_REFERENCE.md#cryptxor_strs-key)
- [crypt.dhsecret](./LUALIB_API_REFERENCE.md#cryptdhsecret交换)
- [crypt.hmac_hash](./LUALIB_API_REFERENCE.md#crypthmac_hashk-s)
- [crypt.md5hash](./LUALIB_API_REFERENCE.md#cryptmd5hashs)
- [crypt.sha1](./LUALIB_API_REFERENCE.md#cryptsha1s)
- [crypt.desencode](./LUALIB_API_REFERENCE.md#cryptdesencodekey-s)
- [crypt.desdecode](./LUALIB_API_REFERENCE.md#cryptdesdecodekey-s)
- [crypt.randomkey](./LUALIB_API_REFERENCE.md#cryptrandomkey)

### skynet/db/redis.lua
- [redis.connect](./LUALIB_API_REFERENCE.md#redisconnectconf)
- [redis.pipeline](./LUALIB_API_REFERENCE.md#redispipeline)

### skynet/db/mongo.lua
- [mongo.client](./LUALIB_API_REFERENCE.md#mongoclientconf)
- [mongo.official](./LUALIB_API_REFERENCE.md#mongoofficial)

### skynet/db/mysql.lua
- [mysql.connect](./LUALIB_API_REFERENCE.md#mysqlconnectconf)

---

**完整文档**: [LUALIB_API_REFERENCE.md](./LUALIB_API_REFERENCE.md)
**快速参考**: [LUALIB_QUICK_REFERENCE.md](./LUALIB_QUICK_REFERENCE.md)
**代码示例**: [LUALIB_EXAMPLES.md](./LUALIB_EXAMPLES.md)
