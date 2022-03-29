---
layout: post
title: "Signal with mutex locked or not(译)"
date: 2016-07-20
comments: true
categories:
    - concurrency
    - system
---

[原文链接](http://www.domaigne.com/blog/computing/condvars-signal-with-mutex-locked-or-not/)

## 介绍

当我们使用条件变量的时候，总有这样一个问题：到底该在解锁mutex之前进行sinal/broadcast，还是在之后？


什么时候进行signal？

``` c
pthread_mutex_lock(&mutex);
predicate=true;
pthread_cond_signal(&cv);    // OR: pthread_mutex_unlock(&mutex);
pthread_mutex_unlock(&mutex); //  : pthread_cond_signal(&cv);

```

## 权威解答

[SUS7](http://pubs.opengroup.org/onlinepubs/9699919799/functions/pthread_cond_signal.html)中提到：
>当其他线程利用pthread_cond_wait() 或pthread_cond_timedwait() 在关联的条件变量上等待时，当前线程既可以在持有（锁住）mutex时调用pthread_cond_broadcast()或 pthread_cond_signal() ，也可以在不持有mutex的情况下调用。然而，如果需要可预测的线程调度行为，则需要在mutex被锁住的情况下调用pthread_cond_broadcast() 或 pthread_cond_signal()

上述具体时什么意思呢？

## 锁住mutex时进行signal


在某些平台上，OS就在 signal/boadcast 之后进行上下文切换（context switch）来唤醒等待线程以达到降低延迟的效果。在一个单处理的系统上，如果我们在持有mutex的情况signal/broadcast则会导致不必要的上下文切换（context switch）.

- ![Fig 1- 锁住mutex时进行signal，我们造成了两次不必要的上下文切换（context switch）](/images/blog_images/signal-ctx-switch.jpg)

事实上，考虑figure 1中的场景。线程T2阻塞在条件变量上。当 T1 在持有关联的mutex的情况下 signal 条件变量时，上下文切换至T2导致T2被唤醒。但是在pthread_cond_wait返回之前，T2需要锁住条件变量关联的mutex。然而条件变量关联的mutex此时仍被T1持有（锁住）。结果导致T2被阻塞（由于mutex竞争）并且上下文切换至T1。之后T1解锁条件变量关联的mutex，同时T2最终变为runalbe状态。当我们对多个线程进行条件变量broadcast（多播）时，情况会变的更加糟糕。

有些Pthreds 使用名为 **wait morphing** [1]的优化实现方式来应对这个缺陷。这种优化可以在持有锁的情况下避免上下文切换(context swith)直接将线程从条件变量队列转移至mutex队列。例如 NPTL 使用了**类似的技术**[2]来优化broadcat.

当我们的实现没有使用 wait morphing时，我们可能需要先解锁然后在进行 signal/broadcast. 事实上，解锁操作不会导致上下文切换至T2，因为T2阻塞在了条件变量上。当signal/broadcast之后，T2被唤醒后会发现mutex已经被解锁，便可以持有mutex。


## 解锁mutex后signal

这样（译者注：解锁mutex后signal）存在缺点么？首先我们关注一个不同的情形。如果我们先signal或者broadcast，我们可以确保唤醒一个阻塞在条件变量上的线程（假设存在这样一个线程）。然而，如果我们先解锁，我们可能会唤醒一个阻塞在mutex上的线程。

什么时候会出现这种情形呢？一个thread可能阻塞在mutex上，因为：

- 线程即将检查谓词（译者注：条件变量的等待条件），并且最终会等待在条件变量上
- 线程即将修改谓词，并且最终会通知等待在条件变量上的线程

在第一种情况下，我们可能获取一个被拦截的唤醒。事实上，再次考虑figure 1中的情形，但是存在第三个线程T3，T3阻塞在mutex上(`译注：即将检查谓词`)。当T1解锁mutex，上下文切换至T3。现在T3发现谓词为真，因此执行相应处理，并且最终会在T1 signal/broadcast 条件变量之前重置谓词。当T2被唤醒，出发唤醒的条件已经不存在。在一个正确的程序设计中，这不是一个问题（`译注：只要你不对调度结果有所期待，这肯定不是问题`），因为T2总是会应对假唤醒（`译注：即使被唤醒也会再次检查谓词`）。下面的程序演示了被拦截的唤醒情形。

[Download cv_01.c](http://www.domaigne.com/blog/wp-content/plugins/wp-codebox/wp-codebox.php?p=33&download=cv_01.c)

在第二个例子（`译注：即线程即将修改谓词，并且最终会通知等待在条件变量上的线程`）里，我们最终延迟了T2的唤醒。实时上，T3可以发现T1已经修改了谓词，并且决定不再signal/broadcast。只要T1不被调度并获得机会signal/broadcast，那么T2会仍旧会阻塞。（`译注：一般是不会取消signal的，至少我不知道什么时候会这样做，这里只是假设你这样做了，会有潜在风险，这种风险也可以通过修改设计来避免的`）

## 考虑实时调度

在实时系统程序设计中，线程的优先级通常会被截止时间的临界所影响。 概括的说，越临近结束时间，优先级越高。不遵守时限可能会造成系统失败，结果可能会损坏我在之前[《Real World Sytems》](http://www.domaigne.com/blog/computing/real-world-systems/)中讨论的环境。

考虑这种情形，你明确的想要最高优先级的线程在变为runnable状态时可以尽快获取CPU时间片，但是低优先级的线程却可能阻止高优先级的线程运行，这种情形被称为优先级倒置。这种情况发生的一个例子就高优先级的线程想要锁住一个已经被低优先级线程持有的mutex。只要优先级倒置的持续时间总是很少或被限制的，这事实就不是一个问题。一个更严重的情况是优先级倒置（潜在的）不被限制, 这可能倒置高优先级的线程错过截止时间，像**优先级顶置**或**优先级继承** [3]这种协议就是被设计来规避这种问题的。
> 译者注：
> - 优先级置顶：就是给共享资源设置一个预定的优先级，这个优先级肯定大于所有会请求这个资源的线程，哪个线程获取了资源，它的优先级就提升到这个预定的优先级，这样它就会比高优先级的线程的优先级还高，等当前线程运行完不再持有共享资源，资源会率先被优先级其次的获取，同时当前线程优先级恢复正常，一切继续。这样就避免了中间优先级的线程拦截持有共享资源
> - 优先级继承：低优先级的线程获取了共享资源后，优先级不变，当高优先级的线程去请求共享资源时，低优先级的线程的优先级会被短暂提升，直至其释放掉共享资源

当使用实时调度策略时，signal/broadcast 操作唤醒最高优先级的线程。如果存在两个或更多线程拥有同样的优先级，会优先选择第一个阻塞在条件变量上的线程。这也是我们所期待的。

然而，条件变量可能被不做限制的优先级倒置以三种方式影响（`译注：这三种情况下使用优先级顶置或者优先级继承也没用`）。第一种明显的倒置是条件变量关联的mutex，因为mutex自身就会被不做限制的优先级倒置所影响（`译注：注意和下面第三种情况做区分，这里仅仅因为mutex解锁，T3恰巧阻塞在锁上，获得锁之后并没干啥和T2相关的事，仅仅就是T3优先级低于T2`）。

另外一种优先级倒置可以发生在线程signal/broadcast条件变量之前，再考虑figure 1中的情节，假设T1是一个低优先级（P1）的线程，T2是一个高优先级（P2）的线程（P1 < P2）。只要T1不signal/broadcast，他就就可以被中间优先级（P3）的线程T3抢占（P1 < P3 < P2）（`译者注：注意和前一种做区分，这个抢占是cpu正常调度引起的，这里T3并没有请求获取mutex，仅仅是因为P3 > P1`）。通常情况，如果选择先解锁再signal/broadcast, T1可以在解锁之后和signal/broadcast之前被抢占。最终T1不会唤醒T2，因此T3阻止了比它优先级更高的T2运行。如果先signal/broadcast，再解锁，我们可以保证T1解锁之后T2可以尽快被调度到，前提是mutex上使用优先级顶置或优先级继承协议（`译注：根据我的理解，以优先级顶置为例，T1持有mutex时，优先级会短暂提升到最高，等它释放后，T2就理所当然凭借高优先级，以及不再阻塞在条件变量上，而获取mutex`）。所以持有mutex时进行signal/broadcast稍微优于先unlock再singnal/broadcast(`译注：假设我们想要的结果是保证在T1进行signal/boadcast之后，T2可以尽快得到cpu时间片`)。值得注意的是不管怎样在这两种情形(`译注：即是否先解锁再signal/boadcast这两`)中，当T1正在修改谓词的时候优先级倒置都可能会发生（`译注：根据我的理解，这种调度结果是正常的，毕竟P3>P1，但如果有优先级置顶或者优先级继承协议的话，可以避免这种情况`）.

最后一个是，当T3阻塞在mutex上的情形。我么已经在之前分时调度的章节（`译注：解锁mutex后signal小节`）讨论过了。如果T1在唤醒T2之前解锁，T3将会获得CPU时间片。在拦截唤醒的例子中，条件被修改后本应该T2处理的却被优先级更低的T3给处理了（`译注：这个例子强调的是倒置之后本应T2等待的谓词，被T3抢走了，T2继续阻塞`）。另一个线程即将修改谓词并且最终会通知等待在条件变量上的线程例子中，我们同样再次被潜在的不受限制的优先级倒置影响。

根据之前的解释，我们相信在要想实时调度的结果可预测(`译注：不可预测其实还是蛮严重的，毕竟会导致任务错过deadline`)，signal/broadcast之后解锁mutex是必须的。这种判断应该有所节制，我从来没有经历过必须强制执行可预测性的情形。总是有可能去修改设计，所以先解锁未尝不可。事实上，David Butenhof 在最近的文章中写道，在SUS标准中的实时可预测陈述本质上是政治而不是技术[4]。但这已经被实时工作组的成员追捧起来，并且为了避免投票过程中潜在的反对也已经在SUS标准稳定下来。


## 一个陷阱 （A Trap）

存在一个案例，如果你先unlock会令你陷入问题中。你必须确保当你解锁mutex之后你所signal/broadcast的条件变量依旧引用的是一个有效的条件变量。这听起来似乎是显而易见的，但是在实践中一直确保这一点并不轻松[5]. 特别的，如果正在被唤醒的线程中销毁条件变量（亦或者条件变量所在的内存）则需要拉响警报了。

[Download cv_02.c](http://www.domaigne.com/blog/wp-content/plugins/wp-codebox/wp-codebox.php?p=33&download=cv_02.c)

上述程序运行在至少双核的机器上，在反复几千次后被SIGSEGV信号所终止。问题在56-59行。问题发生在在负责停止的线程发现nthread为0时会销毁条件变量，但是稍后在线程池中的线程会尝试signal已经不存在的条件变量。如果我们先signal然后再解锁，程序运行就不会有问题。

## 结论

我个人选择在持有mutex的情况下进行signal/boadcast.首先，我可以避免一些晦涩的bug。其次，这样做在使用wait morphing优化实现的pthread中几乎没有性能影响。再者，更重要的一点，我认为当且仅当经过分析有明显的性能提升时才会将解锁放在signal/boadcast之前。对瓶颈没有贡献的优化是没有意义的。

## 引用以及推荐阅读

- [1] David R. Butenhof: Programming with POSIX Threads, section 3.3.3, pp 82-83, Addison-Wesley, ISBN-13 978-0-201-63392-4.]
- [2] [Ulrich Drepper. Futexes Are Tricky](https://www.akkadia.org/drepper/futex.pdf). A paper about futex, the Linux kernel object behind condition variable. See in particular the Chapter 8 “Optimizing Wakeup” on page 9-10.
- [3] [Kyle & Bill Renwick. How to use priority inheritance](http://www.cs.rice.edu/~mgricken/teaching/402/09-spring/readings/PriorityInversion.html). An excellent article from embedded.com about priority inversion and possible cures.
- [4] [basic question about concurrency](https://groups.google.com/forum/#!topic/comp.programming.threads/wEUgPq541v8). A discussion thread on c.p.t, where David Butenhof explains what the “predictable scheduling” statement in the SUS standard means and where it comes from.
- [5] [A word of caution when juggling pthread_cond_signal/pthread_mutex_unlock](http://groups.google.de/group/comp.programming.threads/browse_thread/thread/23dd5883dc36d14a/7e5fcdf360543375) . A post from Bryan Ischo on c.p.t. that shows a subtle bug when unlocking before signaling.

