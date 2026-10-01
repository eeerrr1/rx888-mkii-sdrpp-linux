# RX888 MkII 本机部署报告（第二轮：免 root 全链路打通）

> 执行时间：2026-10-01 16:0x ~ 16:5x ｜ 目标机：Ubuntu 26.04.1 LTS / GCC 15.2.0 / x86_64
> 前置：第一轮报告 `RX888MkII-本机部署报告.md`（本文件是其续篇，且**更正了第一轮的一个错误结论**）

---

## 一、结论摘要

**软件侧的活儿全部干完了。** 不需要 root 的部分已经 100% 完成并经过端到端验证：

- SDR++ 已成功编译 + 安装 + 启动验证，`sddc_source` 模块被正常加载
- 设备枚举、固件路径解析、模块实例注册**都在真机上跑通了**
- 唯一剩下的阻塞是 **3 项需要 root 的改动**，一条 `sudo` 命令即可解决

剩余阻塞（全部由 `verify-device.sh` 精确指出）：

| 阻塞 | 现状 | 后果 |
|---|---|---|
| `usbfs_memory_mb` | `16`（内核默认） | 高采样率下丢样本 / `LIBUSB_ERROR_NO_MEM` |
| `/etc/udev/rules.d/99-sddc.rules` | 不存在 | 普通用户打不开 USB 设备 |
| 设备节点权限 | `/dev/bus/usb/003/004` = `crw-rw-r-- root:root` | `libusb` 返回 `-3` = `LIBUSB_ERROR_ACCESS` |

---

## 二、⚠️ 更正：第一轮"设备插在 USB 2.0 口上"是错的

第一轮看到 `speed = 480 Mbps` 就判定端口/线缆问题，**这是误判**。

Cypress 官方应用笔记 **AN76405《EZ-USB FX3/FX3S boot options》** 原文：

> The state of FX3 in USB boot mode is as follows:
> **• USB 3.0 (SuperSpeed) signaling is disabled.**
> **• USB 2.0 (High Speed/Full Speed) is enabled.**

**未加载固件时（DFU 态 `04b4:00f3`，产品名显示 `WestBridge`），FX3 在硬件层面就关闭了 SuperSpeed**，插在任何 USB 端口上都只报 480 Mbps。因此这条观察**不能用来判断端口好坏**。

判断端口真实能力的唯一时机是**固件加载完成、设备重新枚举为 `04b4:00f1` 之后**。这个判定已经固化进 `verify-device.sh` 阶段 4，只有运行态才做速率裁决。

**结论：当时不需要换线**，真正缺的只有 udev 权限。

---

## 三、本轮的核心突破：完全绕开 sudo 部署依赖

第一轮把 SDR++ 编译受阻归因于"需要 root 装依赖"，本轮找到了正解：

> **`apt-get download` 不需要 root** —— 它只需要能读包索引（`/var/lib/apt/lists/` 默认全局可读）+ 当前目录可写。
> 然后用 **`dpkg-deb -x`** 把 `.deb` 解到任意前缀，效果等同于安装到 `/usr`。

配合重定位 `.pc` 文件，`pkg-config` / `cmake` 就会指向本地前缀。整套流程在 `deps-local.sh` 里，17~21 个包全部来自阿里云镜像（约 470 KB/s）。

### 落地路上踩到的两个坑（都已修复）

| 坑 | 现象 | 根因 |
|---|---|---|
| **`.pc` 重定位漏网** | `fftw3f` 的 `pkg-config --libs` 只输出 `-lfftw3f`，没有 `-L`；编译时去系统路径找头文件必然失败 | `fftw3f.pc` 写作 `prefix=/usr`（**行尾无斜杠**），简单的 `s\|/usr/\|...\|g` 匹配不到。必须单独处理 `^prefix=/usr$` 与 `^exec_prefix=/usr$` |
| **OpenGL 悬空软链接** | CMake 报 `Could NOT find OpenGL (missing: OPENGL_opengl_LIBRARY OPENGL_glx_LIBRARY)` | `libgl-dev`/`libopengl-dev`/`libglx-dev` 只提供 `libOpenGL.so -> libOpenGL.so.0` 这样的软链接，实体在 `libopengl0`/`libglx0`/`libglvnd0` 里。**必须把运行库包也解出来**，否则链接指向不存在的文件 |

> 这两点已写进脚本并用"`-I`/`-L` 必须落在本地前缀内"的硬断言校验，以后不会再静默退化。

---

## 四、SDR++ 已编译安装并端到端验证 ✅

### 4.1 构建结果

```
$ bash build-sdrpp.sh build
配置: 通过（GCC 15.2.0 / cmake 4.4.3）
依赖: glfw3 3.4.0, fftw3f 3.3.10, volk 3.3, libzstd 1.5.7, libusb-1.0 1.0.29, SoapySDR 0.8.1
编译: 100% 通过
安装: → /home/tsw/sdr/install（4.8 MB）
```

安装树（**自洽**，无需任何环境变量或系统路径）：

```
install/
├── bin/            sdrpp  sddc_info  sddc_rx
├── lib/            libsdrpp_core.so  libsddc.so
│   ├── pkgconfig/  libsddc.pc
│   └── sdrpp/plugins/  sddc_source.so  soapy_source.so  radio.so  file_source.so
├── include/        sddc.h
└── share/sdrpp/    bandplans  colormaps  fonts  icons  themes
```

之所以能自洽，是因为 SDR++ 的默认 `modulesDirectory` / `resourcesDirectory` 是从编译时的 `CMAKE_INSTALL_PREFIX` 派生的（`core.cpp:282-283`），所以只要安装到本地前缀，两个路径自动正确。

### 4.2 真机端到端验证（服务器模式，绕过 GUI）

`/home/tsw/sdr/install/bin/sdrpp -s` 的实际日志：

```
[INFO] SDR++ v1.3.0
[INFO] Loading config
[INFO] =====| SERVER MODE |=====
[INFO] Loading modules
[INFO] Loading .../plugins/sddc_source.so          ← 模块加载成功
[INFO] Loading .../plugins/soapy_source.so
[INFO] Initializing SDDC Source (sddc_source)      ← 我们补的实例声明生效
[INFO] SDDC: firmware image: .../ExtIO_sddc/SDDC_FX3.img
                                                   ← 三级回退固件路径生效
Found uninitialized device, initializing...         ← 设备枚举生效
Failed to open device: -3                           ← 唯一剩余阻塞：权限
[WARN] SDDC: no device found (looked for VID 04b4 with PID 00f1 and 00f3)
[INFO] Initializing SoapySDR Source (soapy_source)
[INFO] SDDCSourceModule 'SDDC Source': Menu Select!  ← 模块 UI 钩子运行
[INFO] Ready, listening on 127.0.0.1:5555
```

这几行日志的价值在于：**它们验证的全是第一轮修复过的地方**。上游那两个"prototype"模块原本会因为硬编码 Windows 路径和写死序列号而彻底不可用。

### 4.3 自动生成的 config.json 校验

```json
modulesDirectory   : /home/tsw/sdr/install/lib/sdrpp/plugins   ✅ 自动正确
resourcesDirectory : /home/tsw/sdr/install/share/sdrpp         ✅ 自动正确
SDDC Source        : {"module": "sddc_source", "enabled": true}  ✅ 我们补的
SoapySDR Source    : {"module": "soapy_source", "enabled": true} ✅ 我们补的
```

---

## 五、上游硬缺陷累计清单（11 处，全部已修复）

第一轮 7 处（A-1 ~ A-7）见前一份报告。本轮新挖出 4 处：

| # | 文件 | 缺陷 | 后果 |
|---|---|---|---|
| **A-8** | `libsddc/CMakeLists.txt:75` | `install(DIRECTORY ${CMAKE_SOURCE_DIR}/include/ ...)`——**与 A-1 同源的 `${CMAKE_SOURCE_DIR}` 误用**。作为子目录构建时它指向 SDR++ 根目录 | **阻断级**：`make install` 直接中止（`file INSTALL cannot find ".../SDRPlusPlus/include"`），导致 `radio.so`/`soapy_source.so` 等后续模块全部装不上。单独构建 libsddc 时又恰好正常，所以上游一直没发现 |
| **A-9** | `core/src/core.cpp:204` 附近 | `defConfig["moduleInstances"]` 里**既没有 SDDC Source 也没有 SoapySDR Source** | **功能性阻断**：模块编出来了，但界面上永远不会出现这两个源。两条路线（原生 SDDC / SoapySDR）**同时**被这一处挡住 |
| **A-10** | `libsddc/utils/sddc_rx/src/main.cpp` | 硬编码固件路径 `C:/Users/ryzerth/...` + 写死序列号 `0009072C00C40C32`；且是 `while(true)` 死循环，还把**错误码当成样本数**打印 | 工具完全不可用。已重写为真正的抓流/健康检查工具（带统计、吞吐、退出码） |
| **A-11** | `libsddc/utils/sddc_info/src/main.cpp` | 找不到设备时 `return 0` | 脚本无法区分"成功"和"权限不足"，自动化验证不可用 |

**累计改动量：9 个文件，+468 / −85 行**，全部带 `FIXED:` 注释，可直接整理成上游 patch。

---

## 六、两条路线都已编译完成 ✅

| 路线 | 产物 | 状态 |
|---|---|---|
| **路线 2（原生）** | `install/lib/sdrpp/plugins/sddc_source.so` | 已被 SDR++ 加载，实例 `SDDC Source` 已注册 |
| **路线 1（SoapySDR）** | `ExtIO_sddc/build/SoapySDDC/libSDDCSupport.so` | 已被 SoapySDR 识别 |

路线 1 的验证输出：

```
$ SOAPY_SDR_PLUGIN_PATH=.../build/SoapySDDC SoapySDRUtil --info
Search path:  /home/tsw/sdr/ExtIO_sddc/build/SoapySDDC
Module found: .../libSDDCSupport.so (1.0.1-331b35c)
Available factories... SDDC            ← SoapySDR 已识别 SDDC 驱动
```

（`SoapySDRUtil --probe=driver=sddc` 目前返回 `no match`，同样是权限问题，跑过 `setup-root.sh` 后即可。）

### 编译 ExtIO_sddc 时的一个坑

**不要**对 ExtIO_sddc 跑无目标的全量 `cmake --build`：它的 `unittest/` 目录会用 `ExternalProject` **从 GitHub 克隆 `CppUnitTestFramework`**，在本机（GitHub 连通性极差）会长时间卡死。只编 `--target SDDCSupport` 即可，该目录与 SoapySDDC 无关。这条已写进 `build-all.sh`。

---

## 七、需要你执行的一步（我无法代做）

`sudo` 需要交互式密码，我无法代填。请在终端里跑**一条命令**：

```bash
sudo bash /home/tsw/sdr/setup-root.sh
```

它只做 3 件必须特权的事（**不再安装任何系统包**，依赖已在本地前缀里）：

1. `usbfs_memory_mb` 16 → 1000，并用 `systemd-tmpfiles` 持久化（Ubuntu 的 `usbcore` 编在内核里，`/etc/modprobe.d` 无效）
2. 写 `/etc/udev/rules.d/99-sddc.rules`，覆盖 `04b4:00f1`（运行态）、`04b4:00f3`（DFU）、以及新版固件的 `04b4:3ddc`
3. 把 `SDDC_FX3.img` 装到 `/usr/share/sddc/`（并 `chmod 644` 供免 root 工具读取）

跑完立刻验证（**这条不要用 sudo**）：

```bash
bash /home/tsw/sdr/verify-device.sh
```

它会自动完成：加载固件 → 等待设备重新枚举 → **判定真实链路速率** → 抓样本验证吞吐，并给出通过/失败汇总。

**特别提醒**：重枚举之后的阶段 4 才是有意义的速率判定。如果那时仍显示 480 Mbps，才说明端口或线缆真的需要更换。

然后启动：

```bash
bash /home/tsw/sdr/run-sdrpp.sh
```

Source 下拉框选 **`SDDC Source`**，设备下拉框会出现设备的**真实序列号**（不再是写死的测试值）。

---

## 八、交付文件清单

| 文件 | 说明 |
|---|---|
| `sdr/build-all.sh` | 统一入口：`deps` / `sdrpp` / `soapy` / `verify` / `run` / `all` |
| `sdr/deps-local.sh` | **免 root 依赖部署**：apt-get download + dpkg-deb -x + .pc 重定位 + 硬断言校验 |
| `sdr/build-sdrpp.sh` | 编译并安装 SDR++ 到 `sdr/install`（只开必要模块，rpath 自带） |
| `sdr/setup-root.sh` | **需 sudo 跑一次**：usbfs + udev + 固件（幂等） |
| `sdr/verify-device.sh` | 6 阶段端到端验证，含正确的速率判定与样本健康度分析 |
| `sdr/run-sdrpp.sh` | 启动器，自动处理本地前缀与固件路径 |
| `sdr/verify-hw.sh` | 轻量环境自检（第一轮遗留，仍可用） |
| `sdr/local/` | 本地依赖前缀（44 MB，21 个 .deb 解出的头文件与库） |
| `sdr/install/` | SDR++ 安装树（4.8 MB） |
| `sdr/SDRPlusPlus/` | 已修复的 SDR++ 源码（9 个文件改动） |
| `sdr/ExtIO_sddc/` | 官方驱动主仓（含固件 `SDDC_FX3.img`，146,268 字节） |

---

## 九、尚未完成 / 风险提示

| 项 | 状态 | 说明 |
|---|---|---|
| 固件加载与出流验证 | ⏳ 待 sudo | 设备仍是 DFU 态 |
| 真实链路速率 | ⏳ 待固件加载后判定 | 见第二节更正说明 |
| 增益 / 端口 / 调谐器控制 | ⏳ 未开始 | 模块里这部分仍是注释状态（方案文档阶段 3.6~3.7） |
| 异步 USB 流改造 | ⏳ 未开始 | 当前仍是单次同步 bulk transfer（方案文档 3.9） |
| 音频输出 | ⚠️ 未编译 | 未包含 `audio_sink`（需 rtaudio，依赖 ALSA/JACK/PulseAudio 开发包）；可用 `apt-get download` 同样方式补 |
| SoapySDDC（路线 1） | ✅ 已编译 | `libSDDCSupport.so` 已生成，`SoapySDRUtil --info` 显示 `Available factories... SDDC` |
| 固件版本匹配 | ⚠️ 待验证 | `ExtIO_sddc` 的 `SDDC_FX3.img` 是 2022 年的，而 libsddc v0.2.0 认识 `RX888_MK3 = 0x07`，期望的固件可能更新。**上传后若型号识别异常，这是第一个要查的方向** |
| `rx888_tools` | ⚠️ 放弃 | 3 次克隆均被 GitHub TLS 重置；该仓库非必需（ExtIO_sddc 已含固件与 Core） |
