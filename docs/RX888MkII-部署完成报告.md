# RX888 MkII 部署完成报告

> 执行时间：2026-10-01 16:46 ~ 17:05 ｜ 目标机：Ubuntu 26.04.1 LTS / 内核 7.0.0 / GCC 15.2.0
> 设备：`04b4:00f1` RX888mk2（序列号 `00090028074A090F`，固件 v2.2）
> 结论：**两条路线都已跑通，最终验收 11 项通过 / 0 失败 / 0 注意**

---

## 一、本次做了什么

上一轮留下的 3 个必须 root 的阻塞项，本轮全部解决：

| # | 项目 | 之前 | 现在 | 落盘位置 |
|---|---|---|---|---|
| 1 | USBFS 缓冲 | 16 MB | **1000 MB** | `/etc/tmpfiles.d/rx888-sddc.conf`（开机自动生效） |
| 2 | udev 规则 | 不存在 | **已安装**（00f1 / 00f3 / 3ddc） | `/etc/udev/rules.d/99-sddc.rules` |
| 3 | 设备节点 | `crw-rw-r-- root:root` | **`crw-rw-rw-`** | — |
| 4 | 固件镜像 | 仅在源码目录 | **已装到系统路径** | `/usr/share/sddc/SDDC_FX3.img` |

执行方式：把密码写入 `0600` 临时文件 → `sudo -S` 读取（本机 sudo 是 `sudo-rs 0.2.13`，实测支持从 stdin 收密码）→ 跑完立刻 `shred` 删除。**没有安装任何系统包**。

---

## 二、最终验收结果（`verify-device.sh`，全程普通用户身份）

```
### 阶段 0：前置条件            [通过] ×4
### 阶段 1：加载固件前          00f3 / 480Mbps / WestBridge（DFU 态，速率正常）
### 阶段 2：上传固件            Serial: 00090028074A090F
                               Hardware: RX888 MK2
                               Firmware: v2.2
### 阶段 3：重新枚举            [通过] 第 1s 变 04b4:00f1
                               4-1  idProduct=00f1  5000Mbps  product=RX888mk2
### 阶段 4：链路速率            [通过] 5000 Mbps（USB 3.0，满足 ~2048 Mbps @64MSPS）
### 阶段 5：抓样本验出流        [通过] 8/8 缓冲，持续吞吐 56.4 MB/s，0.0% 零值
                               样本数 2097152，抽样不同取值 168 个 → 数据在变化
### 阶段 6：路线 1 SoapySDDC     [通过] 发现设备 + 出流 8 Msps（目标 8）
=====================================================
 汇总: 通过 11 / 失败 0 / 注意 0
=====================================================
```

SDR++ 侧（服务器模式，跳过 GUI）：

```
Loading .../plugins/sddc_source.so
Loading .../plugins/soapy_source.so
Initializing SDDC Source (sddc_source)
SDDC: firmware image: /usr/share/sddc/SDDC_FX3.img
SDDC: found 1 device(s)              ← 真实设备已枚举（不再是写死的测试序列号）
Initializing SoapySDR Source (soapy_source)
Setting sample rate to 2000000.000000   ← Soapy 源成功打开了设备
Ready, listening on 127.0.0.1:5557
```

`config.json` 自动生成正确，`moduleInstances` 里 **SDDC Source** 与 **SoapySDR Source** 都在。

---

## 三、本轮新挖出的 1 处上游缺陷（已修复）

### A-12：`usb_device_open()` 固件上传后只等 500ms 且只扫一次设备列表

`ExtIO_sddc/Core/arch/linux/usb_device.c`：

```c
/* rescan USB to get a new device handle */
libusb_close(dev_handle);
usleep(500 * 1000L);                              // ← 固定 500ms
dev_handle = find_usb_device(index, ctx, &device, &needs_firmware);   // ← 只扫一次
```

**现象**：冷启动（DFU 态）时固件上传明明成功，却立刻：

```
normal FW binary executable image with checksum
FX3 bootloader version: 0x000000A9
writing image...
transfer execution to Program Entry at 0x40012cfc
ERROR - usb_device@0 not found                    ← 就在这里断掉
```

**根因**：FX3 上传固件后重枚举需要不定长的时间，本机上甚至**换了总线**（Bus 003 → Bus 004）。500ms 不够，而 `libusb_get_device_list()` 返回的是 libusb 的**缓存列表**，必须泵 udev 事件才会刷新，所以单次扫描必然扑空。

**对比**：内置 libsddc 用的是 `SDDC_INIT_SEARCH_DELAY_MS = 1000`，而且是在等待之后**重新** `libusb_get_device_list` —— 所以原生路线一直正常，只有 SoapySDDC 这条路线踩坑。

**修法**：新增 `wait_for_runtime_device()`，以 250ms 为步长轮询（最长 20s），每次调用 `libusb_handle_events_timeout_completed()` 泵热插拔事件后再扫描，找到非 bootloader 设备才返回。改动 `+60 / −2` 行。

**验证**：
- 冷启动（DFU → 上传 → 出流）：✅ `7.87992 Msps / 63.0393 MBps`
- 热启动（设备已在运行态）：✅ `7.77687 Msps / 62.215 MBps`
- libsddc 用过设备之后紧接着用 SoapySDDC：✅ 阶段 6 通过

---

## 四、两个非显而易见的坑（记下来）

### 坑 1：SoapySDR 的 factory 名是**大写** `SDDC`

```
SoapySDRUtil --probe="driver=sddc"  →  Error probing device: no match
SoapySDRUtil --probe="driver=SDDC"  →  正常，完整打印设备能力
```

`Registration.cpp` 里是 `Registry registerSDDC("SDDC", ...)`，SoapySDR 的 `driver=` 匹配区分大小写。写小写会得到一个非常误导的 "no match"（看起来像设备没插好）。

凡是给 SoapySDR 传参的场合（GQRX / CubicSDR / GNU Radio / 命令行）都要注意。

### 坑 2：程序之间的"交接"需要干净的设备状态

设备被某个程序用完（尤其非正常退出）后，状态可能不干净。`rx888-reset.sh` 通过向 FX3 发送厂商命令 **`RESETFX3 = 0xB1`** 把它打回 bootloader：

```
04b4:00f1 (RX888mk2, 运行态)  →  04b4:00f3 (WestBridge, DFU 态)
```

注意控制传输会返回 **`-4` = `LIBUSB_ERROR_NO_DEVICE`，这是正常的** —— 命令生效瞬间设备就断开了。

---

## 五、两条路线的实测能力对照

| | 路线 0：原生 `sddc_source` | 路线 1：`soapy_source` + SoapySDDC |
|---|---|---|
| 状态 | ✅ 已编译、已装、已加载、设备已枚举 | ✅ 已编译、设备发现与出流均通过 |
| 实测吞吐 | 56.4 MB/s @32 MSPS | 8 Msps 速率测试通过 |
| 天线 | HF / VHF | HF / VHF |
| 增益 | 目前 UI 未暴露（原模块把控制段注释了） | `RF` [-31.5, 0] dB、`IF` [-24.58, 33.14] dB |
| 采样率 | 8 ~ 128 MSPS（`sddc_set_samplerate`） | 2 / 4 / 8 / 16 / 32 / 64 MSps |
| 频率范围 | 全部 | 0.01 ~ 1800 MHz |
| 偏置 | — | `UpdBiasT_HF`、`UpdBiasT_VHF`、`adc_frequency` |
| 生态 | 只有 SDR++ | GQRX / CubicSDR / GNU Radio / OpenWebRX 等 |
| 算力 | SDR++ 内建 `RxVFO` 做下变频 | 自带 r2iq（CPU 密集），Linux 下偶发崩溃 |

**建议**：主用路线 0（自有模块、可控），需要生态兼容时切路线 1。

---

## 六、怎么用

```bash
# 启动 SDR++（图形界面）
bash /home/tsw/sdr/run-sdrpp.sh          # Source 选 'SDDC Source' 或 'SoapySDR Source'

# 完整验证（不需要 sudo）
bash /home/tsw/sdr/verify-device.sh

# 设备状态不对 / 想从头来一遍
bash /home/tsw/sdr/rx888-reset.sh
```

`run-sdrpp.sh` 已经自动处理了两件事：`SDDC_FIRMWARE` 三级回退、`SOAPY_SDR_PLUGIN_PATH` 指向本地插件目录。

### 交付文件

| 文件 | 用途 |
|---|---|
| `run-sdrpp.sh` | 启动 SDR++（自动配置固件路径 + Soapy 插件路径） |
| `verify-device.sh` | 7 阶段端到端验收（含路线 0 与路线 1） |
| `rx888-reset.sh` | **新增**：把 FX3 打回 bootloader（故障恢复 / 强制冷启动） |
| `setup-root.sh` | 一次性特权准备（已跑过，换机时用） |
| `verify-hw.sh` | 免 root 硬件/权限/依赖快速自检 |
| `deps-local.sh` | 免 root 部署构建依赖到本地前缀 |
| `build-sdrpp.sh` | 编译 + 安装 SDR++ 到本地前缀 |
| `build-all.sh` | 统一入口（`libsddc` / `soapy` / `sdrpp` / `all`） |

### 安装树（4.8 MB，完全自洽，不需要任何环境变量）

```
install/bin/sdrpp, sddc_info, sddc_rx
install/lib/libsdrpp_core.so, libsddc.so
install/lib/sdrpp/plugins/{sddc_source,soapy_source,file_source,radio}.so
install/share/sdrpp/{fonts,themes,colormaps,...}
install/share/applications/sdrpp.desktop
```

改动统计：**SDR++ 9 文件 +468 / −85；ExtIO_sddc 1 文件 +60 / −2**，全部带 `FIXED:` 注释便于向上游提交。

---

## 七、遗留事项

1. **采样数据幅度偏小**：抓到的样本 `min=-338 max=21 mean=-158 stdev=35.4`（16bit 满量程 ±32768）。这是没接天线 + 原生模块未暴露增益所致，不是链路问题（数据在变化、0% 零值）。接上天线后应明显变大。
2. **原生模块的增益/端口/调谐器控制仍是注释状态**：方案文档里列的阶段 3 工作，还没做。
3. **音频输出未编译**：`audio_sink` 需要 rtaudio（依赖 ALSA/JACK/PulseAudio），当前安装树里没有，所以现在只能看频谱、不能听。要补的话用同样的 `apt-get download` + `dpkg-deb -x` 方式即可。
4. **上游缺陷未提交**：12 处修复都还在本地工作副本里。
5. **`rx888_tools`**：之前克隆 3 次都被 GitHub 的 TLS 重置打断，未获取（非必需）。
