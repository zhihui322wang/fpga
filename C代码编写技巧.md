# C 代码编写技巧

> 项目: RISC-V WebSoC | 日期: 2026-08-05

---

## 目录

| 第一部分：.h 头文件的编写 | 第二部分：.c 源文件的编写 |
|--------------------------|--------------------------|
| [1.1 整体构成 + 完整示例](#h-top) | [2.1 整体构成 + 完整示例](#c-top) |
| [1.2 宏定义 `#define`](#h-macro) | [2.2 `#include` 包含头文件](#c-include) |
| [1.3 `typedef` 类型别名](#h-typedef) | [2.3 全局变量定义](#c-var-def) |
| [1.4 `struct` 结构体](#h-struct) | [2.4 函数定义（实现）](#c-func-def) |
| [1.5 `extern` 全局变量声明](#h-extern) | [2.5 `static` 文件内私有](#c-static) |
| [1.6 函数声明](#h-func-decl) | [2.6 `main()` 程序入口](#c-main) |
| [1.7 核心概念对比](#h-compare) | [2.7 .h 与 .c 联动总结](#c-compare) |
| [1.8 Include Guard](#h-guard) | |
| [附录：C 数据类型速查](#appendix) | |

---

## 第一部分：.h 头文件的编写

---

<a id="h-top"></a>

### 1.1 整体构成：完整示例 + 拆解表

`.h` 文件包含 6 种内容。下面是完整示例（点击注释中的蓝色链接跳转到详解）：

<pre style="background:#1e1e1e;color:#e0e0e0;padding:16px 20px;border-radius:8px;overflow-x:auto;font-size:14px;line-height:1.8;font-family:'Consolas','Monaco','Courier New',monospace;">
<code style="background:transparent;color:inherit;font-size:inherit;padding:0;"><span style="color:#6a9955;">// my_module.h — .h 头文件完整示例 (点击蓝色链接跳转详解)</span>

<a href="#h-guard" style="color:#4fc1ff;font-weight:bold;">① Include Guard</a> — <span style="color:#6a9955;">防重复包含</span>
<span style="color:#c586c0;">#ifndef</span> _MY_MODULE_H_
<span style="color:#c586c0;">#define</span> _MY_MODULE_H_

<span style="color:#6a9955;">// 包含其他头文件</span>
<span style="color:#c586c0;">#include</span> <span style="color:#ce9178;">&lt;stdint.h&gt;</span>

<a href="#h-macro" style="color:#4fc1ff;font-weight:bold;">② 宏定义</a> — <span style="color:#6a9955;">预处理文本替换</span>
<span style="color:#c586c0;">#define</span> MAX_BUFFER_SIZE 1024
<span style="color:#c586c0;">#define</span> PI 3.14159

<a href="#h-typedef" style="color:#4fc1ff;font-weight:bold;">③ typedef 类型别名</a> — <span style="color:#6a9955;">给类型起短名</span>
<span style="color:#569cd6;">typedef</span> <span style="color:#4ec9b0;">unsigned</span> <span style="color:#4ec9b0;">int</span> uint32;

<a href="#h-struct" style="color:#4fc1ff;font-weight:bold;">④ 结构体</a> — <span style="color:#6a9955;">自定义复合类型</span>
<span style="color:#569cd6;">typedef</span> <span style="color:#569cd6;">struct</span> {
    <span style="color:#4ec9b0;">int</span> x;
    <span style="color:#4ec9b0;">int</span> y;
} Point;

<a href="#h-extern" style="color:#4fc1ff;font-weight:bold;">⑤ extern 全局变量声明</a> — <span style="color:#6a9955;">只声明不定义</span>
<span style="color:#569cd6;">extern</span> <span style="color:#4ec9b0;">int</span> g_system_status;

<a href="#h-func-decl" style="color:#4fc1ff;font-weight:bold;">⑥ 函数声明</a> — <span style="color:#6a9955;">只写函数头，不写实现</span>
<span style="color:#4ec9b0;">int</span> add(<span style="color:#4ec9b0;">int</span> a, <span style="color:#4ec9b0;">int</span> b);
<span style="color:#4ec9b0;">void</span> print_point(Point p);

<a href="#h-guard" style="color:#4fc1ff;font-weight:bold;">① Include Guard 结束</a>
<span style="color:#c586c0;">#endif</span> <span style="color:#6a9955;">// _MY_MODULE_H_</span></code></pre>

下面逐项拆解：

| # | 内容类别 | 关键字 | 作用 | 写在 .h 还是 .c？ | 项目实例 | 跳转 |
|---|---------|--------|------|-------------------|----------|------|
| 1 | **Include Guard** | `#ifndef` | 防重复包含 | .h (头尾) | `#ifndef _LCPU_GEN_H_` | [→ 1.8](#h-guard) |
| 2 | **宏定义** | `#define` | 预处理文本替换 | .h | `#define ETH_TYPE_IP 0x0800` | [→ 1.2](#h-macro) |
| 3 | **类型别名** | `typedef` | 给类型起短名 | .h | `typedef unsigned int uint32;` | [→ 1.3](#h-typedef) |
| 4 | **结构体** | `struct` | 自定义复合类型 | .h | `typedef struct {...} tcp_conn_t;` | [→ 1.4](#h-struct) |
| 5 | **全局变量声明** | `extern` | 跨文件共享，只声明不定义 | .h | `extern uint32 src_ip;` | [→ 1.5](#h-extern) |
| 6 | **函数声明** | 函数签名 | 告知编译器函数接口 | .h | `uint16_t tcp_proc(void);` | [→ 1.6](#h-func-decl) |

---

<a id="h-macro"></a>

### 1.2 宏定义

#### 写法 1：简单常量

```c
#define PI          3.14159     // 数字常量
#define MAX_SIZE    1024        // 整数常量
#define LOCAL_IP    0xA9FE0101  // 十六进制常量
```

#### 写法 2：带参数的宏函数

```c
#define MAX(a, b)  ((a) > (b) ? (a) : (b))   // 取最大值
#define ABS(x)     ((x) < 0 ? -(x) : (x))    // 取绝对值
```

> ⚠️ 每个参数和整体都要加括号，否则展开后优先级可能出错。

#### 写法 3：条件编译

```c
#define SIM_FAST   // 定义标记

#ifdef SIM_FAST
    // 仿真模式
#else
    // 上板模式
#endif
```

#### 项目实例 (lcpu_general.h)

```c
#define FIFO_BASE       0x80000000
#define ETH_TYPE_IP     0x0800
#define IP_PROTOCOL_TCP 0x06
#define TCP_FLAG_SYN    0x02
```

[← 返回拆解表](#h-top)

---

<a id="h-typedef"></a>

### 1.3 typedef：类型别名

#### 写法 1：基本类型别名（最常用）

```c
typedef unsigned char  uint8;    // 1 字节
typedef unsigned short uint16;   // 2 字节
typedef unsigned int   uint32;   // 4 字节
```

#### 写法 2：结构体别名

```c
typedef struct {
    uint32_t remote_ip;
    uint16_t remote_port;
    uint8_t  state;
} tcp_conn_t;   // 直接用 tcp_conn_t，不用写 struct
```

#### 写法 3：函数指针别名

```c
typedef void (*callback_t)(int arg);  // callback_t 是函数指针类型
```

#### 项目实例 (lcpu_general.h)

```c
typedef unsigned char   uint8;
typedef unsigned short  uint16;
typedef unsigned int    uint32;
```

[← 返回拆解表](#h-top)

---

<a id="h-struct"></a>

### 1.4 结构体

#### struct 的三种写法

| 写法 | 代码 | 声明变量时 | 适用场景 |
|------|------|-----------|----------|
| **基础写法** | `struct Point { int x; int y; };` | `struct Point p;` (必须带 struct) | C 标准传统 |
| **typedef 写法** | `typedef struct { int x; int y; } Point;` | `Point p;` (简洁) | **最常用** |
| **带标签 typedef** | `typedef struct Node { int d; struct Node* n; } Node;` | `Node n;` | 链表自引用 |

#### 项目实例：寄存器映射

```c
// lcpu_general.h — 用结构体映射硬件寄存器地址
typedef struct {
    uint32 _pad[16];   // 前 16 个字是其他寄存器
    uint32 led;        // 偏移 0x40 是 LED 寄存器
} str_my_reg;

#define LCPU_BASE  0x80000000
((volatile str_my_reg*)LCPU_BASE)->led = 0x0F;  // 通过指针访问硬件
```

[← 返回拆解表](#h-top)

---

<a id="h-extern"></a>

### 1.5 extern：全局变量声明

#### 规则

```
.h 文件中:  extern int g_count;     ← 声明（不分配内存，可多次出现）
.c 文件中:  int g_count = 10;      ← 定义（分配内存，仅一次）  ← 见第二部分2.3
```

#### 图解

```
lcpu_general.h              ip.c                    main.c
┌─────────────────┐    ┌──────────────┐    ┌──────────────┐
│ extern int x;    │←───│ int x = 10;   │    │ #include "h"  │
│ (声明，不占内存)  │    │ (定义，占 4B)  │    │ x = 20; // OK  │
└─────────────────┘    └──────────────┘    └──────────────┘
      ↑ 任何 #include 的 .c 都能用 x
```

#### 项目实例

```c
// lcpu_general.h — 声明
extern uint32 src_ip;
extern uint16 src_port;

// ip.c — 定义（见第二部分2.3）
uint32 src_ip;
uint16 src_port;
```

[← 返回拆解表](#h-top)

---

<a id="h-func-decl"></a>

### 1.6 函数声明

#### 只写函数头，末尾有分号

```c
// tcp.h
void     tcp_init(void);                         // 无参数，无返回值
uint16_t tcp_proc(void);                          // 无参数，返回 uint16_t
void     tcp_send_syn_ack(int slot);              // 有参数，无返回值
```

#### 对比：声明 vs 定义

| | 函数声明 (在 .h) | 函数定义 (在 .c，见第二部分2.4) |
|---|------|------|
| **写法** | `int add(int a, int b);` ← 有分号 | `int add(int a, int b) { ... }` ← 有大括号 |
| **可省略参数名** | ✅ `int add(int, int);` | ❌ 必须写参数名 |
| **作用** | 告诉编译器"这个函数存在" | 生成机器码 |

[← 返回拆解表](#h-top)

---

<a id="h-compare"></a>

### 1.7 核心概念对比

#### 声明 vs 定义

| | 声明 | 定义 |
|---|------|------|
| **分配内存** | ❌ | ✅ |
| **出现次数** | 多次 | 仅一次 |
| **变量** | `extern int x;` | `int x = 10;` |
| **函数** | `int add(int,int);` | `int add(int a,int b){...}` |

#### `#define` vs `const`

| | `#define` | `const` |
|---|-----------|---------|
| **阶段** | 预处理文本替换 | 编译期 |
| **类型检查** | ❌ | ✅ |
| **占内存** | ❌ | ✅ |
| **带参数** | ✅ 宏函数 | ❌ |

[← 返回拆解表](#h-top)

---

<a id="h-guard"></a>

### 1.8 Include Guard

#### 问题

```
A.h → include "point.h" ─┐
                          ├→ main.c 里 struct Point 出现两次 → 编译报错！
B.h → include "point.h" ─┘
```

#### 方式一：`#ifndef` / `#define` / `#endif`（本项目使用）

```c
#ifndef _MY_MODULE_H_
#define _MY_MODULE_H_

// ... 头文件全部内容 ...

#endif // _MY_MODULE_H_
```

#### 方式二：`#pragma once`（更简洁）

```c
#pragma once
// ... 头文件全部内容 ...
```

#### 项目命名规范

| 头文件 | Guard 宏 |
|--------|----------|
| `tcp.h` | `_TCP_H_` |
| `ip.h` | `_IP_H_` |
| `eth.h` | `_ETH_H_` |
| `lcpu_general.h` | `_LCPU_GEN_H_` |

[← 返回拆解表](#h-top)

---

## 第二部分：.c 源文件的编写

---

<a id="c-top"></a>

### 2.1 整体构成：完整示例 + 拆解表

`.c` 文件包含 5 种内容。下面是完整示例（点击注释中的蓝色链接跳转到详解）：

<pre style="background:#1e1e1e;color:#e0e0e0;padding:16px 20px;border-radius:8px;overflow-x:auto;font-size:14px;line-height:1.8;font-family:'Consolas','Monaco','Courier New',monospace;">
<code style="background:transparent;color:inherit;font-size:inherit;padding:0;"><span style="color:#6a9955;">// my_module.c — .c 源文件完整示例 (点击蓝色链接跳转详解)</span>

<a href="#c-include" style="color:#4fc1ff;font-weight:bold;">① #include 包含头文件</a>
<span style="color:#c586c0;">#include</span> <span style="color:#ce9178;">"my_module.h"</span>    <span style="color:#6a9955;">// 自己的头文件</span>
<span style="color:#c586c0;">#include</span> <span style="color:#ce9178;">"inc/lcpu_general.h"</span>  <span style="color:#6a9955;">// 项目公共头文件</span>
<span style="color:#c586c0;">#include</span> <span style="color:#ce9178;">&lt;stdint.h&gt;</span>           <span style="color:#6a9955;">// 系统头文件</span>

<a href="#c-var-def" style="color:#4fc1ff;font-weight:bold;">② 全局变量定义 (分配内存)</a>
<span style="color:#4ec9b0;">int</span> g_system_status = <span style="color:#b5cea8;">0</span>;              <span style="color:#6a9955;">// 对应 .h 中 extern int g_system_status;</span>
<span style="color:#569cd6;">static</span> <span style="color:#4ec9b0;">int</span> s_internal_counter = <span style="color:#b5cea8;">0</span>;  <span style="color:#6a9955;">// static → 仅本文件可见</span>

<a href="#c-func-def" style="color:#4fc1ff;font-weight:bold;">③ 函数定义 (具体实现)</a>
<span style="color:#4ec9b0;">int</span> <span style="color:#dcdcaa;">add</span>(<span style="color:#4ec9b0;">int</span> a, <span style="color:#4ec9b0;">int</span> b) {
    <span style="color:#c586c0;">return</span> a + b;                    <span style="color:#6a9955;">// 实现 .h 中声明的函数</span>
}

<a href="#c-static" style="color:#4fc1ff;font-weight:bold;">④ static 函数 (文件内私有)</a>
<span style="color:#569cd6;">static</span> <span style="color:#4ec9b0;">void</span> <span style="color:#dcdcaa;">internal_helper</span>(<span style="color:#4ec9b0;">void</span>) {
    s_internal_counter++;             <span style="color:#6a9955;">// 仅在 .c 内部调用, .h 中不声明</span>
}

<a href="#c-main" style="color:#4fc1ff;font-weight:bold;">⑤ main() 入口函数</a>
<span style="color:#4ec9b0;">int</span> <span style="color:#dcdcaa;">main</span>(<span style="color:#4ec9b0;">void</span>) {
    <span style="color:#dcdcaa;">add</span>(<span style="color:#b5cea8;">3</span>, <span style="color:#b5cea8;">5</span>);                       <span style="color:#6a9955;">// 调用自己实现的函数</span>
    <span style="color:#c586c0;">return</span> <span style="color:#b5cea8;">0</span>;
}</code></pre>

下面逐项拆解：

| # | 内容类别 | 关键字 | 作用 | 写在 .h 还是 .c？ | 项目实例 | 跳转 |
|---|---------|--------|------|-------------------|----------|------|
| 1 | **#include** | `#include` | 引入头文件，获取声明 | .c (顶部) | `#include "inc/tcp.h"` | [→ 2.2](#c-include) |
| 2 | **全局变量定义** | 无/extern 的反面 | 实际分配内存空间 | .c | `uint32 src_ip;` | [→ 2.3](#c-var-def) |
| 3 | **函数定义** | 函数体 `{...}` | 实现 .h 中声明的函数 | .c | `void tcp_init(void){...}` | [→ 2.4](#c-func-def) |
| 4 | **static** | `static` | 限制变量/函数仅本文件可见 | .c | `static int counter;` | [→ 2.5](#c-static) |
| 5 | **main()** | `main` | 程序入口 | .c | `int main(void){...}` | [→ 2.6](#c-main) |

> **一句话**：`.c` = `#include`声明 + 定义变量(分配内存) + 实现函数(写逻辑)。

---

<a id="c-include"></a>

### 2.2 #include：包含头文件

#### 两种写法

| 写法 | 搜索路径 | 用于 |
|------|----------|------|
| `#include <stdint.h>` | 系统目录 | 标准库头文件 |
| `#include "my_module.h"` | 当前目录 → 系统目录 | 自己的头文件 |

#### 项目实例

```c
// main.c
#include "inc/lcpu_general.h"   // 公共定义 (寄存器、协议常量、类型)
#include "inc/system.h"         // 系统函数声明
#include "inc/eth.h"            // 以太网层
#include "inc/arp.h"            // ARP 层
#include "inc/ip.h"             // IP 层
#include "inc/icmp.h"           // ICMP 层
#include "inc/tcp.h"            // TCP 层
```

> **原则**：你需要用到哪个模块的函数/变量/宏，就 include 哪个模块的 `.h`。

[← 返回拆解表](#c-top)

---

<a id="c-var-def"></a>

### 2.3 全局变量定义

#### .h 声明 → .c 定义 对照

```
┌────────────────────────────────────────────────────────────┐
│ .h 文件                         .c 文件                     │
│                                                             │
│ extern int g_count;      ←→     int g_count = 0;           │
│ (声明：不占内存)                 (定义：占 4 字节)            │
│                                                             │
│ extern uint32 src_ip;    ←→     uint32 src_ip;             │
│ (声明)                           (定义：未初始化 = 0)        │
└────────────────────────────────────────────────────────────┘
```

#### 项目实例

```c
// lcpu_general.h — 声明 (不分配内存)
extern uint32 src_ip;
extern uint16 src_port;
extern uint16 ip_total_len;

// ip.c — 定义 (分配内存)
uint32 src_ip;           // 初始值自动为 0 (在 .bss 段)
uint16 ip_total_len;     // 初始值自动为 0
// src_port 未在此定义 → 在别的 .c 中定义
```

[← 返回拆解表](#c-top)

---

<a id="c-func-def"></a>

### 2.4 函数定义（实现）

#### 结构

```c
返回值类型  函数名(参数列表) {
    // 函数体：具体的业务逻辑
    return 值;  // 如果返回值类型不是 void
}
```

#### 示例：arp.c 中的函数定义

```c
#include "inc/lcpu_general.h"

void arp_reply() {                    // 无返回值，无参数
    uint16 arp_start = eth_header_len;
    // ... 构建 ARP 回复包的业务逻辑 ...
    LCPU_WR_PUSH_PACKET(tx_pkt_len);
}
```

#### 示例：ip.c 中的函数定义

```c
uint16 ip_proc() {                    // 返回 uint16
    uint8 ver_ihl = LCPU_RD_DATA8();
    if ((ver_ihl & 0xF0) != 0x40)     // 校验失败
        return NO_PROC;               // 提前返回
    // ... 正常处理 ...
    return ICMP_PROC;                 // 返回处理结果
}
```

#### 示例：ip.c 中带多个参数的函数

```c
uint16 ip_header_checksum(uint16 total_len, uint16 checksum_ini) {
    uint16 ip_checksum = checksum_ini;   // 使用传入的参数
    // ... 逐字节计算校验和 ...
    return ~ip_checksum;                 // 返回计算结果
}
```

[← 返回拆解表](#c-top)

---

<a id="c-static"></a>

### 2.5 static 的两种用法

#### 用法 1：static 全局变量（文件内私有）

```c
// my_module.c
static int s_counter = 0;     // 只有 my_module.c 里的函数能访问
                               // 其他 .c 文件看不到这个变量

void increment(void) {
    s_counter++;               // OK：本文件内访问
}
```

**对比普通全局变量**：

| | 普通全局变量 | static 全局变量 |
|---|-------------|----------------|
| **声明** | `int g_count;` | `static int s_count;` |
| **可见范围** | 所有 .c 文件 (通过 extern) | 仅本 .c 文件 |
| **.h 中声明** | `extern int g_count;` | 不需要（外部不可见） |
| **命名习惯** | `g_` 前缀 | `s_` 前缀 |

#### 用法 2：static 函数（文件内私有）

```c
// my_module.c
static void internal_helper(void) {  // 仅本文件可见
    // ... 内部辅助逻辑 ...
}

void public_api(void) {              // 在 .h 中声明，外部可用
    internal_helper();               // 内部调用 static 函数
}
```

> **为什么用 static？** 把不需要暴露给外部的函数/变量限制在文件内，避免命名冲突，让接口更清晰。

#### 项目实例

```c
// main.c — 假设有个内部辅助函数不希望外部调用
static void delay_cycles(uint32 count) {
    while (count--) { asm volatile("nop"); }
}

// program_main() 调用它，但其他 .c 文件看不到 delay_cycles
```

[← 返回拆解表](#c-top)

---

<a id="c-main"></a>

### 2.6 main()：程序入口

#### 标准写法

```c
int main(void) {
    // 初始化...
    // 主循环...
    return 0;
}
```

#### 嵌入式/裸机写法（RISC-V 软核）

```c
// 1. 启动入口：设置栈指针、清零 BSS，然后跳转主程序
__attribute__((naked, used, section(".text.bootloader")))
void reset_entry() {
    asm volatile(
        "la sp, _stack_top\n"       // 设栈顶
        "la t0, __bss_start\n"      // BSS 清零
        "la t1, __bss_end\n"
        "1:\n"
        "bgeu t0, t1, 2f\n"
        "sw zero, 0(t0)\n"
        "addi t0, t0, 4\n"
        "j 1b\n"
        "2:\n"
        "j program_main\n"          // 跳转到主程序
    );
}

// 2. 主程序：无限循环处理
void program_main(void) {
    // 初始化
    LCPU_SET_LED(0x0F);

    while (1) {
        // LED 心跳
        // 检查 RX FIFO
        if (LCPU_RD_EMPTY()) continue;

        // 读包 → 解析 → 分发 → 回复
        LCPU_RD_START_PACKET();
        uint32 len = LCPU_RD_PKT_LEN();

        uint16 ptype = eth_proc();     // 以太网层
        if (ptype == ARP_PROC) {
            arp_reply();               // ARP 层
        } else if (ptype == IP_PROC) {
            uint16 iptype = ip_proc(); // IP 层
            if (iptype == ICMP_PROC) {
                icmp_reply();          // ICMP 层
            } else if (iptype == TCP_PROC) {
                tcp_proc();            // TCP 层（待实现）
            }
        }
    }
}

// 3. main() 只是入口
int main() {
    program_main();
    return 0;
}
```

#### 三个层级的关系

```
上电
  ↓
reset_entry()     ← 硬件复位向量，汇编级初始化 (栈/BSS)
  ↓
main()            ← C 标准入口
  ↓
program_main()    ← 实际业务主循环 (while(1) 永不退出)
```

[← 返回拆解表](#c-top)

---

<a id="c-compare"></a>

### 2.7 .h 与 .c 联动总结

| | .h 头文件 | .c 源文件 |
|---|----------|----------|
| **类比** | 产品说明书 | 产品本身 |
| **内容** | 宏、typedef、struct、extern、函数声明 | #include、变量定义、函数实现 |
| **编译** | 不单独编译 | 编译为 .o 目标文件 |
| **分配内存** | 不分配 | 分配 |
| **可以被多个文件包含** | ✅ | ❌ (会产生重复定义) |

```
tcp.h                           tcp.c
┌──────────────────────┐       ┌─────────────────────────┐
│ #ifndef _TCP_H_       │       │ #include "tcp.h"         │  ← 引入声明
│ #define _TCP_H_       │       │ #include "lcpu_general.h"│
│                       │       │                          │
│ // 宏                 │       │ // 定义全局变量           │
│ #define MAX_CONN 4    │       │ static tcp_conn_t conns[4];│
│                       │       │                          │
│ // 结构体             │       │ // 实现函数               │
│ typedef struct {...}  │       │ void tcp_init(void) {    │
│       tcp_conn_t;     │       │   // 清零连接表...        │
│                       │       │ }                        │
│ // 函数声明           │       │                          │
│ void tcp_init(void);  │───→   │ uint16_t tcp_proc(void) {│
│ uint16_t tcp_proc();  │ 实现  │   // 解析 + 状态机...     │
│                       │       │ }                        │
│ #endif                │       │                          │
└──────────────────────┘       └─────────────────────────┘
```

[← 返回拆解表](#c-top)

---

<a id="appendix"></a>

## 附录：C 数据类型速查

### 基本类型

| 关键字 | 占用 | 取值范围 | 格式占位符 | 项目中的用途 |
|--------|------|----------|-----------|-------------|
| `char` | 1B | -128 ~ 127 | `%c` / `%d` | 单字符 |
| `unsigned char` / `uint8` | 1B | 0 ~ 255 | `%u` | 状态值、标志位、字节数据 |
| `short` | 2B | -32768 ~ 32767 | `%hd` | 小整数 |
| `unsigned short` / `uint16` | 2B | 0 ~ 65535 | `%hu` | 端口号、包长度 |
| `int` | 4B | -21亿 ~ 21亿 | `%d` | 普通整数 |
| `unsigned int` / `uint32` | 4B | 0 ~ 42亿 | `%u` | IP 地址、SEQ/ACK 序号、计数器 |
| `long long` | 8B | ±9×10¹⁸ | `%lld` | 大整数 |
| `float` | 4B | 6-7 位精度 | `%f` | 低精度小数 |
| `double` | 8B | 15-17 位精度 | `%lf` | 高精度小数（首选） |

### 项目中的类型选择

| 数据 | 选型 | 原因 |
|------|------|------|
| IP 地址 | `uint32` | 恰好 4 字节 |
| MAC 地址 | `uint32` + `uint16` | 6 字节拆为 4+2 |
| 端口号 | `uint16` | 0~65535 |
| TCP SEQ/ACK | `uint32` | 32 位序号 |
| 包长度 | `uint16` | 最大 65535 |
| 连接状态 | `uint8` | 几个状态值 |
| Flags | `uint8` | 6 个 bit |
| 超时计数 | `uint32` | rdcycle 值 |

### char 的特殊性

```c
char c = 'A';        // 'A' 的 ASCII 码值是 65
printf("%c\n", c);   // 输出: A    (按字符打印)
printf("%d\n", c);   // 输出: 65   (按数字打印)
char next = c + 1;   // 65 + 1 = 66 → 'B'
```

---

> 更新日期: 2026-08-05 | 项目: RISC-V WebSoC
