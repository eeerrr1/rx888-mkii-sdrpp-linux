# RX888 MkII 在 Linux 下适配 SDR++ 的技术分析与实施方案

> 调研时间：2026-10-01 ｜ 目标：在 Linux 上让 RX888 MkII 在 SDR++ 中"能收、能控、稳定"

---

## 0. 结论速览

1. **好消息**：SDR++ 上游**已经有** `source_modules/sddc_source` 模块，并且随模块内置了一份 `libsddc`（v0.2.0，纯 C，只依赖 libusb，**不需要 CUDA**）。适配不是"从零写驱动"。
2. **坏消息**：这个模块是 2025-04-23 提交的 **原型（prototype）**，包含四处"作者本机可用、别人不可用"的硬编码，且 RF 前端控制整段被注释。**直接 clone 编译会失败或启动即崩。**
3. **推荐路径**：先走 **SoapySDDC + SDR++ 的 `soapy_source` 模块**（半天内出可用画面，作为基准与对照），再投入 **3~5 天修复并增强原生 `sddc_source`**（暴露增益/端口/调谐器 + 改成异步 USB 流）。第三条 `rx888_stream` 旁路链作为应急与验证手段。
4. **四个前置条件不做必然踩坑**：USB 3.0 直连、`usbfs_memory_mb` 放大、udev 权限、**固件与主机库版本匹配**。任何一条不满足，现象都是"有数据流但只有噪声 / 应用完全不响应设备控制"，极难反查。

---

## 1. 硬件与协议基线

| 项目 | 参数 | 对适配的影响 |
|---|---|---|
| ADC | LTC2208，16 bit @ 130 MSPS（标称） | 满速数据量 128 MSPS × 2 B = **256 MB/s**，必须 USB 3.0 |
| HF 通道 | 1 kHz ~ 64 MHz **直采**，可整段实时输出 | 64 MHz 带宽对 PC 侧下变频与 FFT 算力要求高 |
| VHF/UHF 通道 | R828D 调谐器，64 MHz ~ 1.7 GHz（官网标到 1.8 GHz） | 实时带宽约 10 MHz；需主机侧经 I²C 透传驱动 |
| 时钟 | Si5351 + 0.5 ppm VCXO，支持外部 27 MHz 参考 | 校准项，影响频率准确度 |
| 前端增益 | HF：可调衰减器 + AD8340 VGA（合成约 −41.5 ~ +33 dB）；VHF：约 0 ~ 55 dB | **是"适配"必须暴露的关键控制项**，原型模块里全部缺失 |
| 其他 | Bias-T（HF/VHF 独立）、ADC PGA / Dither / Randomizer | 应做成可开关选项 |
| USB ID | Bootloader `04b4:00f3` → 运行态 `04b4:00f1` | udev 规则必须**两条都写** |
| 固件 | `SDDC_FX3.img`（Cypress FX3 / EZ-USB） | 固件与主机库的厂商命令集必须匹配 |

> ⚠️ 官方在产品页明确声明市面上存在**山寨 RX888**，这些设备性能与支持都不保证。适配排查时若现象离奇，先确认设备真伪。

---

## 2. 现状诊断：为什么不能"装个包就用"

### 2.1 软件栈分层

硬件 → FX3 固件 → 主机库（libusb 之上）→ SDR 应用。RX888 生态的分裂点在第 3 层，历史上并行存在过至少 4 套主机库：

| 主机库 | 维护状态 | 特点 | 适用 |
|---|---|---|---|
| `ik1xpv/ExtIO_sddc` 官方主仓 | **活跃**（最后提交 2026-03-10） | Core + ExtIO + **SoapySDDC**；v1.4 起固件内嵌；含 R828D VHF 支持 | Linux/Windows **首选** |
| `fventuri/libsddc` | 老分支，作者注明"开发已并入 ExtIO_sddc" | GPLv3，含 firmware 目录；**老版本 r2iq 走 CUDA，需 NVIDIA GPU** | 历史参考 |
| `renardspark/SDDC_Driver` | 活跃（2025-11） | 对 ExtIO_sddc Core 的深度重写，明确"仅 Linux/macOS" | 备选主线 |
| `cozycactus/SoapyRX888` + `librx888` | **已停更**（2023） | 仅支持一代 RX888，MkII 支持不全 | 不建议 |
| SDR++ 内置 `libsddc` | 原型级 | 纯 C，无 CUDA，只做 USB 搬运 | 见 2.3 |

另有一条完全独立的**流式 CLI 链**：`rhgndf/rx888_stream`、`ringof/rx888_tools`（rx888_stream + rx888_dsp + iqrecord）、以及配套固件 `ringof/rx888-firmware`。它的定位是"把样点稳定地吐到 stdout/FIFO"，被 PhantomSDR / PhantomSDR-Plus / FernSDR 这类 WebSDR 采用。

### 2.2 SDR++ `sddc_source` 的具体缺陷（这是"适配"的核心工作量）

模块路径 `source_modules/sddc_source/`，作者 Ryzerth，版本号 `0,2,0`。逐条列出阻塞项：

| # | 位置 | 问题 | 后果 |
|---|---|---|---|
| 1 | `main.cpp` 构造函数 | `sddc_set_firmware_path("C:/Users/ryzerth/Downloads/SDDC_FX3 (1).img")` | 硬编码作者本机 Windows 路径；固件上传必然失败（`sddc_init()` 里 `// TODO: Find the firmware` 也没实现自动查找） |
| 2 | `main.cpp` `refresh()` | 完整的 `sddc_get_device_list()` 枚举被注释，替换成 `devices.define("0009072C00C40C32", "TESTING", ...)` | 设备列表只有一个假条目，且序列号是作者机器的 |
| 3 | 根 `CMakeLists.txt` | 引用了 `if (OPT_BUILD_SDDC_SOURCE)`，但**该 `option()` 从未声明** | 默认永不编译；官方发行版不含此模块（必须显式 `-DOPT_BUILD_SDDC_SOURCE=ON`） |
| 4 | `menuHandler()` / `worker()` | 端口选择、LNA/VGA 增益、调谐器频率、HF1/HF2/VHF 分支全部被注释掉 | 无法控制 RF 前端；VHF 段完全不可用 |
| 5 | `start()` | 采样率语义隐式：`sddc_set_samplerate(sampleRate * 2)` | UI 上的 64 MHz 实际是"ADC 128 MSPS 的实数流"，容易被误解为 IQ 带宽 |
| 6 | `worker()` | `bufferSize = sampleRate / 100.0`（64 MHz 时 64 万样点 = 1.28 MB 单次同步 bulk transfer），代码注释自承是"workaround for their API having broken streaming" | 大缓冲 + 同步传输，对 `usbfs_memory_mb` 极敏感，易丢样本 |

模块**可用**的部分：`MOD_INFO`、配置管理、采样率列表、用 SDR++ 内建 `dsp::channel::RxVFO` 做实数→复数的下变频（`volk_16i_s32f_convert_32f` + 交织空 Q + `ddc.setOffset(freq)`）。这条思路本身是对的，可以保留。

### 2.3 SDR++ 内置 `libsddc` v0.2.0 的缺口

| # | 问题 | 说明 |
|---|---|---|
| 1 | 公开 API 无增益接口 | 内部已有 `sddc_fx3_set_param()` 与 `SDDC_PARAM_R82XX_ATT(1)` / `R83XX_VGA(2)` / `DAT31_ATT(10)` / `AD8340_VGA(11)` / `VHF_ATT(13)` / `PRESELECTOR(12)`，但 `sddc.h` 未把它们语义化导出 |
| 2 | `sddc_open()` 硬编码前端初值 | 固定写入 `R82XX_ATT=15`、`R83XX_VGA=9`、`AD8340_VGA=5`，并把 `SEL0/SEL1/VHF_EN` 写死；且 `sddc_tuner_tune()` 固定到 100 MHz |
| 3 | `sddc_rx()` 是最朴素的同步读 | 单次 `libusb_bulk_transfer(EP 0x81, count*2, timeout 1000ms)`，无环形缓冲、无溢出统计、无重传 |
| 4 | 设备识别依赖固件上报 | `sddc_get_device_list()` 读 `sddc_fx3_get_info()` 的 `hwinfo.model`（`RX888_MK2 = 0x04`）。**老固件不报 model 字段 → 型号识别失败** |
| 5 | `sddc_get_samplerate_range()` 返回 `{8e6, 128e6, 0}` | ADC 8~128 MSPS 无级可变，但原型的 UI 只给了 4/8/16/32/64 MHz 五档 |

> 注意区分：**SDR++ 内置的这份 libsddc 不依赖 CUDA**，它把下变频丢给 SDR++ 自己做；而 OpenWebRX wiki 提到"libsddc 需要 NVIDIA GPU"指的是 fventuri 的**老版** libsddc（r2iq 走 CUDA）。不要把两者混为一谈。

---

## 3. 三条路线对比

| 维度 | A：修复增强原生 `sddc_source` | B：SoapySDDC + `soapy_source` | C：`rx888_stream` 旁路 |
|---|---|---|---|
| 依赖 | 仅 libusb（模块内置） | libusb + fftw3 + **SoapySDR** | libusb + librx888 |
| 现在就能跑 | ❌ 需改代码 | ✅ 半天 | ✅ 半天 |
| RF 前端控制 | 需自行开发（可做到最细） | ✅ 已有 `RF`/`IF` 增益、`HF`/`VHF` 天线 | ⚠️ 仅 CLI 参数 |
| 采样率/带宽 | 8~128 MSPS 连续 | 由 `adc_frequency / 64` 派生的离散档 | 任意（自行指定） |
| 交互调谐 | ✅ 实时 | ✅ 实时 | ❌ 需先定中心频率（走 FIFO/file_source） |
| CPU | 轻（下变频在 SDR++） | 重（Core 的 r2iq + FFTW 在插件里跑） | 中（`rx888_dsp` 分担） |
| 稳定性 | 可控（自己写流） | Linux 下**偶发崩溃**（OpenWebRX wiki 明确记录） | 最稳 |
| 适合场景 | 长期主力、要精细控制 | 快速见效、对照基准、GQRX/SDRangel 通用 | WebSDR、无人值守、录制、链路自证 |
| 工作量 | 3~5 天 | 0.5~1 天 | 0.5 天 |

**建议：B 先做（拿到可用基准）→ A 跟上（长期主力）→ C 全程作为"底层是否健康"的裁判工具。**

---

## 4. 实施方案

### 阶段 0 · 环境与权限就绪（约半天）

```bash
# 1) 依赖（发行版包名略有差异，libvolk 在部分版本叫 libvolk2-dev）
sudo apt install -y build-essential cmake git pkg-config \
  libusb-1.0-0-dev libfftw3-dev libsoapysdr-dev soapysdr-tools \
  libvolk-dev libglfw3-dev libzstd-dev portaudio19-dev

# 2) 关键：放大 USBFS 缓冲（默认仅 16 MB，是"丢样本/NO_MEM"的头号原因）
sudo sh -c 'echo 1000 > /sys/module/usbcore/parameters/usbfs_memory_mb'

# 2b) 持久化（注意：Ubuntu 上 usbcore 编入内核，/etc/modprobe.d 无效，用 tmpfiles.d）
echo 'w /sys/module/usbcore/parameters/usbfs_memory_mb - - - - 1000' | sudo tee /usr/lib/tmpfiles.d/rx888.conf
sudo systemd-tmpfiles --create /usr/lib/tmpfiles.d/rx888.conf

# 3) udev 权限：两条 USB ID 都要（bootloader + 运行态）
sudo tee /etc/udev/rules.d/99-sddc.rules >/dev/null <<'EOF'
SUBSYSTEM=="usb",ENV{DEVTYPE}=="usb_device",ATTRS{idVendor}=="04b4",ATTRS{idProduct}=="00f1",MODE:="0666"
SUBSYSTEM=="usb",ENV{DEVTYPE}=="usb_device",ATTRS{idVendor}=="04b4",ATTRS{idProduct}=="00f3",MODE:="0666"
EOF
sudo udevadm control --reload-rules && sudo udevadm trigger

# 4) 确认真的挂在 USB 3.0 上（不是 USB2 口/劣质 Hub/劣质线）
lsusb -t                 # 该设备所在端口应显示 5000M
cat /sys/bus/usb/devices/*/speed
```

**验收**：`lsusb` 能看到 `04b4:00f3` 或 `04b4:00f1`；`usbfs_memory_mb` 读回 1000。

> 若只能在 USB 2.0 下工作（例如虚拟机/老旧主板），RX888 的原始数据率远超 USB 2.0 带宽，**样本会被静默丢弃**——不会报错，只会"看起来在收但频谱全是糊的"。

### 阶段 1 · 底层链路自证（约 1 天）

先不要碰 SDR，用 CLI 工具确认"USB + 固件 + 数据"三件事都正常。

```bash
# 固件来源（三选一，注意差异）
#  a) 官方主仓（推荐：含 VHF、固件上报 model）
git clone https://github.com/ik1xpv/ExtIO_sddc.git      # 根目录 SDDC_FX3.img
#  b) fventuri/libsddc/firmware/                          # 老版本，GPLv3
#  c) ringof/rx888-firmware（MIT，mk2 专用，FIRMWARE_VER_MINOR=6）
#     ⚠️ 该固件"只驱动 HF 直采"，R828D 驱动被移除（GPL 与专有 SDK 许可冲突），
#        需要 VHF/UHF 就不要用它

# 构建并试跑 CLI 流（rx888_tools 路线）
git clone https://github.com/ringof/rx888_tools.git && cd rx888_tools
make firmware && sudo make install
rx888_stream -f firmware/SDDC_FX3.img -s 135000000 | rx888_dsp --block-on-full | iqrecord /tmp/cap --freq 7100000
# 诊断/恢复用：fx3_cmd（发送单条厂商命令并报 PASS/FAIL）
```

**验收清单**
- [ ] `rx888_stream` 能上传固件，设备从 `04b4:00f3` 重新枚举为 `04b4:00f1`
- [ ] 接天线能看到真实信号（FM 广播 / 授时台 / 短波台）
- [ ] 接 50 Ω 负载时底噪平坦，无梳状/镜像异常
- [ ] 控制台**无 overflow / continuity error** 提示
- [ ] 拔插与重复启停 10 次，均能正常枚举（FX3 偶发不枚举 bootloader 是已知硬件问题，需物理重插）

### 阶段 2 · 路线 B：SoapySDDC + SDR++（约半天）

```bash
git clone https://github.com/ik1xpv/ExtIO_sddc.git && cd ExtIO_sddc
cmake -B build -DCMAKE_INSTALL_PREFIX=/usr
cmake --build build -j$(nproc)
sudo make -C build install

# 让 SoapySDR 找到插件（路径按实际输出的 modules0.8/modules0.7 调整）
export SOAPY_SDR_PLUGIN_PATH=/usr/lib/x86_64-linux-gnu/SoapySDR/modules0.8
SoapySDRUtil --info
SoapySDRUtil --probe="driver=sddc"
```

在 SDR++ 中：**Source → SoapySDR**，设备参数填 `driver=sddc`。

SoapySDDC 暴露出的可控项（来自其 `Settings.cpp` / `SoapySDDC.hpp`）：
- 增益元素：`RF`（对应 R82XX 衰减）、`IF`（对应 VGA）
- 天线：`HF`、`VHF`
- 设备设置项：`UpdBiasT_HF`、`UpdBiasT_VHF`、`adc_frequency`（默认 `128000000` 或 `64000000`，范围 `MIN_ADC_FREQ`~`MAX_ADC_FREQ`）
- 调谐范围：10 kHz ~ 1.8 GHz
- 采样率为 `computeSampleRateFromIndex()` 从 ADC 频率派生（`bwmin = adcnominalfreq / 64`，含奈奎斯特校验），**不是任意值**

**已知问题**（要提前接受）：Linux 下 SoapySDDC "仍相当有 bug，偶发崩溃"（OpenWebRX wiki 原文）；纯 CPU 做 r2iq，嵌入式设备（树莓派等）算力不足；默认 16 个缓冲、`sampleRate` 默认 32 MSPS。

> ⚠️ 不要用发行版仓库里的 `sdrpp` 包——SDR++ 作者明确提示该包不完整且与官方模块不兼容。

**验收**：SDR++ 中频谱可见、能解调 FM/AM；增益拖动有实际效果；切 HF/VHF 天线可收到对应频段。

### 阶段 3 · 路线 A：修复并增强原生 `sddc_source`（约 3~5 天）

这是本次适配的主体工程。按"先能启动 → 再能控 → 再稳定"排序：

| 序 | 文件 | 改动 | 验证方式 |
|---|---|---|---|
| 3.1 | 根 `CMakeLists.txt` | 在 `option()` 区补 `option(OPT_BUILD_SDDC_SOURCE "Build SDDC source" OFF)`；或直接 `cmake -DOPT_BUILD_SDDC_SOURCE=ON` | 配置阶段不再跳过 `add_subdirectory` |
| 3.2 | 模块 `CMakeLists.txt` | 若链接报 volk 未定义，补 `target_link_libraries(sddc_source PRIVATE volk)`；确认 `add_subdirectory("./libsddc")` 生效 | `sddc_source.so` 生成成功 |
| 3.3 | `main.cpp` 构造 | 删除硬编码 Windows 固件路径，改为：配置项 `firmwarePath` → 默认搜索路径（`/usr/share/sddc/SDDC_FX3.img`、`$XDG_DATA_HOME/sddc/`、程序同目录）→ 都找不到时在 UI 弹**文件选择 + 明确错误提示** | 换机器后无需改代码即可加载 |
| 3.4 | `refresh()` | 恢复 `sddc_get_device_list()` / `sddc_free_device_list()`；列表显示"型号[序列号] fw x.y"，型号映射 `SDDC_MODEL_RX888_MK2 = 0x04` | 拔插设备后 `Refresh` 能正确刷新 |
| 3.5 | 采样率 | 用 `sddc_get_samplerate_range()`（8~128 MSPS）动态生成档位，UI 明确标注"ADC 速率 / 输出 IQ 速率 = 一半" | 切档后频谱带宽随之变化且不崩 |
| 3.6 | **增益** | 扩展 `libsddc` 公共 API：新增 `sddc_set_rf_att()` / `sddc_set_if_gain()` / `sddc_set_vhf_gain()`，内部包 `sddc_fx3_set_param()`；在 `menuHandler()` 加滑块。**HF 与 VHF 增益语义不同，需按当前端口切换量程** | 拖动滑块，频谱底噪/信号强度实时变化 |
| 3.7 | **端口与调谐器** | 暴露 `SEL0/SEL1/VHF_EN` 三态选择（HF1/HF2/VHF）；VHF 模式下调用 `sddc_set_tuner_frequency()`，并在 DDC 上叠加中频偏移（ExtIO_sddc 把 tuner IF 中心定在 **4.570 MHz**） | VHF 段能收到航空波段（118~137 MHz） |
| 3.8 | 采样率切换时序 | 改为 `stop() → sddc_set_samplerate() → start()`；运行中改 ADC 速率不可靠 | 连续切档 20 次无死锁 |
| 3.9 | **USB 流健壮性** | 用 libusb **异步传输池**（参考 ExtIO_sddc `FX3handler` 的 16 缓冲做法）替换单次同步 bulk transfer；缓冲改为按 USB transfer 粒度而非 `sampleRate/100`；加 overflow/underflow 计数并在 UI 显示 | 64 MHz 连续跑 1 h，计数为 0 |
| 3.10 | 线程 | worker 线程提优先级 / 绑核；音频与 DSP 线程分离 | CPU 占用下降、无周期性爆音 |
| 3.11 | 杂项开关 | Dither、Randomizer、Bias-T（HF/VHF）、外部 27 MHz 参考选择 | UI 可切换 |
| 3.12 | 校准 | 若固件支持，暴露 ppm 修正 | 对标准频率台，误差 < 1 ppm |

**上游协作建议**：3.1~3.5 属于明显的 bug 修复，建议先在 SDR++ 仓库开 issue/PR 沟通（模块自 2025-04 起未再更新，长期无人维护）；3.6~3.9 属于功能扩展，适合先以 fork 形式落地再谈合并。

### 阶段 4 · 验收与固化（约 1 天）

**测试矩阵**：`采样率(8/16/32/64/128 MSPS) × 端口(HF1/HF2/VHF) × 增益(最小/中/最大) × 运行时长(10 min / 1 h / 8 h)`

| 指标 | 目标 | 工具 |
|---|---|---|
| 丢样本率 | 0（长稳期内计数不增长） | 自建计数器 / `rx888_tools` 的 `make hw-check` |
| 底噪 | 50 Ω 负载下平坦，边缘不翘 | SDR++ waterfall |
| 频率准确度 | 对标准频率台 < 1 ppm | 对照已知频率 |
| CPU | 64 MSPS 下可用（记录基线值） | `top` / `htop` / `perf` |
| 内存 | 8 h 无增长（无泄漏） | `/proc/<pid>/status` VmRSS |
| USB | 带宽占用与理论值相符，无 reset | `usbtop` / `dmesg` |
| 温度 | LTC2208 满速连续 8 h 稳定（该芯片发热大，需散热处理） | 红外/贴片测温 |

**交付物**：一份可复现的构建脚本（含 udev/usbfs/tmpfiles 配置）、一份"症状 → 原因 → 处置"排障表、以及 fork 的 patch 说明。

### 备选路线 C · `rx888_stream` 旁路（应急，约半天）

```bash
mkfifo /tmp/iq.fifo
rx888_stream -f SDDC_FX3.img -s 135000000 | rx888_dsp -o /tmp/iq.fifo
# SDR++ 用 File source / Network source 指向该 FIFO；GQRX 亦可读 FIFO
# WebSDR 场景：PhantomSDR / PhantomSDR-Plus / FernSDR（Fern-RX888 模块，2026-09 仍在更新）
```
优点：链路最稳、可 UDP 化远程、CPU 由 `rx888_dsp` 分担。缺点：**无实时交互调谐**（中心频率需预先确定）。

---

## 5. 风险与对策

| 风险 | 症状 | 对策 |
|---|---|---|
| USB 2.0 / 劣质线缆或 Hub | 有流但全是噪声、样本静默丢失 | `lsusb -t` 确认 5000M；换线换口；避免经 Hub |
| `usbfs_memory_mb` 太小 | `LIBUSB_ERROR_NO_MEM`、启动即崩 | 提到 256~1000 MB 并持久化 |
| 固件与主机库厂商命令不匹配 | 有数据流但**设备完全不响应控制**、型号识别错误 | 用 `fx3_cmd` / `sddc_info` 打印实际 `hwinfo`；固定固件与库的版本组合并写进文档 |
| FX3 上电偶发不枚举 bootloader | `lsusb` 看不到设备 | 物理重插（已知问题，非软件可解） |
| 山寨 RX888 | 性能异常、支持缺失 | 官方产品页有真伪识别指引 |
| LTC2208 发热 | 长时间满速后丢样本/掉线 | 加散热；降低采样率或加间歇 |
| SoapySDDC 在 Linux 偶发崩溃 | SDR++ 无预警退出 | 接受现状；关键场景走路线 A/C |
| 模块长期无人维护 | patch 难以被上游合并 | 先沟通 issue；准备好长期维护 fork 的心理预期 |
| 许可证 | 再分发风险 | ExtIO_sddc 为混合许可（Core/SoapySDDC 与固件部分不同）；`ringof/rx888-firmware` 为 MIT 但**移除了 R828D 驱动**；自用无碍，对外分发前需逐文件审阅 |

---

## 6. 关键命令速查

```bash
# 环境
sudo sh -c 'echo 1000 > /sys/module/usbcore/parameters/usbfs_memory_mb'
lsusb -t ; lsusb | grep -i 04b4

# Soapy 链路自检
export SOAPY_SDR_PLUGIN_PATH=<SoapySDR modules 目录>
SoapySDRUtil --probe="driver=sddc"

# 原生 CLI 链路
rx888_stream -f SDDC_FX3.img -s 135000000 | rx888_dsp --block-on-full | iqrecord /tmp/cap --freq 7100000
fx3_cmd                       # 单条厂商命令诊断/恢复

# SDR++ 构建（含原生 SDDC 模块）
git clone https://github.com/AlexandreRouma/SDRPlusPlus.git && cd SDRPlusPlus
mkdir build && cd build
cmake .. -DOPT_BUILD_SDDC_SOURCE=ON -DCMAKE_BUILD_TYPE=Release
make -j$(nproc)
```

---

## 7. 参考仓库

| 仓库 | 用途 |
|---|---|
| `ik1xpv/ExtIO_sddc` | 官方主线：Core + SoapySDDC + 固件源码 |
| `renardspark/SDDC_Driver` | Core 重写版，Linux/macOS 友好，附 `sddc-cli` |
| `fventuri/libsddc` | 老 Linux 库（GPLv3），部分发行版仍有打包 |
| `AlexandreRouma/SDRPlusPlus` → `source_modules/sddc_source` | SDR++ 原生模块（待修复） |
| `rhgndf/rx888_stream`、`ringof/rx888_tools`、`ringof/rx888-firmware` | CLI 流式链路 + mk2 专用固件（MIT） |
| `PhantomSDR/PhantomSDR`、`Steven9101/PhantomSDR-Plus`、`Steven9101/Fern-RX888` | WebSDR / 旁路应用 |
| `ka9q/ka9q-radio` | 原生支持 RX888 的 SDR 守护进程 |
| `jketterl/openwebrx` wiki「SDDC device notes」 | Linux 下 SDDC 支持的实践记录（含已知坑） |

---

## 附录 A：本机实测结论（2026-10-01，已从"推测"升级为"确证"）

在本机（Ubuntu 26.04 / GCC 15.2 / 内核 7.0.0 / x86_64）克隆 SDR++ 上游 `master`（commit `8c9f5ee`，2026-07-04）并实机编译后，第 2 章的判断全部得到验证，并新增两条**上游仓库的硬缺陷**：

### A.1 新增确证的阻塞项

| # | 位置 | 实测现象 | 严重度 |
|---|---|---|---|
| A-1 | `source_modules/sddc_source/libsddc/CMakeLists.txt:58` | `configure_file(${CMAKE_SOURCE_DIR}/libsddc.pc.in ...)` —— **`libsddc.pc.in` 文件在整个仓库中不存在**（`find` 全库无结果）；且 `${CMAKE_SOURCE_DIR}` 在作为子目录构建时指向 SDR++ 根目录。后果：`cmake` 配置阶段直接 `CMake Error`，**这会让整份 SDR++ 的 configure 失败**，不只是这个模块编不出来 | 阻断级 |
| A-2 | `libsddc/src/sddc.c:448`、`usb_interface.c`（13 处 `libusb_control_transfer`）、`fx3_boot.c:13` | 隐式指针转换（`int16_t*`/`uint32_t*`/`const uint8_t*` → `unsigned char*`）。GCC 14+ 起 C23 为默认标准，此类转换**由警告升为硬错误** | 阻断级 |
| A-3 | `libsddc/src/fx3_boot.c` | 用了 `malloc`/`realloc` 但**未 `#include <stdlib.h>`**；`sddc.c` 用了 `strlen`/`strcpy`/`strcmp`/`usleep` 却**未包含 `<string.h>`/`<unistd.h>`** → C23 下隐式函数声明同样是硬错误 | 阻断级 |
| A-4 | `libsddc/src/sddc.c:355` | `sddc_gpio_set()` 声明返回 `int` 但**函数体没有 `return`** → 返回值未定义 | 真实 bug |
| A-5 | `libsddc/src/fx3_boot.c:86` | `realloc(buffer, size)` **丢弃返回值** → 缓冲区根本没被扩容，随后 `fread` 会越界写入大于 64 KB 的固件段。另外成功路径**漏了 `free(buffer)`** | 真实 bug（内存越界） |
| A-6 | `libsddc/utils/sddc_info/src/main.cpp` | 与模块同一处硬编码：`sddc_set_firmware_path("C:/Users/ryzerth/Downloads/SDDC_FX3 (1).img")` | 阻断级（工具不可用） |
| A-7 | `libsddc/src/sddc.c:314` | `sddc_gpio_put()` 在定义之前被调用，缺少前置声明 → C23 报 implicit declaration 且与真实原型冲突 | 阻断级 |

### A.2 实机验证结果

| 验证项 | 结果 |
|---|---|
| 设备枚举 | ✅ `sddc_info` 成功识别出 Cypress FX3 设备并进入固件上传流程，日志：`Found uninitialized device, initializing...` |
| 设备打开 | ❌ `Failed to open device: -3` → `LIBUSB_ERROR_ACCESS`，原因是设备节点为 `root:root crw-rw-r--`，当前用户只有读权限。**证明只差一条 udev 规则** |
| 修复后编译 | ✅ `libsddc.so` + `sddc_info` + `sddc_rx` 全部编译成功（修复 A-1~A-3、A-6、A-7 之后） |
| 总线速率 | ❌ **设备当前挂在 USB 2.0 总线（480 Mbps）上**。本机 USB 3.x 端口在 Bus 002（20000M/x2，4 口）与 Bus 004（20000M/x2，2 口），而设备在 Bus 003（480M，12 口的 USB 2.0 控制器）。RX888 MkII 满速需约 2048 Mbps，**该端口下无法正常工作**，必须先换端口（物理动作） |
| `usbfs_memory_mb` | ⚠️ 当前为默认 `16` MB，需提升 |

### A.3 结论修正

原第 2 章的判断"直接 clone 编译会失败"得到确认，且失败点比预想更靠前：**不是模块编不出来，而是 `-DOPT_BUILD_SDDC_SOURCE=ON` 会让整个 SDR++ 的 CMake 配置阶段中止**。因此修复顺序应调整为：

1. 先补 `libsddc.pc.in` + 修正 `CMAKE_CURRENT_SOURCE_DIR`（否则什么都编不了）
2. 再修 C23 兼容性（缺头文件 + 显式指针转换）
3. 然后才是模块级的固件路径 / 设备枚举修复
4. 最后才是增益、端口、调谐器、异步 USB 流等功能增强

### A.4 已在下游修复的部分

本机工作副本（`/home/tsw/sdr/SDRPlusPlus`）已完成 A-1~A-7 的修复，改动带 `FIXED:` 注释便于识别与上游提交；同时把 `sddc_source` 的固件路径改为"配置项 → `$SDDC_FIRMWARE` → 常见路径搜索"三级回退，并恢复了设备枚举。**尚未编译验证模块本身**（受限于 `fftw3f`/`glfw3`/`volk`/`libzstd` 等 dev 包需 root 安装）。
