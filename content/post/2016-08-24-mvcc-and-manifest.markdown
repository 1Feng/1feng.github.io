---
layout: post
title: "leveldb 源码笔记之 MVCC && Manifest"
date: 2016-08-24
comments: true
categories: 
    - distribute
    - system
    - leveldb
---
### MVCC

**问题**:
针对同一条记录，如果读和写在同一时间发生时，reader可能会读取到不一致或者写了一半的数据

**常见解决方案**
>悲观锁：
>>最简单的方式,即通过锁来控制并发，但是效率非常的低,增加的产生死锁的机会

>乐观锁：
>>它假设多用户并发的事物在处理时不会彼此互相影响，各食物能够在不产生锁的的情况下处理各自影响的那部分数据。在提交数据更新之前，每个事务会先检查在该事务读取数据后，有没有其他事务又修改了该数据。如果其他事务有更新的话，正在提交的事务会进行回滚;这样做不会有锁竞争更不会产生思索，但如果数据竞争的概率较高，效率也会受影响

>MVCC -- Multiversion concurrency control:
>> 每一个执行操作的用户，看到的都是数据库特定时刻的的快照(snapshot), writer的任何未完成的修改都不会被其他的用户所看到;当对数据进行更新的时候并是不直接覆盖，而是先进行标记, 然后在其他地方添加新的数据，从而形成一个新版本, 此时再来读取的reader看到的就是最新的版本了。所以这种处理策略是维护了多个版本的数据的,但只有一个是最新的。

### Key/Value
如[前文](http://1feng.github.io/2016/08/18/leveldb-write/)所述，leveldb中写入一条记录，仅仅是先写入binlog，然后写入memtable

- **binlog**: binlog的写入只需要append，无需并发控制

- **memtable**: memtable是使用Memory Barriers技术实现的无锁的skiplist

- **更新**: 真正写入memtable中参与skiplist排序的key其实是包含sequence number的，所以更新操作其实只是写入了一条新的k/v记录, 真正的更新由compact完成

- **删除**: 如[前文](http://1feng.github.io/2016/08/18/leveldb-write/)提到，删除一条Key时，仅仅是将type标记为kTypeDeletion，写入(同上述写入逻辑)了一条新的记录，并没有真正删除,真正的删除也是由compact完成的

#### Sequence Number
- sequence number 是一个由VersionSet直接持有的全局的编号，每次写入（`注意批量写入时sequence number是相同的`），就会递增


- 根据我们之前对写入操作的分析，我们可以看到，当插入一条key的时候，实际参与排序，存储的是key和sequence number以及type组成的
InternalKey


- 当我们进行Get操作时，我们只需要找到目标key，同时其sequence number <= specific sequence number
  - 普通的读取，sepcific sequence number == last sequence number
  - snapshot读取，sepcific sequenc number == snapshot sequence number

#### Snapshot
snapshot 其实就是一个sequence number，获取snapshot，即获取当前的last sequence number

例如：
``` cpp
  string key = 'a';
  string value = 'b';
  leveldb::Status s = db->Put(leveldb::WriteOptions(), key, value);
  assert(s.ok())
  leveldb::ReadOptions options;
  options.snapshot = db->GetSnapshot();
  string value = 'c';
  leveldb::Status s = db->Put(leveldb::WriteOptions(), key, value);
  assert(s.ok())
  // ...
  // ...
  value.clear();
  s = db->Get(leveldb::ReadOptions(), key, &value);   // value == 'c'
  assert(s.ok())
  s = db->Get(options, key, &value);   // value == 'b'
  assert(s.ok())
```

- 我们知道在sstable compact的时候，才会执行真正的删除或覆盖，而覆盖则是如果发现两条相同的记录
会丢弃旧的(sequence number较小)一条，但是这同时会破坏掉snapshot
- 那么 key = 'a', value = 'b'是如何避免compact时被丢弃掉的呢？
  - db在内存中记录了当前用户持有的所有snapshot
  - smallest snapshot = has snapshot ? oldest snapshot : last sequence number
  - 当进行compact时，如果发现两条相同的记录，只有当两条记录的sequence number都小于 smallest snapshot 时才丢弃掉其中sequence number较小的一条

### Sstable
sstable级别的MVCC是利用Version和VersionEdit实现的：

- 只有一个current version，持有了最新的sstable集合
- VersionEdit代表了一次current version的更新, 新增了那些sstable，哪些sstable已经没用了等

![](/images/blog_images/leveldb/mvcc.png)

### Mainifest
每次current version 更新的数据(即新产生的VersionEdit)都写入mainifest文件，以便重启时recover

![](/images/blog_images/leveldb/write_a_manifest.png)
