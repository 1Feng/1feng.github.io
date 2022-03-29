---
layout: post
title: "函数对象与std::bind"
date: 2014-04-27
comments: true
categories: 
    - cpp
    - std::bind
---

-------------------

### 函数指针

主要有以下两类：

1. 一般函数指针（普通函数指针 and static 成员函数指针）
2. 非static成员函数指针

#### 一般函数指针
##### 初始化
普通函数指针
> func_type func = function_name; 

or
>func_type func = &function_name;

static 成员函数指针
>func_type func = ClassName::function_name;

or
> func_type func = &ClassName::function_name;

##### 调用
>function_name(arg);

or
>(*function_name)(arg);

*注：同数组名类似，对函数名而言 functin_name 和 &function_name 是一样的，即地址相同，所以，上述的两种写法都可以*

#### 对于类的非static成员函数指针
##### 初始化
>func_type func = &function_name;

##### 调用
>(obj.*func)(arg);

即，非static成员函数在初始化时，必须以&的方式避免歧义，否则编译会报错为 `invalid use of non-static member function`


-------------------

### 函数对象
C++推荐使用函数对象（仿函数）来替代函数指针，这样可以避免指针操作带来的繁琐，切可以维护数据，使函数带有自己的状态
函数对象主要通过重载operator()来实现，例如：
``` cpp
struct Max
 {
   Max() : times()
   {
   }
   int operator()(int a, int b)
   {
     std::cout << "Called " << ++times << " times match" << std::endl;
     return a > b ? a : b;
   }
   int times;
 };
```

同时我们可以声明一个函数对象

```cpp
Max max;
std::function<int(int, int)> func = max;  //拷贝
max(1,3);
func(1, 3); 
func = std::ref(max); //引用该对象
func(1, 3);
```
output:
```
Called 1 times match
Called 1 times match
Called 2 times match
```
 
 -------------------
 
### std::bind

>用于绑定函数参数，返回函数对象
 
#### 使用示例：

``` cpp
 class Test
 {
 public:
   void print()
   {
     std::cout << ++value << std::endl;
   }
   void addX(int x);
   {
     value += x;
     std::cout << value << std::endl;
   }
 private:
   int value;
 }
 
 Test test;
 std::function<void()> func = std::bind(&Test::print, test);  //test 传值
 test.print();  //  value is 1
 func();        //  value is 1
 func = std::bind(&Test::print, &test);    //传引用
 func();        //  value is 2
 test.print();  //  value is 3
 func = std::bind(&Test::addX, &test, 5);  //多参数绑定
 func();        //  value is 8
 test.print();  //  value is 9
 std::function<void(int)> func1;
 func1 = std::bind(&Test::addX, &test, std::placeholders::_1);  //参数占位
 func1(4);      //  value is 13
 test.print();  //  value is 14
```
#### 原理描述

bind普通函数

![](/images/blog_images/bind_1.png)

bind成员函数，如果绑定的是`*this`， 则内部调用时为`(v1.*fn)()`

![](/images/blog_images/bind_2.png)

显式传递`this`

![](/images/blog_images/bind_3.png)

占位预留参数

![](/images/blog_images/bind_4.png)


-------------------
### 相关参考&援引
1. [函数指针](http://www.cprogramming.com/tutorial/function-pointers.html)
2. [函数对象](http://www.cprogramming.com/tutorial/functors-function-objects-in-c++.html)
3. ["&" in ordinary functions pointer](http://stackoverflow.com/questions/6893285/why-do-all-these-crazy-function-pointer-definitions-all-work-what-is-really-goi)
4. [《bind illustrated》 --- Christopher M. Kohlhoff ](http://blog.think-async.com/2010/04/bind-illustrated.html)


