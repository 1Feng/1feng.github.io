---
layout: post
title: "leveldb 源码笔记之 Compact"
date: 2016-09-06
comments: true
categories:
    - distribute
    - leveldb
---
### 简介
leveldb中只有minor compaction 和 major compaction两种

- 代码中通过调用`DBImpl::MaybeScheduleCompaction()`来触发两种compaction
```cpp
// db_impl.cc
void DBImpl::MaybeScheduleCompaction() {
  mutex_.AssertHeld();
  // 确保只有一个后台线程在做compact
  if (bg_compaction_scheduled_) {
    // Already scheduled
  } else if (shutting_down_.Acquire_Load()) {
    // DB is being deleted; no more background compactions
  } else if (!bg_error_.ok()) {
    // Already got an error; no more changes
  } else if (imm_ == NULL &&
             manual_compaction_ == NULL &&
             !versions_->NeedsCompaction()) {
    // No work to be done
  } else {
    bg_compaction_scheduled_ = true;
    // 启动compact线程,主要逻辑是通过DBImpl::BackgroundCompaction()实现
    env_->Schedule(&DBImpl::BGWork, this);
  }
}
```
调用时机:

- 1.每次写入前，需要确保空间充足，如果空间不足，尝试将memtable转换为immutable-memtable，之后调用`DBImpl::MaybeScheduleCompaction()`
- 2.每次重启db，binlog recover结束后，会触发调用`DBImpl::MaybeScheduleCompaction()`
- 3.每次读取一条记录结束时会触发调用`DBImpl::MaybeScheduleCompaction()`




### minor compaction
#### 方式

- 将immutalbe-memtable dump到磁盘，形成sstable
- sstable一般位于level-0,如果sstable的key范围和当前level没有重叠会尝试下移，最多不会超过`config::kMaxMemCompactLevel(默认为2)`

#### 触发时机

- 每次调用BackGroudCompaction如果存在immutalbe-memtable都会触发将其dump到磁盘


### major compaction

#### 方式

- 将level-n的sstable 与 level-(n+1)中与之存在key范围重叠的sstable多路归并，生成level-(n+1)的sstable
- 如果是level-0,则由于level-0中sstable之间key有重叠，所以level-0参与compact的sstable可能不止一个

#### 触发时机

第一种是size触发类型(优先)：

```cpp
// version_set.cc
void VersionSet::Finalize(Version* v) {
  // Precomputed best level for next compaction
  int best_level = -1;
  double best_score = -1;

  for (int level = 0; level < config::kNumLevels-1; level++) {
    double score;
    if (level == 0) {
      // We treat level-0 specially by bounding the number of files
      // instead of number of bytes for two reasons:
      //
      // 对于较大的write buffer, 不过多的进行levle-0的compactions是好的
      // (1) With larger write-buffer sizes, it is nice not to do too
      // many level-0 compactions.
      //
      // 因为每次读操作都会触发level-0的归并，因此当个别的文件size很小的时候
      // 我们期望避免level-0有太多文件存在
      // (2) The files in level-0 are merged on every read and
      // therefore we wish to avoid too many files when the individual
      // file size is small (perhaps because of a small write-buffer
      // setting, or very high compression ratios, or lots of
      // overwrites/deletions).
      score = v->files_[level].size() /
          static_cast<double>(config::kL0_CompactionTrigger);
    } else {
      // Compute the ratio of current size to size limit.
      const uint64_t level_bytes = TotalFileSize(v->files_[level]);
      score = static_cast<double>(level_bytes) / MaxBytesForLevel(level);
    }

    if (score > best_score) {
      best_level = level;
      best_score = score;
    }
  }

  v->compaction_level_ = best_level;
  v->compaction_score_ = best_score;
}
```

- 对于level-0:
  - score = level-0文件数/config::kL0_CompactionTrigger(默认为4)

- 对于level-n(n>0)：
  - score = 当前level的字节数 / (10^n * 2^20)  2^20 即1MB

- score >= 1,当前level就会被标识起来，等待触发 compaction

第二种是seek触发:

```cpp
// version_edit.h

// 记录了文件编号， 文件大小，最小key，最大key
// sstable文件的命名就是按照file number + 特定后缀完成的
struct FileMetaData {
  int refs;
  int allowed_seeks;          // Seeks allowed until compaction
  uint64_t number;
  uint64_t file_size;         // File size in bytes
  InternalKey smallest;       // Smallest internal key served by table
  InternalKey largest;        // Largest internal key served by table

  FileMetaData() : refs(0), allowed_seeks(1 << 30), file_size(0) { }
};

// version_set.cc

// Apply all of the edits in *edit to the current state.
void Apply(VersionEdit* edit) {
  ...
  for (size_t i = 0; i < edit->new_files_.size(); i++) {
    const int level = edit->new_files_[i].first;
    FileMetaData* f = new FileMetaData(edit->new_files_[i].second);
    f->refs = 1;
    // We arrange to automatically compact this file after
    // a certain number of seeks.  Let's assume:
    //   (1) One seek costs 10ms
    //   (2) Writing or reading 1MB costs 10ms (100MB/s)
    //   (3) A compaction of 1MB does 25MB of IO:
    //        1MB read from this level
    //        10-12MB read from next level(boundaries may be misaligned)
    //        10-12MB written to next level
    // This implies that 25 seeks cost the same as the compaction
    // of 1MB of data.  I.e., one seek costs approximately the
    // same as the compaction of 40KB of data.  We are a little
    // conservative and allow approximately one seek for every 16KB
    // of data before triggering a compaction.
    // 1次seek相当与compact 40kb的data,
    // 那么n次seek大概和compact一个sstable相当(n = sstable_size / 40kb)
    // 保守点，这里搞了个16kb
    f->allowed_seeks = (f->file_size / 16384);  // 2^14 == 16384 == 16kb
    if (f->allowed_seeks < 100) f->allowed_seeks = 100;
    ...
  }
  ...
}
```
- 当一个新的sstable建立时，会有一个allowed_seeks的初值：
  - 作者认为1次sstable的seek（`此处的seek就是指去sstable里查找指定key`），相当于compact 40kb的数据，那么 sstable size / 40kb  次的seek操作，大概和compact 一个 sstable相当
  - 保守的做法，allowed_seeks的初值为file_size/16kb
  - 如果allowed_seeks小于100，令其为100
- 每当Get操作触发磁盘读，即sstable被读取，该数值就会减一；如果有多个sstable被读取，则仅首个被读取的sstable的sllowed_seeks减一
- allowed_seeks == 0 时，该sstable以及其所处level会被标识起来，等待触发 compaction

#### sstable选择：

- 针对size触发类型，默认从当前level的首个sstable开始执行

- seek触发相对简单，sstable已经选择好了

- 对于level-0,需要将与选中的sstable存在key重叠的sstable也包含进此次compact

- 对于level-(n+1)，需要将与level-n中选中的sstable存在key重叠的sstable包含进此次compact
>由于level-(n+1)多个sstable的参与扩展了整个compact的key的范围, 我们可以使用该key范围将level-n中更多的sstable包含进此次compact
>前提是保证level-n更多sstable的参与不会导致level-(n+1)的sstable数量再次增长.
>同时，参与整个compaction的字节数不超过kExpandedCompactionByteSizeLimit = 25 * kTargetFileSize = 25 * 2MB;

- 为了保持公平，保证某个level中每个sstable都有机会参与compact:
  - 存储当前level首次compact的sstable(s)的largest key，存入compact_point_[level]
  - 当前level如果再次被size触发进行compact时，选择首个largest key大于compact_point_[level] sstable进行compact
