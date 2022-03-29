---
layout: post
title: "Linux cpu load"
date: 2016-05-05
comments: true
categories: 
     - linux
     - system
---

## 简析
工作一直是在linux环境下，经常通过top，uptime来查看当前机器的负载（load average）, 但是始终对这个概念比较模糊，无法描述清楚这个值所反馈的真实含义，抽时间读了网上的一些文章，简单做下笔记：
 
- **introduction** ：例如 load average: 0.03, 0.05, 0.06 后面三个数字代表了过去1分钟，5分钟，15分钟的CPU平均负载；
- **Threshold** ：如果当前机器是一个N核CPU（grep 'model name' /proc/cpuinfo | wc -l），则load average的上限就是N，具体如下：
	- 预警：0.7*N
	- 上限：1.0*N
	- WTF：5.0*N
- **tips** ：
	- 1分钟，5分钟，15分钟三个参考数据，着重参考后两者即可，1分钟内如果超过1.0*N，并无大碍
>以上来自互联网前辈们工程实践的总结

## 原理
尝试看下kernel里是怎么计算load值的：

**定时计算**
```cpp
// linux-2.6.32.68/kernel/timer.c
// jiffies记录了电脑开机到现在总共的时钟中断次数
// 如果系统的时钟频率是1000（由宏HZ设置），即1秒中断1000次，每1ms中断一次
// 我们暂时不管ticks到底是代表了几次中断，总之每个ticks周期，都会调用load的计算函数
void do_timer(unsigned long ticks)
{
    jiffies_64 += ticks;
    update_wall_time();
    calc_global_load();
}
// linux-2.6.32.68/kernel/sched.h
/*
 * These are the constant used to fake the fixed-point load-average
 * counting. Some notes:
 *  - 11 bit fractions expand to 22 bits by the multiplies: this gives
 *    a load-average precision of 10 bits integer + 11 bits fractional
 *  - if you want to count load-averages more often, you need more
 *    precision, or rounding will get you. With 2-second counting freq,
 *    the EXP_n values would be 1981, 2034 and 2043 if still using only
 *    11 bit fractions.
 */
// 上述大意，是采用了10 bit整数 + 11 bits的分数的fixed-point形式来表示，并非通常的float-point
#define FSHIFT      11      /* nr of bits of precision */
#define FIXED_1     (1<<FSHIFT) /* 1.0 as fixed-point */
#define LOAD_FREQ   (5*HZ+1)    /* 5 sec intervals */
#define EXP_1       1884        /* 1/exp(5sec/1min) as fixed-point */
#define EXP_5       2014        /* 1/exp(5sec/5min) */
#define EXP_15      2037        /* 1/exp(5sec/15min) */

// linux-2.6.32.68/kernel/sched.c
void calc_global_load(void)
{
    unsigned long upd = calc_load_update + 10; 
    long active;

    // 如果 jiffies 小于 upd，直接return
    // 当前距离上次计算超过5 second + 10个ticks（如果HZ == 1000，即10ms）则触发计算
    if (time_before(jiffies, upd)) 
        return;

    active = atomic_long_read(&calc_load_tasks);
    active = active > 0 ? active * FIXED_1 : 0;

    // 直观上看，这三次计算分别对应的应该是1分钟，5分钟，15分钟三个load值
    avenrun[0] = calc_load(avenrun[0], EXP_1, active);
    avenrun[1] = calc_load(avenrun[1], EXP_5, active);
    avenrun[2] = calc_load(avenrun[2], EXP_15, active);
    // 计算完成后更新 cal_load_update
    // LOAD_FREQ = 5HZ + 1  即约等于 5 seconds
    // 其实cal_load_update指定了下次计算的时间点
    calc_load_update += LOAD_FREQ;
}

static unsigned long
calc_load(unsigned long load, unsigned long exp, unsigned long active)
{
    load *= exp;
    load += active * (FIXED_1 - exp); 
    return load >> FSHIFT;
}
```
截至目前，我只知道了计算间隔约5秒钟
没看懂EXP_1，EXP_5, EXP_15，FSHIFT这几个magic number，冥冥中感觉前三个应该跟1分钟，5分钟，15分钟有关
active代表的又是什么？感觉像是指的active状态的task数量（最近刚读完[《Operating Systems: Three Easy Pieces》](http://pages.cs.wisc.edu/~remzi/OSTEP/#book-chapters)）

追溯下 calc_load_task变量：

```cpp
// linux-2.6.32.68/kernel/sched.c
// 发现针对calc_load_task的删除操作
/*
 * remove the tasks which were accounted by rq from calc_load_tasks.
 */
static void calc_global_load_remove(struct rq *rq)
{
    atomic_long_sub(rq->calc_load_active, &calc_load_tasks);
    rq->calc_load_active = 0;
}
// 发现针对calc_load_task的添加操作
/*      
 * Either called from update_cpu_load() or from a cpu going idle
 */
// 更新calc_load_tasks动作，是在load的计算之后进行的
// do_timer()被调用之后又调用的update_process_times() -> calc_load_account_active() -> update_cpu_load() -> calc_load_account_active（）
// 但是calc_load_account_active（）也是每隔LOAD_FREQ执行一次，avg_load计算的是前一个LOAD_FREQ周期的数据，计算完了，然后calc_load_task再被更新   
static void calc_load_account_active(struct rq *this_rq)
{
    long nr_active, delta;

    // 结合rq定义看，所谓 active 就是R，D类型的进程数
    nr_active = this_rq->nr_running;
    nr_active += (long) this_rq->nr_uninterruptible;

    // 如果一个LOAD_FREQ周期内，nr_active数量有发生变化，则计算delta
    if (nr_active != this_rq->calc_load_active) {
        // delta 是指当前一个LOAD_FREQ周期新增的R,D进程数
        delta = nr_active - this_rq->calc_load_active;
        this_rq->calc_load_active = nr_active;
        // 疑问：既然每次都加delta，calc_load_tasks 其实就等于nr_active嘛，直接atomic_long_set不就完了？？
        atomic_long_add(delta, &calc_load_tasks);
    }
}
// 查看 rq的定义: per-CPU runqueue data structure
/*
 * This is the main, per-CPU runqueue data structure.
 *
 * Locking rule: those places that want to lock multiple runqueues
 * (such as the load balancing or the thread migration code), lock
 * acquire operations must be ordered by ascending &runqueue.
 */
struct rq {
    ...
    /*
     * nr_running and cpu_load should be in the same cacheline because
     * remote CPUs use both these fields when doing load calculation.
     */
    // 可运行的进程数量（进程状态以及含义可以自行google）-----状态码 R (TASK_RUNNING)
    unsigned long nr_running;    // kernel里的number类型都以nr作为前缀
    ...
    /*
     * This is part of a global counter where only the total sum
     * over all CPUs matters. A task can increase this counter on
     * one CPU and if it got migrated afterwards it may decrease
     * it on another CPU. Always updated under the runqueue lock:
     */
    // 不可中断睡眠状态进程数-----状态码 D (TASK_UNINTERRUPTIBLE)
    unsigned long nr_uninterruptible;
    ...
    /* calc_load related fields */
    unsigned long calc_load_update;
    long calc_load_active;
}
```
再尝试看下avenrun数组内的数据都在哪里被使用了，最终是怎么输出到/proc/loadavg（uptime，top里的load数据都源于此文件）

```cpp
// linux-2.6.32.68/kernel/sched.c
/**
 * get_avenrun - get the load average array
 * @loads:  pointer to dest load array
 * @offset: offset to add
 * @shift:  shift count to shift the result left
 *
 * These values are estimates at best, so no need for locking.
 */
void get_avenrun(unsigned long *loads, unsigned long offset, int shift)
{
    loads[0] = (avenrun[0] + offset) << shift;
    loads[1] = (avenrun[1] + offset) << shift;
    loads[2] = (avenrun[2] + offset) << shift;
}

// linux-2.6.32.68/fs/proc/loadavg.c
// 从这两个宏可以看出，avnrun内元素，低11位为分数,高位是10进制的整数
// 其实之前FSHIFT处的注释就说过了'fixed-point' && '10 bits integer + 11 bits fractional'
#define LOAD_INT(x) ((x) >> FSHIFT)
#define LOAD_FRAC(x) LOAD_INT(((x) & (FIXED_1-1)) * 100)
  
static int loadavg_proc_show(struct seq_file *m, void *v) 
{
    unsigned long avnrun[3];
  
    get_avenrun(avnrun, FIXED_1/200, 0); 
  
    // 看输出格式，应该就是/proc/loadavg内的数据无疑
    seq_printf(m, "%lu.%02lu %lu.%02lu %lu.%02lu %ld/%d %d\n",
        LOAD_INT(avnrun[0]), LOAD_FRAC(avnrun[0]),
        LOAD_INT(avnrun[1]), LOAD_FRAC(avnrun[1]),
        LOAD_INT(avnrun[2]), LOAD_FRAC(avnrun[2]),
        nr_running(), nr_threads,
        task_active_pid_ns(current)->last_pid);
    return 0;
}
```
以上，我们知道了load计算其实只是利用了cpu 当前的R，D状态的进程数，仍旧未解的问题：
>1. calc_load_tasks 存放的竟然是当前的R,D状态的进程数，更新周期为LOAD_FREQ，那究竟是如何计算出过去1,5,15分钟的平均load的，load的计算具体公式是什么？
>2. 具体的那几个magic number到底什么含义？

通过kernel代码里calc_load()的实现，可以看到在计算当前load的时候，变量只有active，公式 ：
	load(N) = (load(N-1)*EXP + active*(2^11 - EXP) )/ 2^11

很明显这不是朴素的平均数计算方法，奈何统计学学的实在不咋滴，思考良久依旧不知所以。

回想下朴素的计算方式，考虑目前我们可以做到5秒统计一次当前的active tasks数量，那么如果是我自己来实现，统计过去1分钟的平均值，我会进行如下设计：
![](/images/blog_images/cpu_load.png)

用长度12（60 s / 5s = 12）的链表来存储，每个周期（5s）,会在首部添加一个节点，记录当前的active tasks数量，并删除尾端的节点；整个链表则可以随时用来计算过去的1分钟，active tasks的平均数量，即avg_load = count(list_node)/12
但是，每次更新都有一次插入，一次删除，而且需要进行加锁操作，在kernel里这样实现应该不是一个好的方案，另外还需要了解的一点就是处于性能的考虑kernel里不支持浮点数操作


最后不断google，发现了[《UNIX Load Average Part 1》](http://www.teamquest.com/files/9214/2049/9761/ldavg1.pdf) , 同样是解析load，写的比我详细，并且对magic number做了详细解释，文中指出此处计算的是 ***exponentially-damped moving averages***，这也只是[moving averages](https://en.wikipedia.org/wiki/Moving_average)的一种计算方式（冥冥之中感觉这种计算方法应用很广啊，例如流式数据朴素的平均数计算相当浪费内存，如果也可以这样……，果然数学优化比工程优化要牛逼的多啊）。



## 总结
**Load average 其实就是任务队列的长度（TASK_RUNNING, TASK_UNINTERRUPTIBLE进程的数量）的MOVING AVERAGES**

>很显然，TASK_UNINTERRUPTIBLE状态的进程数量如果增多，也会引起load average 增高，但是TASK_UNINTERRUPTIBLE状态的进程并没有在消耗CPU，例如可能是在做IO 等待等，所以load 如果短时升高，也没有问题；同样，如果长时间很高，也有可能是磁盘IO负载较高引起的。

>load 其实没有一个纸面上的阈值，只能凭借对操作系统知识的了解，以及工作场景等实际经验来判断load的含义，其值也只是用来发现问题，而不是解释问题的，如果发现load过高，还是需要在实际场景上去寻找问题原因，进行针对性优化

-------------------
**参考资料：**

1. [Process State Definition](http://www.linfo.org/process_state.html)
2. [CFS Scheduler](https://www.kernel.org/doc/Documentation/scheduler/sched-design-CFS.txt)
3. [Examining Load Average](http://www.linuxjournal.com/article/9001?page=0,1)
4. [Unix/Linux 的 Load 初级解释 ](http://dbanotes.net/arch/unix_linux_load.html)
5. [Understanding linux cpu load - when should you be worried?](http://blog.scoutapp.com/articles/2009/07/31/understanding-load-averages)
6. [UNIX Load Average Part 1: How It Works](http://www.teamquest.com/files/9214/2049/9761/ldavg1.pdf)
7. [UNIX Load Average Part 2: Not Your Average Average](http://www.teamquest.com/files/6714/2049/9760/ldavg2.pdf)
