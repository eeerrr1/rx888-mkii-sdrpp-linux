# RX888 MkII (SDDC) × SDR++ on Linux

把 **RX888 MkII**（以及 BBRF103 等同族 SDDC 设备）在 Linux 上跑通 SDR++ 的完整补丁集、构建脚本与验证工具。

上游 `sddc_source` 模块是 2025-04 以 prototype 形式并入 SDR++ 的，存在 **12 处缺陷**：其中 3 处直接阻断编译/安装，2 处是真实内存越界 bug，7 处导致"编出来也用不了"。本仓库把这些问题全部修掉，并附带一套**全程免 root** 的依赖部署 + 构建 + 端到端验收脚本。

> 已在 **Ubuntu 26.04.1 LTS / 内核 7.0.0 / GCC 15.2.0** 上实测通过。
> GCC 15 默认 `-std=c23`，上游那批隐式转换/隐式声明会直接变成**硬错误**——这是本补丁集存在的主要动机。

---

## 一、快速开始

```bash
git clone <本仓库> && cd rx888-mkii-sdrpp-linux

# ① 拉取上游源码
git clone --depth 1 https://github.com/AlexandreRouma/SDRPlusPlus.git
git clone --depth 1 https://github.com/ik1xpv/ExtIO_sddc.git

# ② 打补丁
(cd SDRPlusPlus  && git apply ../patches/sdrpp/ALL-SDRPlusPlus.patch \
                 && cp ../patches/sdrpp/new-libsddc.pc.in source_modules/sddc_source/libsddc/libsddc.pc.in)
(cd ExtIO_sddc   && git apply ../patches/extio_sddc/ALL-ExtIO_sddc.patch)

# ③ 免 root 部署依赖（apt-get download + dpkg-deb -x，不写 /usr、不动 dpkg 库）
bash scripts/deps-full.sh
bash scripts/deps-vendor.sh        # 可选：编 librfnm / libfobos / dlcr 等厂商库

# ④ 全量编译 SDR++
SDR_LOCAL_PREFIX=$PWD/local SRC=$PWD/SDRPlusPlus INSTALL=$PWD/install \
  bash scripts/build-sdrpp-full.sh build

# ⑤ 一次性特权准备（udev 规则 / usbfs_memory_mb / 固件）——唯一需要 root 的一步
sudo bash scripts/setup-root.sh

# ⑥ 端到端验收
bash scripts/verify-device.sh
```

运行：

```bash
bash scripts/run-sdrpp.sh          # Source 里选 "SDDC Source" 或 "SoapySDR Source"
```

---

## 二、修了什么（12 处上游缺陷）

### A. 阻断编译 / 安装

| # | 位置 | 问题 | 修法 |
|---|---|---|---|
| 1 | `libsddc/CMakeLists.txt` | `configure_file(${CMAKE_SOURCE_DIR}/libsddc.pc.in ...)` —— 该文件**仓库里根本不存在**，且 `${CMAKE_SOURCE_DIR}` 在子目录构建时指向 SDR++ 根目录 → `configure_file` 失败 → **整个 SDR++ 配置中止** | 补 `libsddc.pc.in`；改用 `${CMAKE_CURRENT_SOURCE_DIR}` |
| 2 | 13 处 `libusb_*_transfer()` | `int16_t*` / `uint32_t*` → `unsigned char*` 隐式指针转换，C23 下是硬错误 | 加显式 cast（**没有**靠降级 `-std=` 绕过） |
| 3 | `fx3_boot.c` / `sddc.c` | 缺 `<stdlib.h>` / `<string.h>` / `<unistd.h>` → 隐式函数声明，C23 硬错误 | 补头文件 |
| 4 | `sddc.c` | `sddc_gpio_put()` 定义前被调用，缺前置声明 | 补声明 |
| 5 | `libsddc/CMakeLists.txt` | `install(DIRECTORY ${CMAKE_SOURCE_DIR}/include/ ...)` —— 与 #1 同源的 `${CMAKE_SOURCE_DIR}` 误用 → **`make install` 中止**，后续模块全部装不上（单独构建 libsddc 时又正常，所以上游没发现） | 改用 `${CMAKE_CURRENT_SOURCE_DIR}` |

> `${CMAKE_SOURCE_DIR}` vs `${CMAKE_CURRENT_SOURCE_DIR}` 是这个项目的典型 bug 模式，出现了两次：一次阻断 configure，一次阻断 install。

### B. 真实内存 bug

| # | 位置 | 问题 | 修法 |
|---|---|---|---|
| 6 | `fx3_boot.c` | `realloc(buffer, size)` **丢弃返回值** → 缓冲区从未扩容，>64 KB 的固件段会**越界写入**；成功路径还漏了 `free` | 接住返回值 + 失败处理 + 补 `free` |
| 7 | `sddc.c` | `sddc_gpio_set()` 声明返回 `int` 却**没有 `return`** | 补 `return` |

### C. 功能性阻断（模块编出来也用不了）

| # | 位置 | 问题 | 修法 |
|---|---|---|---|
| 8 | `sddc_source/src/main.cpp` | 构造函数硬编码 `sddc_set_firmware_path("C:/Users/ryzerth/Downloads/SDDC_FX3 (1).img")` → 固件上传必失败 | 三级回退：环境变量 → 安装路径 → 源码树 |
| 9 | 同上 | `refresh()` 里设备枚举整段被注释，替换为硬编码序列号 `0009072C00C40C32` | 恢复真实枚举，只枚举已插入设备 |
| 10 | `core/src/core.cpp` | `moduleInstances` 里**既没有 SDDC Source 也没有 SoapySDR Source** → 模块加载了但界面永不出现，**两条路线同时被挡** | 补两个实例声明 |
| 11 | `libsddc/utils/sddc_rx`、`sddc_info` | 工具里同样是硬编码作者本机路径 + 写死序列号；`sddc_rx` 还是 `while(true)` 死循环，且把**错误码当样本数**打印 | 恢复枚举 / 正确处理错误码 / 增加 `--samples` 限量 |

### D. SoapySDDC（ExtIO_sddc）侧

| # | 位置 | 问题 | 修法 |
|---|---|---|---|
| 12 | `Core/arch/linux/usb_device.c` 的 `usb_device_open()` | 固件上传后只 `usleep(500ms)` 且**只扫一次** `libusb_get_device_list()`。500ms 不够，FX3 重枚举还可能**换总线**（实测 Bus 003→004）；而 `libusb_get_device_list()` 返回的是 libusb 的**缓存列表**，必须泵 udev 事件才会刷新 → 单次扫描必然扑空，报 `ERROR - usb_device@0 not found`，**紧跟在一个成功的固件上传之后**，极具误导性 | 新增 `wait_for_runtime_device()`：250 ms 步长轮询（上限 20 s），每轮先 `libusb_handle_events_timeout_completed()` 泵热插拔事件再扫描 |

> 对照：内置 `libsddc` 用的是 `SDDC_INIT_SEARCH_DELAY_MS = 1000`，且等待之后**重新**扫描，所以原生路线一直正常 —— 只有 SoapySDDC 这条路线踩坑。**同一个硬件，两个库的等待策略不同，一个能跑一个不能。**

补丁拆分见 `patches/sdrpp/*.patch`（按文件分组，便于上游逐条 review）。所有改动都带 `FIXED:` 注释。

---

## 三、两条路线

| | 路线 0：原生 `sddc_source` | 路线 1：`soapy_source` + SoapySDDC |
|---|---|---|
| 状态 | ✅ 已编译、已装、已加载、设备已枚举 | ✅ 已编译、设备发现与出流均通过 |
| 实测吞吐 | 56.4 MB/s @32 MSPS | 8 Msps 固定速率测试通过 |
| 增益 | 目前 UI 未暴露（上游把控制段注释了） | `RF` [-31.5, 0] dB、`IF` [-24.58, 33.14] dB |
| 采样率 | 8 ~ 128 MSPS | 2 / 4 / 8 / 16 / 32 / 64 MSps |
| 频率范围 | 全部 | 0.01 ~ 1800 MHz |
| 生态 | 只有 SDR++ | GQRX / CubicSDR / GNU Radio / OpenWebRX… |
| 算力 | SDR++ 内建 `RxVFO` 做下变频 | 自带 r2iq（CPU 密集） |

**建议**：主用路线 0；需要生态兼容时切路线 1。

⚠️ **SoapySDR 的 factory 名是大写 `SDDC`**：

```bash
SoapySDRUtil --probe="driver=sddc"   # Error probing device: no match   ← 误导性极强
SoapySDRUtil --probe="driver=SDDC"   # 正常，打印完整设备能力
```

---

## 四、实测验收（`scripts/verify-device.sh`）

```
### 阶段 0：前置条件            [通过] ×4
### 阶段 1：加载固件前          00f3 / 480Mbps（DFU 态，速率无参考价值）
### 阶段 2：上传固件            Serial: 00090028074A090F / Hardware: RX888 MK2 / Firmware: v2.2
### 阶段 3：重新枚举            [通过] 第 1s 变 04b4:00f1
### 阶段 4：链路速率            [通过] 5000 Mbps（USB 3.0）
### 阶段 5：抓样本验出流        [通过] 8/8 缓冲，持续吞吐 56.4 MB/s，0.0% 零值
### 阶段 6：路线 1 SoapySDDC     [通过] 发现设备 + 出流 8 Msps
=====================================================
 汇总: 通过 11 / 失败 0 / 注意 0
=====================================================
```

---

## 五、硬件侧两个反直觉事实

### 1. DFU 态下的 USB 速率没有参考价值

Cypress 应用笔记 **AN76405** 明确写着：FX3 处于 USB boot 模式时 **SuperSpeed 被硬件关闭，只启用 USB 2.0**。

所以未加载固件时（`04b4:00f3`，产品名 `WestBridge`）在**任何**端口上都只报 480 Mbps —— **不能据此判断端口/线缆好坏**。

FX3 是两步枚举：`04b4:00f3`（DFU，USB 2.0）→ 上传固件 → `04b4:00f1`（运行态，可协商 USB 3.0）。**只有第二步之后看 `speed` 才有意义。**

### 2. `usbfs_memory_mb` 默认只有 16 MB

高采样率下会丢样本 / `LIBUSB_ERROR_NO_MEM`。放大到 256~1000。

持久化注意：**Ubuntu 的 `usbcore` 是编进内核的（不是模块），`/etc/modprobe.d/` 无效**，必须用 `systemd-tmpfiles`，且路径放 `/etc/tmpfiles.d/`：

```
w /sys/module/usbcore/parameters/usbfs_memory_mb - - - - 1000
```

---

## 六、目录结构

```
patches/
  sdrpp/            SDR++ 侧 9 个文件的独立补丁 + ALL-SDRPlusPlus.patch + 新增 libsddc.pc.in
  extio_sddc/       ExtIO_sddc 侧补丁（A-12）
scripts/
  deps-full.sh         免 root 部署完整构建依赖（对齐官方 ubuntu_resolute 的 apt 集）
  deps-vendor.sh       编译 apt 源里没有的厂商库（librfnm / libfobos / dlcr / perseus / sdrplay）
  build-sdrpp-full.sh  全量编译：按 pkg-config 探测结果自动决定每个模块 ON/OFF
  build-sdrpp.sh       最小验证版（只编 RX888 相关的 4 个模块）
  setup-root.sh        一次性特权准备（udev / usbfs / 固件）——唯一需要 root 的一步
  verify-device.sh     7 阶段 11 项端到端验收
  run-sdrpp.sh         启动器（自动处理固件路径回退 + Soapy 插件路径）
  rx888-reset.sh       把 FX3 打回 bootloader（故障恢复）
  verify-hw.sh         免 root 硬件/权限/依赖快速自检
docs/               部署报告与适配方案
```

### 免 root 依赖部署的原理

`apt-get download` **不需要 root**（只要能读包索引 + 当前目录可写），再用 `dpkg-deb -x` 把 `.deb` 解到本地前缀，效果等价于安装到 `/usr`，但不写系统目录、不动 dpkg 数据库 —— 卸载只需 `rm -rf local/`。

两个必须注意的点：

1. **`.pc` 文件要重定位**。有些 `.pc` 写作 `prefix=/usr`（行尾无斜杠），必须先单独处理，否则简单的 `s|/usr/|...|g` 会漏掉它，`pkg-config` 静默回退到系统路径 → 编译失败。
2. **dev 包只提供 `.so` 软链接，实体在运行库包里**。不一起解出来就会得到悬空链接（`libOpenGL.so -> libOpenGL.so.0` 指向不存在），CMake 报 `missing: OPENGL_opengl_LIBRARY`。所以清单里每个 `-dev` 都紧跟它的运行库包。

---

## 七、完整构建的模块覆盖

`build-sdrpp-full.sh` 不硬编码开关，而是**逐个模块用 `pkg-config` 探测**，有依赖就 ON、没有就 OFF。

**已启用**（对齐 SDR++ 官方 `docker_builds/ubuntu_resolute/do_build.sh`）：

- 源：`sddc` / `soapy` / `airspy` / `airspyhf` / `audio` / `hackrf` / `plutosdr` / `rtl_sdr` / `bladerf` / `limesdr` / `hydrasdr` / `file` / `hermes` / `network` / `rfspace` / `rtl_tcp` / `sdrpp_server` / `spectran_http` / `spyserver`
- Sink：`audio`（★ 关键：上游最小构建里没有它，导致"只能看频谱不能听"）/ `network` / `new_portaudio` / `portaudio`
- 解码：`radio` / `atv` / `meteor` / `pager` / `dab` / `m17` / `kg_sstv` / `ryfi` / `vor` / `weather_sat`
- 其他：`discord_presence` / `frequency_manager` / `iq_exporter` / `recorder` / `rigctl_client` / `rigctl_server` / `scanner` / `scheduler`

**未启用及原因**：

| 模块 | 原因 |
|---|---|
| `usrp` | 未装 `libuhd`——它会拖入整套 Boost dev（11 个包）。官方 Dockerfile 同样没编它 |
| `perseus` | 需要 autotools；release tarball 的 configure 在本环境跑不通。厂商文档建议自行编译 |
| `rfnm` | `librfnm` 的 cmake 依赖链（spdlog→fmt）在本地前缀下仍未完全自洽 |
| `sdrplay` | 厂商闭源 API，官方下载路径已失效（需注册/EULA），且安装器会装系统守护进程 |
| `kcsdr` | 需厂商 FTD3XX SDK，`source_modules` 下无源码 |
| `badgesdr` | `source_modules/badgesdr_source` 目录不存在 |
| `harogic` / `spectran` | 需 Aaronia 闭源 SDK |
| `falcon9` | 需 `ffplay` |

---

## 八、已知限制

1. **抓到的样本幅度偏小**（`min=-338 max=21 mean=-158`，16bit 满量程 ±32768）：这是**没接天线** + 原生模块未暴露增益所致，不是链路问题（数据在变化、0% 零值）。接天线后应明显变大。
2. **原生模块的增益/端口/调谐器控制仍是注释状态**（上游遗留），方案文档里列为后续工作。
3. **12 处修复目前只在本仓库**，尚未提交上游。

---

## 九、许可

- 本仓库的补丁与脚本：随上游保持一致（GPL-3.0）。
- `patches/` 中的改动仅针对上游代码，版权归原作者。
- SDR++ 由 AlexandreRouma 开发；ExtIO_sddc / SoapySDDC 由 ik1xpv 等开发。
