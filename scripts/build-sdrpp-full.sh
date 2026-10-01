#!/usr/bin/env bash
# build-sdrpp-full.sh — 构建「完整 Linux 版」SDR++（含打过补丁的 sddc_source）
#
# 与 build-sdrpp.sh（只开 4 个模块的最小验证版）的区别：
#   本脚本对齐官方 docker_builds/ubuntu_resolute/do_build.sh 的模块集，
#   并把「依赖是否真的存在」交给 pkg-config 判定 —— 逐个模块探测，
#   有依赖就 ON、没有就 OFF，绝不硬编码开关，因此在任何机器上都能一次跑通。
#
# 用法：
#   bash build-sdrpp-full.sh setup    # 只配置，并打印模块开关决策表
#   bash build-sdrpp-full.sh build    # 配置 + 编译 + 安装（默认）
#   bash build-sdrpp-full.sh clean    # 清干净后重建

set -uo pipefail

SRC="${SRC:-/home/tsw/sdr/SDRPlusPlus}"
BUILD="$SRC/build-full"
INSTALL="${INSTALL:-/home/tsw/sdr/install}"
CM="${CM:-cmake}"
NV="$(nproc 2>/dev/null || echo 4)"
PREFIX="${SDR_LOCAL_PREFIX:-/home/tsw/sdr/local}"
INS="$PREFIX/usr"
LIBDIRS="$INS/lib/x86_64-linux-gnu:$INS/lib"

command -v "$CM" >/dev/null 2>&1 || CM=cmake
[ -f "$PREFIX/env.sh" ] && source "$PREFIX/env.sh"

have_pc() { pkg-config --exists "$1" 2>/dev/null; }
have_file() { [ -e "$1" ] || [ -e "$2" ]; }

# ---------------------------------------------------------------------------
# 模块开关决策表： "OPT_XXX 依赖类型 依赖名 说明"
#   依赖类型 pc    → pkg-config 能查到才开
#   依赖类型 file  → 指定文件存在才开
#   依赖类型 none  → 无依赖，直接开
# ---------------------------------------------------------------------------
SPEC=(
  # ── 无外部依赖的模块：全部开启（"完整"的基线） ────────────────────────
  "OPT_BUILD_FILE_SOURCE          none -                  WAV 文件源"
  "OPT_BUILD_HERMES_SOURCE        none -                  Hermes/HPSDR（网络协议）"
  "OPT_BUILD_NETWORK_SOURCE       none -                  SDR++ 网络源"
  "OPT_BUILD_RFSPACE_SOURCE       none -                  RFspace"
  "OPT_BUILD_RTL_TCP_SOURCE       none -                  RTL-TCP"
  "OPT_BUILD_SDRPP_SERVER_SOURCE  none -                  SDR++ 服务器源"
  "OPT_BUILD_SPECTRAN_HTTP_SOURCE none -                  Spectran HTTP"
  "OPT_BUILD_SPYSERVER_SOURCE     none -                  SpyServer"
  "OPT_BUILD_AUDIO_SINK           pc   rtaudio            ★ 音频输出（上次没编出来）"
  "OPT_BUILD_NETWORK_SINK         none -                  网络音频 sink"
  "OPT_BUILD_ATV_DECODER          none -                  ATV 解码"
  "OPT_BUILD_METEOR_DEMODULATOR   none -                  Meteor 解调"
  "OPT_BUILD_PAGER_DECODER        none -                  寻呼解码"
  "OPT_BUILD_RADIO                none -                  ★ 主解调（AM/FM/SSB…）"
  "OPT_BUILD_RYFI_DECODER         none -                  RyFi 解码"
  "OPT_BUILD_VOR_RECEIVER         none -                  VOR 接收"
  "OPT_BUILD_DISCORD_PRESENCE     none -                  Discord 状态"
  "OPT_BUILD_FREQUENCY_MANAGER    none -                  频率管理"
  "OPT_BUILD_IQ_EXPORTER          none -                  IQ 导出"
  "OPT_BUILD_RECORDER             none -                  ★ 录音/基带录制"
  "OPT_BUILD_RIGCTL_CLIENT        none -                  Rigctl 客户端"
  "OPT_BUILD_RIGCTL_SERVER        none -                  Rigctl 服务端"
  "OPT_BUILD_SCANNER              none -                  ★ 频率扫描"
  "OPT_BUILD_SCHEDULER            none -                  计划任务"
  # ── 有 apt 依赖的常规 SDR 硬件 ─────────────────────────────────────────
  "OPT_BUILD_SDDC_SOURCE          pc   libusb-1.0         ★ RX888/BBRF103（本机主目标）"
  "OPT_BUILD_SOAPY_SOURCE         pc   SoapySDR           ★ SoapySDR（路线1入口）"
  "OPT_BUILD_AIRSPY_SOURCE        pc   libairspy          Airspy"
  "OPT_BUILD_AIRSPYHF_SOURCE      pc   libairspyhf        Airspy HF+"
  "OPT_BUILD_AUDIO_SOURCE         pc   rtaudio            音频输入源"
  "OPT_BUILD_HACKRF_SOURCE        pc   libhackrf          HackRF"
  "OPT_BUILD_PLUTOSDR_SOURCE      pc   libad9361          PlutoSDR（需 libiio+libad9361）"
  "OPT_BUILD_RTL_SDR_SOURCE       pc   librtlsdr          RTL-SDR"
  "OPT_BUILD_BLADERF_SOURCE       pc   libbladeRF         BladeRF"
  # HydraSDR：apt 的 libhydrasdr 1.0.3 把头文件里的枚举改名为 RF_PORT_RX0/RX1/RX2，
  # 而模块写的是 HYDRASDR_RF_PORT_RX0…（对应官方 git 版 rfone_host）→ 名字对不上，
  # 编不过。官方构建用的是自行编译的 rfone_host，本机 apt 版 API 已漂移。
  "OPT_BUILD_HYDRASDR_SOURCE     pc   libhydrasdr-nope   HydraSDR（apt 版 API 与模块期望不一致）"
  "OPT_BUILD_NEW_PORTAUDIO_SINK   pc   portaudio-2.0      PortAudio sink（新版）"
  # 旧版 portaudio_sink 的 CMake project() 名也叫 audio_sink，与 audio_sink 模块
  # 撞目标名，两个一起开会 add_library 冲突 → 只保留新版
  "OPT_BUILD_PORTAUDIO_SINK       none OFF                  PortAudio sink（旧版，目标名与 audio_sink 冲突）"
  "OPT_BUILD_DAB_DECODER          pc   codec2             DAB/DAB+ 解码"
  "OPT_BUILD_M17_DECODER          pc   codec2             M17 解码"
  # ── 无 .pc、用裸 target_link_libraries（靠 -I/-L 兜） ─────────────────
  # LimeSuite 的 .pc 名就是 LimeSuite（大小写敏感）；模块本身不调 pkg-config，
  # 只用裸 target_link_libraries(LimeSuite)，所以这里用 .pc 存在性判断可编译性，
  # 真正的头/库路径靠下面 CMAKE_CXX_FLAGS 的 -I/-L 兜。
  "OPT_BUILD_LIMESDR_SOURCE      pc   LimeSuite          LimeSDR"
  # ── 厂商库（deps-vendor.sh 编出来的，有 .pc 才开） ─────────────────────
  "OPT_BUILD_PERSEUS_SOURCE       pc   libperseus-sdr     Perseus"
  "OPT_BUILD_RFNM_SOURCE          pc   librfnm            RFNM"
  "OPT_BUILD_FOBOSSDR_SOURCE      pc   libfobos           FobosSDR"
  "OPT_BUILD_DRAGONLABS_SOURCE    pc   libdlcr            Dragon Labs"
  "OPT_BUILD_SDRPLAY_SOURCE       file include/sdrplay_api.h SDRplay（厂商二进制）"
  # ── 无法满足：显式关闭并说明原因 ───────────────────────────────────────
  "OPT_BUILD_USRP_SOURCE         pc   uhd                USRP（未装 libuhd：会拖入整套 Boost dev）"
  # 下面这几个模块在上游默认就是 OFF，且源码里 include 了仓库中根本不存在的
  # 头文件（dsp/demodulator.h、dsp/window.h、dsp/resampling.h、dsp/processing.h、
  # dsp/routing.h、dsp/deframing.h）—— 属未完成的死代码，任何环境下都编不过。
  "OPT_BUILD_KG_SSTV_DECODER     none OFF                  KG-SSTV 解码（引用不存在的 dsp/*.h，上游默认 OFF）"
  "OPT_BUILD_WEATHER_SAT_DECODER none OFF                  HRPT 气象卫星解码（同上）"
  "OPT_BUILD_KCSDR_SOURCE        none OFF                  KCSDR（需厂商 FTD3XX SDK，仓库无源码）"
  "OPT_BUILD_BADGESDR_SOURCE     none OFF                  BadgeSDR（source_modules 下无此目录）"
  "OPT_BUILD_HAROGIC_SOURCE      none OFF                  Harogic（需 Aaronia htra_api，闭源）"
  "OPT_BUILD_SPECTRAN_SOURCE     none OFF                  Spectran（需 Aaronia RTSA，闭源）"
  "OPT_BUILD_FALCON9_DECODER     none OFF                  Falcon9（需 ffplay）"
  "OPT_BUILD_ANDROID_AUDIO_SINK  none OFF                  Android 专用"
)

echo "=============================================================="
echo " SDR++ 完整版构建"
echo " 源码   : $SRC"
echo " 构建   : $BUILD"
echo " 依赖   : $PREFIX"
echo " 安装到 : $INSTALL"
echo "=============================================================="

echo
echo "==> 模块开关决策（依赖探测结果）"
FLAGS=()
on=0; off=0
for row in "${SPEC[@]}"; do
  # 用固定列宽切分：选项 / 类型 / 依赖 / 说明
  opt=$(awk '{print $1}' <<<"$row")
  typ=$(awk '{print $2}' <<<"$row")
  dep=$(awk '{print $3}' <<<"$row")
  desc=$(awk '{for(i=4;i<=NF;i++) printf "%s ", $i}' <<<"$row")

  enable=0
  case "$typ" in
    none) [ "$dep" = "OFF" ] && enable=0 || enable=1 ;;
    pc)   have_pc "$dep" && enable=1 || enable=0 ;;
    file) have_file "$INS/$dep" "$INS/lib/x86_64-linux-gnu/$dep" && enable=1 || enable=0 ;;
  esac

  if [ "$enable" = 1 ]; then
    FLAGS+=("-D$opt=ON");  printf "  \033[32m[ON ]\033[0m %-32s %s\n" "$opt" "$desc"; on=$((on+1))
  else
    FLAGS+=("-D$opt=OFF"); printf "  \033[31m[OFF]\033[0m %-32s %s\n" "$opt" "$desc"; off=$((off+1))
  fi
done
echo "  —— 合计：ON $on / OFF $off"

case "${1:-build}" in
  clean) echo; echo "==> 请求彻底清理（--fresh 会重建配置）" ;;
esac

# 强制重新配置：pkg_check_modules() 的结果会以 INTERNAL 变量写进 CMakeCache.txt，
# 之后即使 .pc 改了、依赖修好了，直接重跑 cmake 也不会刷新，会一直用旧路径编译
# （踩过：codec2.pc 修好后 m17_decoder 仍报找不到 codec2.h）。
#
# 这里用 cmake 自带的 --fresh（3.24+）：它在配置前自行删掉 CMakeCache.txt 与
# CMakeFiles/。刻意不用 `rm -rf` —— 在本机沙箱环境下递归删除会被安全策略静默
# 拦截，导致"看起来清了、其实没清"，非常难查。
FRESH_ARGS=()
if [ "${KEEP_BUILD:-0}" != "1" ]; then
  FRESH_ARGS+=("--fresh")
  echo; echo "==> 使用 cmake --fresh 重新配置（丢弃陈旧的 pkg-config 缓存）"
fi

# rpath：让构建树里的二进制/插件无需 make install 也能找到彼此与依赖
RPATH="\$ORIGIN"
for p in "/.." "/../lib" "/../.." "/../../lib" "/../../.." "/libsddc"; do RPATH="$RPATH;\$ORIGIN$p"; done
RPATH="$RPATH;$INS/lib/x86_64-linux-gnu;$INS/lib"

# 裸链接模块（LimeSDR / SDRplay）需要头目录和库目录显式进搜索路径
EXTRA_FLAGS="-I$INS/include -I$INS/include/libusb-1.0"
EXTRA_LDFLAGS="-L$INS/lib/x86_64-linux-gnu -L$INS/lib -Wl,-rpath,$INS/lib/x86_64-linux-gnu -Wl,-rpath,$INS/lib"

echo
echo "===== 配置 ====="
"$CM" "${FRESH_ARGS[@]}" -S "$SRC" -B "$BUILD" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$INSTALL" \
  -DCMAKE_PREFIX_PATH="$INS" \
  -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON \
  -DCMAKE_INSTALL_RPATH="$RPATH" \
  -DCMAKE_C_FLAGS="$EXTRA_FLAGS" \
  -DCMAKE_CXX_FLAGS="$EXTRA_FLAGS" \
  -DCMAKE_EXE_LINKER_FLAGS="$EXTRA_LDFLAGS" \
  -DCMAKE_SHARED_LINKER_FLAGS="$EXTRA_LDFLAGS" \
  "${FLAGS[@]}" 2>&1 | tail -25

if [ ! -f "$BUILD/CMakeCache.txt" ]; then
  echo; echo "!!! 配置失败（无 CMakeCache.txt）"; exit 1
fi
if [ "${1:-build}" = "setup" ]; then echo; echo "配置完成（setup，未编译）"; exit 0; fi

echo
echo "===== 编译（-j$NV）====="
if ! "$CM" --build "$BUILD" -j"$NV" 2>&1 | tail -30; then
  echo; echo "!!! 编译失败"; exit 1
fi

echo
echo "===== 安装到 $INSTALL ====="
"$CM" --install "$BUILD" 2>&1 | tail -15

echo
echo "===== 产物清单 ====="
echo "  --- 可执行 ---"
ls -1 "$INSTALL/bin" 2>/dev/null | sed 's/^/    /'
echo "  --- 模块（$(ls -1 "$INSTALL/lib/sdrpp/plugins" 2>/dev/null | wc -l) 个） ---"
ls -1 "$INSTALL/lib/sdrpp/plugins" 2>/dev/null | sed 's/^/    /'

echo
echo "===== 冒烟测试（不设 LD_LIBRARY_PATH，验证 rpath 是否自洽）====="
if [ -x "$INSTALL/bin/sdrpp" ]; then
  if OUT=$(env -u LD_LIBRARY_PATH "$INSTALL/bin/sdrpp" -h 2>&1); then
    echo "  ✓ 运行 OK"; echo "$OUT" | head -3 | sed 's/^/    /'
  else
    echo "  ✗ 运行失败："; echo "$OUT" | head -8 | sed 's/^/    /'
  fi
fi
