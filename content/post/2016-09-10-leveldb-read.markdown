---
layout: post
title: "leveldb 源码笔记之 Read"
date: 2016-09-10
comments: true
categories: 
    - distribute
    - system
    - leveldb
---
### key逻辑分类

根据我们之前文章的描述，leveldb的数据存储可能存在在内存的memtable中，或者磁盘的sstalbe中，但是key的实际存储格式会略微有差异，代码里按照存储的位置，划分为以下几种类型：

>**memtable**: 逻辑上称为memtable_key

>**sstalbe**: 逻辑上称为internal_key

>**key**: 用户提供的key，我们称之为user_key

当用户去查询某个key时，leveldb会先利用key构建起Lookupkey类

Lookupkey类内部的完整数据即memtable_key，可以方便的利用成员函数截取memtable_key,internal_key,user_key以方便去memtalble和sstable中查询

事实上LookupKey是由 key， sequence number组成的，如之前文章提到:

- 如果普通Get()操作，sequence number 为 last sequence number
- 如果是使用的snapshot, sequence number 为 snapshot sequence number

``` cpp
// dbformat.h
// lookup key format:
// start_       kstart_                                         end_
//   |             |                                             |
//   |             |<--user_key-->|                              |
//   |             |<---------------internal_key---------------->|
//   |<---------------------memtable_key------------------------>|
//   -------------------------------------------------------------
//   |  1--5 byte  | klenght byte |           8 byte             |
//   -------------------------------------------------------------
//   | klenght + 8 |   raw key    | pack(sequence number, type)) |
//   -------------------------------------------------------------
// A helper class useful for DBImpl::Get()
class LookupKey {
 public:
  // Initialize *this for looking up user_key at a snapshot with
  // the specified sequence number.
  LookupKey(const Slice& user_key, SequenceNumber sequence);

  ~LookupKey();

  // Return a key suitable for lookup in a MemTable.
  Slice memtable_key() const { return Slice(start_, end_ - start_); }

  // Return an internal key (suitable for passing to an internal iterator)
  Slice internal_key() const { return Slice(kstart_, end_ - kstart_); }

  // Return the user key
  Slice user_key() const { return Slice(kstart_, end_ - kstart_ - 8); }

 private:
  const char* start_;
  const char* kstart_;
  const char* end_;
  char space_[200];      // Avoid allocation for short keys

  // No copying allowed
  LookupKey(const LookupKey&);
  void operator=(const LookupKey&);
};
```
如图:
![](/images/blog_images/leveldb/leveldb-keys.png)

### 读操作
图示Get()操作的基本逻辑如下：
![](/images/blog_images/leveldb/leveldb-read.png)
以上我们是假设sstable没有filter的情况下的操作逻辑

### cache
无论是table cache，还是block cache，都是使用了相同的数据结构LRUCache来实现的，区别只在于内部存储的数据不同。

LRUCache是通过k/v方式存储的，对于：

**TableCache**:

- key: 其实就是file number
```cpp
// table_cache.cc
char buf[sizeof(file_number)];
EncodeFixed64(buf, file_number);
Slice key(buf, sizeof(buf));
```
- value: TableAndFile， 其实主要是sstable index block里的数据
```cpp
// table_cache.cc
struct TableAndFile {
  RandomAccessFile* file;
  Table* table;
};

// table.cc
// Table里的主要数据即下述
struct Table::Rep {
    ~Rep() {
      delete filter;
      delete [] filter_data;
      delete index_block;
    }

    Options options;
    Status status;
    RandomAccessFile* file;
    uint64_t cache_id;
    FilterBlockReader* filter;
    const char* filter_data;

    BlockHandle metaindex_handle;  // Handle to metaindex_block: saved from footer
    Block* index_block;
};
```
**BlockCache**:

- key: 其实是 cache_id 和 block 在sstable中的offset的组合
```cpp
// table.cc
char cache_key_buffer[16];
// 构造block_cache 的key
EncodeFixed64(cache_key_buffer, table->rep_->cache_id);
EncodeFixed64(cache_key_buffer+8, handle.offset());
Slice key(cache_key_buffer, sizeof(cache_key_buffer));
```
- value: data block 内容
```cpp
// block.h
class Block {
 public:
  // Initialize the block with the specified contents.
  explicit Block(const BlockContents& contents);

  ~Block();

  size_t size() const { return size_; }
  Iterator* NewIterator(const Comparator* comparator);

 private:
  uint32_t NumRestarts() const;

  const char* data_;
  size_t size_;
  uint32_t restart_offset_;     // Offset in data_ of restart array
  bool owned_;                  // Block owns data_[]

  // No copying allowed
  Block(const Block&);
  void operator=(const Block&);

  class Iter;
};
```

#### cache 逻辑结构图示
![](/images/blog_images/leveldb/leveldb-cache.png)
