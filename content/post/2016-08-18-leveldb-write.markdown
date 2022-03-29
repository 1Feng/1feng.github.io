---
layout: post
title: "leveldb源码笔记之 Write"
date: 2016-08-18
comments: true
categories:
    - distribute
    - leveldb
---
#### 插入一条K/V记录
![](/images/blog_images/leveldb/writer.png)

#### 持有Writer的线程进入Writers队列,细节如下：
![](/images/blog_images/leveldb/writers_queue.png)

#### MakeRoomForWrite的流程图：
![](/images/blog_images/leveldb/make_room_for_write.png)

#### 记录会首先写入磁盘上的binlog，避免程序crash时内存数据丢失：
![](/images/blog_images/leveldb/write_to_binlog.png)
>此处我们做了一个极度夸张的假设来做演示:两条记录的大小超出一个block的大小, 以至于被一切为三

#### K/V记录插入内存中的Memtable:
![](/images/blog_images/leveldb/write_to_memtable.png)
