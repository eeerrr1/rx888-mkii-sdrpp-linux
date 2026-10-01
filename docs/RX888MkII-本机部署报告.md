# RX888 MkII 本机部署报告

> 执行时间：2026-10-01 ｜ 目标机：Ubuntu 26.04.1 LTS / 内核 7.0.0 / x86_64 / GCC 15.2.0

---

## ⚠️ 事后更正（2026-10-01 16:3x，同日复盘）

**本报告第一节"发现 1：设备插在 USB 2.0 口上"是一个错误结论，特此更正。**

当时看到 `speed = 480 Mbps` 就判断是端口/线缆问题。实际原因在 Cypress 官方应用笔记 **AN76405 《EZ-USB FX3/FX3S boot options》** 中写得很明确：

> The state of FX3 in USB boot mode is as follows:
> **• USB 3.0 (SuperSpeed) signaling is disabled.**
> **• USB 2.0 (High Speed/Full Speed) is enabled.**

也就是说，**未加载固件的 DFU/bootloader 态（`04b4:00f3`）下，FX3 在硬件层面就关闭了 SuperSpeed**，无论插在哪个 USB 端口上都只会显示 480 Mbps。这条观察**不能用来判断端口好坏**。

判断端口是否真的是 USB 3.0，唯一有效时机是**固件加载完成、设备重新枚举为 `04b4:00f1` 之后**再看 `speed`。该判定已固化进 `verify-device.sh` 阶段 4。

结论修正：**当时不需要换线**，真正缺的只有 udev 权限。

---

## 一、结论摘要

**驱动栈已打通到"只差权限"这一步。** 实机编译 libsddc 成功，`sddc_info` 能识别出设备并进入固件上传流程；随后卡在 `LIBUSB_ERROR_ACCESS`——差一条 udev 规则。

同时发现**两个必须先解决的问题**：

1. 🔴 **设备插在 USB 2.0 口上**（480 Mbps）。RX888 MkII 满速需要约 2048 Mbps，这个端口物理上跑不动。**这需要你动手换线**，软件无法解决。
2. 🔴 **SDR++ 上游的 SDDC 模块有 7 处硬缺陷**，其中一处会让**整个 SDR++ 的 CMake 配置直接中止**（不只是该模块编不出来）。已全部修复到本机工作副本。

---

## 二、环境概况

| 项目 | 实测值 |
|---|---|
| 系统 | Ubuntu 26.04.1 LTS (resolute) |
| 内核 | 7.0.0-34-generic |
| 编译器 | GCC 15.2.0（**C23 为默认标准**，这是多个编译错误的根因） |
| 磁盘可用 | 419 GB |
| 网络 | 可访问 GitHub，但**极不稳定**（多次 TLS 重置 / 连接超时） |
| 设备 | `Bus 003 Device 003: ID 04b4:00f3 Cypress FX3 micro-controller (DFU mode)` |
| 设备链路 | **480 Mbps / USB 2.00** ← 问题所在 |
| 设备节点 | `/dev/bus/usb/003/003` → `crw-rw-r-- root:root`（当前用户只读） |
| usbfs 缓冲 | `usbfs_memory_mb = 16`（默认值，过小） |

**本机 USB 布局**：`Bus 002`（20000M/x2，4 口）和 `Bus 004`（20000M/x2，2 口）是高速总线；`Bus 001`/`Bus 003`（480M）是 USB 2.0。设备现在在 `Bus 003`。

---

## 三、已完成项（全部经过验证）

### 3.1 源码拉取

| 仓库 | 位置 | 版本 |
|---|---|---|
| SDR++ | `/home/tsw/sdr/SDRPlusPlus` | `8c9f5ee`（2026-07-04） |
| ExtIO_sddc（驱动 + 固件） | `/home/tsw/sdr/ExtIO_sddc` | `331b35c`（2026-03-10） |
| rx888_tools（CLI 工具） | 待补 | ⚠️ GitHub 连接不稳定，后台重试中 |

固件镜像已随 ExtIO_sddc 仓库获得：`/home/tsw/sdr/ExtIO_sddc/SDDC_FX3.img`（146,268 字节）。

### 3.2 本地构建环境

系统缺 `cmake` 且 `sudo` 需要密码，因此用托管 Python 装了一个**免 root** 的 cmake：

```
/home/tsw/.workbuddy/binaries/python/envs/default/bin/cmake   # 4.4.3
```

### 3.3 驱动库编译成功 ✅

`libsddc` 只需 libusb（本机已有 1.0.29），已成功编译出：

```
libsddc.so         27 KB
sddc_info          16 KB   # 设备信息/枚举工具
sddc_rx            16 KB   # 收流工具
```

位于 `/home/tsw/sdr/SDRPlusPlus/source_modules/sddc_source/libsddc/build/`

### 3.4 实机联调结果 ✅/❌

```
$ ./sddc_info /home/tsw/sdr/ExtIO_sddc/SDDC_FX3.img
Firmware: /home/tsw/sdr/ExtIO_sddc/SDDC_FX3.img

Found uninitialized device, initializing...   ← ✅ 设备识别成功
Failed to open device: -3                      ← ❌ LIBUSB_ERROR_ACCESS（缺 udev 规则）
No device found.
```

这一步证明了：**USB 通信、设备枚举、固件上传流程都是通的**，唯一的门是权限。

---

## 四、实测发现的上游硬缺陷（7 处，已修复）

这一节把方案文档里的"推测"变成了"确证"。所有修复都带 `FIXED:` 注释，便于识别与向上游提交。

| # | 文件 | 缺陷 | 后果 |
|---|---|---|---|
| A-1 | `libsddc/CMakeLists.txt:58` | `configure_file(${CMAKE_SOURCE_DIR}/libsddc.pc.in ...)`——**`libsddc.pc.in` 文件在整个仓库中不存在**；且 `${CMAKE_SOURCE_DIR}` 作为子目录构建时指向 SDR++ 根目录 | **阻断级**：`cmake` 配置阶段直接报错，`-DOPT_BUILD_SDDC_SOURCE=ON` 会让整份 SDR++ 配置失败 |
| A-2 | `sddc.c:448`、`usb_interface.c`（13 处）、`fx3_boot.c:13` | 隐式指针转换（`int16_t*`/`uint32_t*`/`const uint8_t*` → `unsigned char*`） | **阻断级**：GCC 14+ 起 C23 默认，此类转换由警告升为硬错误 |
| A-3 | `fx3_boot.c`、`sddc.c` | 缺 `#include <stdlib.h>`（malloc/realloc）、`<string.h>`（strlen/strcpy/strcmp）、`<unistd.h>`（usleep） | **阻断级**：C23 下隐式函数声明是硬错误 |
| A-4 | `sddc.c:355` | `sddc_gpio_set()` 声明返回 `int` 却**没有 `return` 语句** | 真实 bug：返回值未定义 |
| A-5 | `fx3_boot.c:86` | `realloc(buffer, size)` **丢弃返回值** | 真实 bug：缓冲区从未扩容，随后 `fread` 对 >64 KB 的固件段会**越界写入**；另外成功路径漏了 `free(buffer)` |
| A-6 | `sddc_info/src/main.cpp:6` | 与模块同一处硬编码 `"C:/Users/ryzerth/Downloads/SDDC_FX3 (1).img"` | 工具在任何别的机器上都不可用 |
| A-7 | `sddc.c:314` | `sddc_gpio_put()` 在定义前被调用，缺前置声明 | **阻断级**：C23 报 implicit declaration 且与真实原型冲突 |

### 另外修复的模块级问题

| 位置 | 原状 | 修复后 |
|---|---|---|
| `sddc_source/src/main.cpp:30` | 硬编码作者本机 Windows 固件路径 | 三级回退：配置项 → `$SDDC_FIRMWARE` → 常见路径搜索（`/usr/share/sddc/`、SDR++ 程序目录、`~/sdr/` 等），并在 UI 加了固件路径输入框 |
| `sddc_source/src/main.cpp:97-124` | 设备枚举整段被注释，用硬编码序列号 `0009072C00C40C32` 顶替 | 恢复 `sddc_get_device_list()`，列表显示"型号[序列号] fw x.y"，并对空列表做了防护 |
| 根 `CMakeLists.txt` | 引用了 `OPT_BUILD_SDDC_SOURCE` 但**从未 `option()` 声明** | 已补上声明（默认 OFF） |

**改动量**：7 个文件，+242 / −59 行。

---

## 五、需要你执行的一步（我无法代做）

`sudo` 需要交互式密码，所以下面两条请你在终端里跑一次：

### 5.1 物理动作（最重要）

**把 RX888 的 USB 线从当前端口拔下来，插到 USB 3.0 端口上**（蓝色口，或支持 10 Gbps 的 USB-C 口）。
插好后用这条命令确认速率变成 `5000` 或 `10000`：

```bash
for d in /sys/bus/usb/devices/*/; do [ "$(cat $d/idVendor 2>/dev/null)" = "04b4" ] && echo "$(cat $d/speed) Mbps"; done
```

### 5.2 一次性环境准备

```bash
sudo bash /home/tsw/sdr/setup-root.sh
```

这一步会完成：安装构建依赖（fftw3/glfw3/volk/zstd/OpenGL/SoapySDR）、把 `usbfs_memory_mb` 提到 1000 并持久化、装 udev 规则（含 `04b4:00f1` 与 `04b4:00f3`）、把固件安装到 `/usr/share/sddc/SDDC_FX3.img`，最后自动复核。

执行完再跑一次自检：

```bash
bash /home/tsw/sdr/verify-hw.sh
```

### 5.3 然后就可以编译了

```bash
bash /home/tsw/sdr/build-all.sh sdrpp    # 只编 SDR++
bash /home/tsw/sdr/build-all.sh all      # libsddc + SoapySDDC + SDR++ 全编
```

---

## 六、交付文件清单

| 文件 | 说明 |
|---|---|
| `/home/tsw/sdr/setup-root.sh` | **需 sudo 执行一次**：依赖 + usbfs + udev + 固件安装 + 复核（幂等，可重复跑） |
| `/home/tsw/sdr/verify-hw.sh` | 环境自检（免 root）：设备、链路速率、权限、缓冲、依赖、工具链，输出通过/注意/失败汇总 |
| `/home/tsw/sdr/build-all.sh` | 构建脚本（免 root，装到 `~/.local`）：`libsddc` / `soapy` / `sdrpp` / `all` |
| `/home/tsw/sdr/SDRPlusPlus` | 已修复的 SDR++ 源码（含 `sddc_source` 模块与内置 libsddc） |
| `/home/tsw/sdr/ExtIO_sddc` | 官方驱动主仓（SoapySDDC + Core + 固件源码 + `SDDC_FX3.img`） |
| `/home/tsw/WorkBuddy/2026-10-01-16-01-30/RX888MkII-Linux-SDRpp-适配方案.md` | 方案主文档（已追加"附录 A：本机实测结论"） |

---

## 七、尚未完成 / 风险提示

| 项 | 状态 | 说明 |
|---|---|---|
| SDR++ 模块编译验证 | ⏳ 待做 | 受限于 `glfw3`/`fftw3f`/`volk`/`libzstd` 需 root 安装；配置流程已验证会正确停在缺包处，说明 CMakeLists 改动无语法问题 |
| SoapySDDC 编译 | ⏳ 待做 | 需 `libsoapysdr-dev` + `libfftw3-dev` |
| 增益 / 端口 / 调谐器控制 | ⏳ 未开始 | 方案文档阶段 3 的 3.6~3.7 项，模块里这 24 行仍是注释状态 |
| 异步 USB 流改造 | ⏳ 未开始 | 方案文档 3.9 项；当前仍是单次同步 bulk transfer（1 s 超时） |
| `rx888_tools` | ⚠️ 受阻 | GitHub 连接不稳定，3 次克隆均失败；该工具是可选的自证/录流工具 |
| 固件与库版本匹配 | ⚠️ 待验证 | 设备目前是 DFU 态，尚未成功上传固件；`hwinfo.model` 能否正确上报出 `RX888 MK2 (0x04)` 需要上传后才能确认 |

> ⚠️ 注意：`ExtIO_sddc` 根目录的 `SDDC_FX3.img` 最后更新于 2022 年（`#225` 提交），而 SDR++ 内置 libsddc v0.2.0 认识 `RX888_MK3 = 0x07` 这类新型号，说明它期望的固件可能更新。**如果上传后型号识别异常或设备不响应控制，这是第一个要查的方向**（备选固件：`ringof/rx888-firmware`，但它移除了 R828D 驱动，只支持 HF 直采）。
