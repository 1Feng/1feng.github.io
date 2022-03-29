---
layout: post
title: "如何实现一个 daemon"
date: 2014-11-29
comments: true
categories:
     - linux
     - daemon
---


Linux下经常需要将服务程序实现为**daemon**（**守护进程**）。从而完成后台运行，开机启动，关机正常结束的功能。




-------------------
## 需求

- **后台运行** ：摆脱tty控制
- **根目录运行** ：切换工作目录至(/)，防止机器重启工作目录处于Unmount状态，导致进程无法正常工作
- **标准io重定向** ：重定向stdin,stdout,stderr
- **文件创建模式** ：提高创建文件权限
- **屏蔽/接管信号** ： 屏蔽或者接管部分signals处理
- **Single instance** ： 可选
- **开机启动** ：可选

## How to

### 修改文件创建模式屏蔽字
- umask(0) : 将文件创建模式屏蔽字设置为0

###  摆脱tty
- fork 并退出父进程（子进程不是session leader，为setsid创造条件）
- 调用setsid，使子进程成为session leader，同时成为一个process group leader，此时已摆脱tty
- 再次fork，并退出父进程，摆脱session leader，从而避免进程取得tty控制权限。（如果每次open /dev/tty* 的时候都使用O_NOCTTY, 则该步骤可以取消）

### 写并锁定pidfile
- 锁定pidfile，并将pid写入pidfile，如果pidfile已经存在，说明实例已经启动


###  切换目录
- cddir("/")

### 屏蔽signals
－ 屏蔽或者后续自己写代码处理相应signals(nohup 无法完成该任务)


### 重定向标准io
- 可以选择关闭或者重定向标准io到指定文件

### 开机启动
- 参考/etc/init.d/skeleton 实现启动/停止脚本, 并使用update-rc.d添加为启动项



##Code example:

``` cpp

 bool DaemonInit()
 {
    /* Our process ID and Session ID */
    pid_t pid, sid;

    /* Change the file mode mask */
    umask(0);

    /* Fork off the parent process */
    pid = fork();
    if (pid < 0)
    {
        std::cerr << "First fock failed!" << std::endl;;
        return false;
    }
    /* If we got a good PID, then
     * we can exit the parent process. */
    if (pid > 0)
    {
        sleep(1);
        exit(EXIT_SUCCESS);
    }

    /* Create a new SID for the child process */
    sid = setsid();
    if (sid < 0)
    {
        std::cerr << "Setsid failed!" << std::endl;;
        return false;
    }

    /* Fork off the second time */
    pid = fork();
    if (pid < 0)
    {
        std::cerr << "Second fork failed!" << std::endl;;
        return false;
    }
    /* If we got a good PID, then
     * we can exit the parent process. */
    if (pid > 0)
    {
        exit(EXIT_SUCCESS);
    }

    /* Ignore signals */
    signal(SIGCHLD, SIG_IGN);
    signal(SIGHUP, SIG_IGN);

	 /* Change the current working directory */
    if ((chdir("/")) < 0) {
      return false;
    }

    //需保证 pid_fd 生命周期与进程生命周期一致
    int pid_fd = open("/var/run/daemon_example.pid", O_RDWR|O_CREAT, 0640);
    if ( pid_fd < 0)
    {
        //std::cerr << "Can not open " << pidfile_ << std::endl;
        return false;
    }
    if (lockf(fd_, F_TLOCK, 0) < 0)
    {
        //std::cerr << "Another instance is running!" << std::endl;;
        return false;
    }
    /*write and lock pid file*/
    std::stringstream stream;
    stream << getpid() << '\n';
    std::string pidstr = stream.str();
    ssize_t len = write(fd_, pidstr.c_str(), pidstr.length());
    if(len < 0)
    {
        //std::cerr << "Write to /var/run/daemon_example.pid failed!"
        //          << std::endl;;
        return false;
    }

    /* Close out the standard file descriptors */
    if(close(STDIN_FILENO) == -1)
    {
        //std::cerr << "Can not close STDIN_FILENO!" << std::endl;
        return false;
    }
    if(close(STDOUT_FILENO) == -1)
    {
        //std::cerr << "Can not close STDOUT_FILENO!" << std::endl;
        return false;
    }
    if(close(STDERR_FILENO)  == -1)
    {
        //std::cerr << "Can not close STDERR_FILENO!" << std::endl;
        return false;
    }
    /*redirect standard output*/
    //需保证 output_fd 生命周期与进程生命周期一致
    int output_fd = open(DEV_NULL, O_RDWR, 0);
    if(output_fd == -1)
    {
      return false;
    }
    if(dup2(output_fd, STDIN_FILENO) == -1)
    {
      return false;
    }
    if(dup2(output_fd, STDOUT_FILENO) == -1)
    {
      return false;
    }
    if(dup2(output_fd, STDERR_FILENO) == -1)
    {
      return false;
    }
    return true;
}
```


## 参考
1. [《APUE》 Chapter 13](http://www.apuebook.com/)
2. [Daemon how to](http://netzmafia.de/skripten/unix/linux-daemon-howto.html)
3. [Creating a daemon in Linux](https://stackoverflow.com/questions/17954432/creting-a-daemon-in-linux)
4. [What's the difference between nohup and a daemon?](https://stackoverflow.com/questions/958249/whats-the-difference-between-nohup-and-a-daemon)

