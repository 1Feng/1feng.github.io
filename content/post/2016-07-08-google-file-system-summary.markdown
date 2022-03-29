---
layout: post
title: "Google File System 笔记"
date: 2016-07-08
comments: true
categories:
    - distribute
    - system
---

### 创新点

 - 把组件故障当做常态，而不是异常。即，要有完备的监控，错误检测，故障恢复机制
 - 通常文件都是巨大的，数以GB是常态
 - 多数文件的修改是追加新数据，而不是覆盖已有数据
 - 综合应用以及系统API一起来设计，从而增加整个系统的灵活性

### 设计假设
- 整个系统构建在许多廉价的商用组件之上，所以故障是在所难免的
- 系统存储了适当数量（几千万）的大文件，大小从几百MB到数以GB不等
- 读操作通常包含大量的流式读取，和少量的随机读。应用可以通过对小的读取操作组合排序成批量操作从而提高效率
- 写操作通常是许多大量的顺序的写来追加数据到文件里
- 对于多client向同一文件并发append的情况，系统必须有效实现一套明确定义的规则
- 持续的高带宽比低延迟更重要

### 接口
只支持了一些常规的create，delete，open，close，read 以及 write接口，并没有支持POSIX标准的接口

### 架构
#### 整体架构图
![](/images/blog_images/gfs01.jpg)

- 系统整体由master，chunkservers，client三部分组成
- 文件的存储单元为chunk，chunk size = 64M(一般FS也就kb级别)，默认每个chunk有3个备份（可配置）
	- 大chunksize的优点：
		- 可以利用client的cache，有效减少client同master的交互
		- 意味着client能够在同一个chunkserver上执行更多的操作，节省了网络开销(如果chunksize过小，极端情况下一次数据读取要和多个chunkservers进行交互)
		- 大的chunk size 可以有效减少master上metadata的存储量
	- 大的chunksize的缺点：
		- 如果某个chunk 的访问过热，单机就会变为热点
			- 解决方案：优化业务 or 允许client从其他client获取数据
-  只有一个master角色，用以存储文件的元数据信息，同时这些元数据信息会备份在多个远程机器上
- Master通过HeartBeat与chunkservers保持通讯

#### 数据一致性模型
> GFS放宽了数据的一致性模型，从而降低系统的复杂度以及可以高效的实现

##### Namespace
- Namespace的修改（例如文件创建，重命名）操作是原子性的

##### File Region State
- File Region的状态取决于其修改的类型以及操作结果（成功与否），如图：
	- ![](/images/blog_images/gfs03.jpg)
	- Consisitent：不管从哪个replica读取数据，client看到的都是相同的数据
	- Inconsistent:  一般由操作失败引起
	- Defined：当一个改动操作完成，数据是consistent状态，并且client可以看到改动的内容
	- Undefined：
		- 并发操作存在相互影响时，数据虽然是consistent状体，但是无法看出每个client的修改（`例如并发的在同一个位置写入两次`）
		- inconsistent
- 概念区分（mutation）：
	- write: 向application指定的位置写入数据，offset由application指定
	- record append：即使并发操作情形，也会保证append  atomically at leaset once，offset是GFS选择的
- How to：
	- Success:
		- 通过确保mutations的顺序在所有的replicas上一致来保证defined
		- 使用chunk version number来检测旧的数据(某chunksever宕机时，mutation依旧会Success，然后导致旧数据产生)
	- Failure:
		- 利用Master和chunkservers的心跳以及数据的checksum来检测操作失败生成的脏数据（通过其他replicas来恢复）
##### Applications
- 通过以下技术手段，application可以迁就GFS的较为放松的一致性模型
	- relying on appends rather than overwrites
	- checkpointing
	- writing self-validating
	- self-identifying
- 场景举例：
	- 场景一： writer创建一个文件，并且从开始到结束（`写满即结束？`）一直持有这个文件，当数据写完，文件会被writer被重命名为一个permanent name; 或者，writer周期性的通过checkpoint记录写入成功了多少（`不太明白啥意思`）
		- checkpoint可以包含application级别的校验码(checksum)
		- reader只会检验和处理那些和checkpoint对比最新的file region，即defined状态的数据
		- checkpoint可以允许writer增量重启并且让reader继续处理那些在application看来还未完成的数据
		- 不管是并发还是一致问题，当前这个场景都可以较好的应对
	-	场景二: 利用多路归并合，或者通过生产者消费者队列完成多个writer并发的append 
		-	readers 处理偶然的padding和重复，如下：
			- 由writer对写入的record增加额外的checksum
			- 由reader通过checksum来剔除掉额外的padding数据或者其他record fragments
			- 如果reader可以容忍偶然的重复（例如触发了非幂等的操作），可以通过唯一标识来剔除掉重复

#### Master

![](/images/blog_images/GFS02.png)


> 上图为根据论文猜测的结构，比如location可能并不是以这种方式存储的，也有可能是通过所谓的chunk namespace来获取

##### DATA

- **Namespace**
	- 存储位置：disk + memory
	- File Namespace：
		- 启动时加载自Operation log
		- 数据结构为前缀压缩的lookup table，通常小于64byte
		- namespace tree 的每个节点（node）都有一个关联的读写锁
		- namespace的修改为原子操作（atomic）
	- Chunk namespace: `如果也是前缀压缩来实现，就解释不过去了，想不出chunk namespace有什么用`
		- 论文中仅有两次提及，具体不详
- **Access control information**
	- 存储位置：disk + memory
	- 备注： 文中较少提及，具体不详
- **Mapping from files to chunks**
	- 存储位置：disk + memory
	- 详解： 
		- 每个文件都被切分为了固定大小的chunk，master里仅存放chunk handle 以及 location
		- chunk handle 是个64bit的唯一标示（猜测是hash获得的,但是为什么不是chunknumber？）
- **Current locations of chunks**
	- 存储位置：memory
	- 详解： 
		- 通过询问chunkserver获取，一般在启动或者有新chunkserver加入等情况下发生
		- 与client交互时会把client请求的chunk的所有location都返回，由client自己决定（就近）与哪个chunkserver交互
- **Operation log**
	- 存储位置：disk
	- 详解：
		- 存放了关键元数据的改动记录
		- 数据同时备份在remote machines上 
		- 只有在数据刷新到磁盘上时，才响应client
		- 利用log replay来完成灾难恢复
		- 当日止文件超过一定大小，master会记录checkpoint（使用额外线程，不阻塞当前mutation）
		- B-tree结构存储（可以直接被加载进内存）的checkpoint，方便快速定位，恢复
##### 功能  
- **Namespace Management and Locking**
	- 简介：仅用于处理master内部操作(master's operations)并发冲突
	- 例子：我们在对/home/user目录进行snapshot的时候，如何避免同一时间创建/home/user/foo操作
		- 绿色R代表获取读锁，红色W代表获取写锁
		- ![](/images/blog_images/GFS_lock.png)
		- 如图：当create操作获取/home/user的读锁时，只能等到其他操作释放掉写锁才能继续
		- create操作不需要对父层目录（/home/user）加写锁,仅需要加读锁，防止该目录被删除即可
	- 注意：为了避免死锁，加锁是先按照namespace tree的level顺序进行的，同level按照字典序
- **Replica Placement**
	- 简介：处理chunk replica placement，从而保证scalability，reliability， and availability
	- 目的：最大化数据的可靠性和可用性，同时最大利用化带宽
	- 策略：不仅仅是跨机器，同时需要跨机架(racks)
		-  优点: 是充分保证了可靠性和可用性，同时读操作可以有效利用多机架的带宽资源
		-  缺点: 是跨机架(racks)同样带来的弊端就是写操作时，数据流向不得不得跨机架
- **Creation, Re-replication, Rebalancing**
	- 简介：chunk replicas 只在三种情况下被创建：chunk creation, re-replication, and rebalancing
	- Creation（where to place the initially empty replicas）：
		1. 放在磁盘空间利用低于所有chunkservers均值的chunkserver上
		2. 限制单个chunkserver最近创建数(如果数字过高，意味着chunkserver会迎来一波大量的写操作)
		3. 跨机架(racks)存放
	- Re-replication:  
		- when:  当可用的replicas数低于用户指定的数（默认为3）时
			- chunkservers unavailable
			- chunkservers report its replica corrupted（disk fail，error...）
			- 用户指定的replicas数进行了提升
		- where: 同Creation（此处限制的是单个chunkserver当前active clone操作的数）
	- Rebalance：
		- 对象：当前的replicas分配策略，以及移动已有的replicas
		- 目标:  获得较佳的磁盘使用率和负载均衡
		- 方式：定期的，缓慢进行（避免新的chunkserver一下负载大量写操作）
		- 策略：(选机器而不是选replica) 选择当前的磁盘剩余低于所有chunkservers均值的机器，对其replica进行move操作，从而均衡磁盘使用率
- **Garbage colleciton**
	- 简介：GFS的文件删除是一种lazy的方式，依赖定期垃圾回收来回收磁盘物理空间，回收包括file级别和chunk级别
	- 机制：
		- 对于要删除操作，修改文件名为隐藏的名字(hidden name,猜测就像linux带.前缀的文件名)，同时文件名带有删除时间戳
		- 定期扫描file namespace，发现如果这种文件存在超过指定时间(默认三天)则执行删除操作，同时删除其metadata
		- 定期扫描chunk namespace（`chunk 的 namespace是什么结构，有什么意义??`）
			- 标记那些失效的chunk(对应的文件已不存在)，删除其metadata
			- 同时利用和chunkservers的HeartBeat传递的信息，chunkservers会报告其持有的chunk集合，对比，告知其持有的chunk那些需要删除
	- 优点：
		- 增强了系统的容错性，失败操作造成的一些垃圾chunk，会通过此机制回收
		- 回收操作整合进了master的后台操作和与chunkservers的handshakes中，回收动作得以批量进行，整体开销被分担
		- 这种延迟删除的机制，同时避免了偶然和不可逆的删除操作
	- 缺点：
		- 浪费了存储空间，用户无法通过删除操作来立即释放空间
		- 解决方法：
			- 用户如果对于已经删除的文件再一次进行删除，系统将加快其回收的速度
			- 允许用户对不同的namespace制定不同的回收策略，以及复制策略（例如不进行备份/复制，其删除操作立即执行）
	- **Stale Replica Detection**
		- 定义：由于操作失败，或者chunkserver宕机造成chunk的修改没有被同步，形成了Stale Replica
		- 方案：
			- master持有chunk version number来区分某个chunk是否是旧的, 并通过垃圾回收机制来回收stale replica
			- 通过client的cache 超时时间以及重新打开文件来尽量限制client读取到过期数据（`文中区分了早期(premature)和过期(outdated)数据，某些业务场景读到premature数据应该是可以的`）
	

#### 系统交互

> 系统的整体设计旨在降低master的参与度，毕竟它是整个分布式系统中唯一一个单点，很容易形成瓶颈

##### 租契(leases)和改动顺序(mutation order)

- **背景**：一条修改操作要在所有的chunk replicas上执行，我们使用租契(leases)来管理这个修改顺序
- **描述**：
	- Master 向其中一个replicas发放租契(leases),该replica被称作 primary
	- Primary 针对chunk的所有修改动作选择一系列的顺序
	- 当改动提交时，其他replicas依照primary的顺序进行
- **目的**：降低master的管理开销
- **细节**：
	- Lease初始的超时时间为60s，超时则意味着当前lease失效，需要master重新下发
	- 如果Lease正在被执行，即chunk正在被执行改动，primary会通过和master交互来确保Lease的超时时间可以无限扩展
	- 上述中的交互是通过Master与chunkservers的HeartBeat捎带进行的
	- 同时，Master可以在Lease过期之前予以撤销（例如撤销重命名）
	- 即使Master和Primary的通讯断开了，在当前Lease过期前，他同样可以下发给其他replica一个新的Lease
	- 如果需要write的数据太大，或者跨越单个chunk，那么该操作会被client拆分成多个write操作；
		- 由于有多个client存在，这些操作会按照相同的顺序进行，但是其中可能会穿插其他client的操作
		- Shared file region 尾部可能包含来自多个client(`concurrent write`)的数据段(`比如clientA 向offset写入4个字节，clientB向ofset+2写入4个字节`)
- **示例**：
	- ![](/images/blog_images/gfs00.jpg)
		- 1.client 询问Master对于指定chunk哪个chunkserver持有了当前的lease，同时询问其他replicas的位置；如果没有lease，那么master会选择一个replica，然后下发一个Lease
		- 2.Master告知client当前primary的标识以及其他replicas的位置(secondary)，client会把这些数据cache起来，直到primary不可达或者其不再持有lease
		- 3.client会把所有数据push到所有的replicas，chunkservers 会把这些数据存放在内部的LRU cache中，直到过期或者被使用
		- 4.当所有replicas都确认收到了client push的数据，client会向Primary发送write请求，Primary会先行执行操作，同时会为改动操作分配一个序列号
		- 5.Primary想所有的secondary replicas转发此次写请求，secondary按照primary分配的序列号依次执行
		- 6.当操作完成，Secondary会向Primary进行确认回复
		- 7.Primary向Client进行回复，如果执行过程中有任何错误，都会反馈给client。如果写入失败，client会选择重试3-7。

##### 数据流
> 系统把数据流从控制流中解耦出来，在Figure2中可以明显看出

- **目标**：
	- 最大化单机带宽的使用
		- 采用线性的方式来push数据，确保单机的出口带宽可以被充分利用，而不是向树状push时需要将出口带宽分给多个replicas (`并没有理解这样有什么高效，树状不也是充分利用了么？后续树状散射push出去貌似可以更高效？`)
	- 避免网络瓶颈，和高延迟链接
		- 每个机器都向离其最近的机器push数据
		- distance 可以通过IP地址精确衡量（`内网IP吧，肯定是事先按照这种规则分配的IP`）
	- 最小化延迟
		- 利用TCP链接管道化数据传输，收到数据，立马向下转发，这依赖与全双工的链接（`结合这点，似乎能解释的通他比树状push数据高效了`）

##### Atomic Record Appends
> 传统的写入方式，如果client都指定在某个位置写入数据，那么并发写入同一region就不是序列化的，例如region结尾会包含来自多个client的数据段

- **描述**：GFS可以保证其追加操作至少有一次是原子性的(`at least once atomically`)，类似于没有竞争情况下的Unix O_APPEND 
	- GFS里大量使用了append操作(特意如此设计，避免随机写)，如果按照传统的做法，client端需要额外的负载逻辑以及昂贵的同步机制（例如分布式锁）
	- GFS系统中对这种并发写的的操作通常使用多生产者-单消费者模型或者多client归并结果进行处理
	- record append操作和write一样，遵循Lease那套规则
- **细节**：
	- 在执行append操作时，Primary会检查当前chunk(chunk固定最大64M)是否可以容纳这条记录
		- 如果不能，先填充满，填充操作不能超过chunk大小的1/4，避免过多碎片（`猜测：如果超了就让client去拆成多条`）
		- 告知secondaries执行相同操作，同时告知client去下一个chunk重试该操作
		- 如果能容纳，按照Figure2中的处理逻辑处理即可
	- 如果append失败：
		- replicas 相同的chunk上的数据就会不一致(有的成功，有的失败了)，replicas相互之间按字节不一致
		- 接下来的append操作需要在更高的offset上或者下一个chunk上去append即可
	
##### Snapshot
> 快照操作在保证最小化干扰当前的修改操作的情况下，利用copy-on-write瞬间完成对文件或文件夹的拷贝

- **细节**:
	- Master收到快照请求，会先撤销所涉及的chunk的所有未交付的Leases
	- Master 将此操作写入磁盘日志
	- 创建一个新的快照文件，其metadata 拷贝自源文件的metadata, 源文件对应的chunk引用计数都加一
	- 如果引用计数大于1的chunk要client被修改，那么Master会推迟响应client，然后告知chunkserver拷贝当前chunk（`系统所处的磁盘速度3倍于其百兆网卡`）
	- Master针对client的请求，对新拷贝的chunk执行Leases

#### 容错以及诊断

##### 高可用
>保证高可用的策略: faset recovery and replication

- **Chunk**
	- 主要规则：
		- 每个chunk都会在不同的chunkservers，不同的机架(racks)上进行备份
		- 用户可以指定不同namespace下的文件执行不同的备份级别
		- 备份损坏或者服务器下线后，master会再增加备份，以满足相应的备份级别
	- 未来规划：
		- 使用奇偶校验（partiy）
		- 使用纠删码（ensure codes）
- **Master**
	- Master通过备份来保证可靠性（`not availability，master始终是单点`）
	- replication：
		- 仅将operation log 和 checkpoints备份至多台机器
		- 只有operation log 被刷入磁盘，并同步至备份服务器后，mutation才被认为完成
		- 如果监测点发现Master不可用（机器宕机，磁盘挂了之类的），会将备份机启动为新的master，client通过dns规则可以快速对接到新的master上
	- shadow：（`区别于备份机`）
		- 仅对外提供只读服务
		- 通过读取master备份机上的operation log来保持状态一致，同步master的决策（`仅能保证最终一致性`）
		- chunk locations 也是在启东时通过询问chunkservers获取location信息，后续也会通过握手信息来监控其状态（相对Master而言频率较低）
		- shadow 上的元数据信息会落后与master
##### 数据完整性
- 由chunkservers端维护自己的数据校验
	- why?
		- 通过和其他备份进行交叉校验开销太大
		- 备份直接数据并不完全一样，例如GFS允许append失败发生时，有脏数据存在，不保证字节一致
	- how?
		- chunk被分为64KB大小的blocks，每个block有32bit的校验码
		- 校验码存放在内存中，并且持久化在日志里，和用户数据分离
		- 对于来自client或者其他chunkservers的读取操作：
			- 在返回数据前进行完整性校验，以保证损坏的数据不会传播
			- 如果校验结果失败
				- 返回错误码，并向master上报，master会令请求方去其他备份读取数据
				- 同时master会从其他备份拷贝当前chunk(`没有说是master让当前chunkservers去恢复，那文中提到read from another chunkserver是什么场景？`)
				- 当新的合法数据就位（`master并不一定把数据恢复到当前机器上，也有可能是在另外某台机器上新建了一份备份`），master会下令当前chunkservers删除其备份
			- 数据校验并不会对读取性能有很大影响，因为：
				- 大部分读取只会跨越很少的blocks，需要校验的数据非常少
				- 读取一方，尽量去对齐（align）读取数据的checksum block的边界来降低chunkservers数据校验成本（`对齐就优化了？意思是说每次尽量读整个block？关键每次写入也不一定写入一个完整的block？怎么生出校验码？`）
				- 校验码的查找和数据校验的工作并不会产生磁盘IO，所以这个动作可以和磁盘IO重叠进行
		- 校验码的计算在写入操作（append）进行的深度优化
			- 仅仅增量的去更新最后一部分的checksum block的校验码， 计算通过append新添加的新的 checksum blocks的校验码（`这里的checksum block 是个什么概念？`）
			- 即使最后一段的checksum block 已经损坏，而且我们没有检测到；新的checksum值也不会匹配存储的数据，在block下一次被读取时就会被检测到
		- 对于已经存在的chunk进行overwrite：
			- 我们必须读取并且验证被覆盖区域的第一个和最后一个block，然后执行写入操作
			- 否则，新的checksum就会隐藏其他没有被overwriten的区域的损坏数据
		- chunkservers在空闲时间会扫描验证不活跃的chunks，以此来对鲜有读取的损坏数据进行发现，master会重建备份（`通过这一点保证GFS的备份级别是准确的，而不是自以为是的`）

##### 诊断工具
- 通过广泛且详细的诊断日志，以微小的开销来来协助完不可测量（immeasurably）问题的隔离，调试，性能分析
	- 记录特定的事件（例如chunkservers 上线或者宕机）（`所以，究竟由谁来记录诊断日志？猜测是所有的角色都参与`）
	- 记录所有的RPC请求以及回复

### 经验总结

##### 业务
- 最初设想GFS只应用与产品环境，结果后来承担了科研和开发任务。因此例如权限，配额等功能被引入了进来

##### 实现
- GFS是依赖与linux 磁盘驱动，因为IDE接口协议版本不匹配有可能会造成数据损坏，也正是因为这一点促使了checksums机制的使用，同时开发团队也修改了kernel来处理这种协议不匹配
- linux 2.2 kenel中的fsync() 的开销是跟文件大小成比例的，而不是和被修改的局部大小。这影响了size较大的operation log的写性能，尤其是checkpoint实现之前。后来的解决方案是使用同步写来完成这个操作，最终迁移到了linux 2.4
- 涉及读写锁，mmap，当磁盘线程正在page之前的映射的数据时，锁会阻塞网络线程把数据映射进内存；最终把mmap()缓冲了pread()(`不是很懂`)

### 参考
[Google File System](http://static.googleusercontent.com/media/research.google.com/en//archive/gfs-sosp2003.pdf)



