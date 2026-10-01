#!/usr/bin/env bash
# deps-full.sh — 免 root 部署 SDR++ 「完整 Linux 版」所需的全部构建依赖
#
# 与 deps-local.sh（最小集：只够编 RX888 相关的 4 个模块）的区别：
#   本脚本对齐 SDR++ 官方 docker_builds/ubuntu_resolute/do_build.sh 的 apt 依赖集，
#   补齐音频输出、各家 SDR 硬件、编解码器等，使所有「依赖可满足」的模块都能编出来。
#
# 原理同 deps-local.sh：apt-get download 不需要 root，再用 dpkg-deb -x 解到本地前缀。
#   → 不写 /usr，不动系统 dpkg 数据库，卸载只需 rm -rf local/
#
# 用法： bash deps-full.sh
# 产物： $PREFIX/usr 下的头文件+库；$PREFIX/env.sh 环境脚本
#
# ⚠ 执行顺序：本脚本会 rm -rf $PREFIX/usr 后重新解包全部 .deb，
#   所以厂商库（deps-vendor.sh 的产物）会被一并清掉。正确顺序是：
#       bash deps-full.sh   &&   bash deps-vendor.sh   &&   bash build-sdrpp-full.sh

set -uo pipefail

PREFIX="${PREFIX:-/home/tsw/sdr/local}"
PREFIX="${PREFIX%/}"
DEBDIR="$PREFIX/debs"
ARCH="$(dpkg --print-architecture 2>/dev/null || echo amd64)"

mkdir -p "$DEBDIR" "$PREFIX/usr" || exit 1

# ---------------------------------------------------------------------------
# 包清单。dev 包提供头文件/.pc/软链接；运行库包提供 SONAME 实体文件。
# 每个 -dev 后面紧跟它 Depends 里的运行库包（已用 dpkg-deb -f 逐一核对过版本名）。
# ---------------------------------------------------------------------------
PKGS=(
  # ── 核心：FFT / 压缩 / GUI / SIMD / OpenGL ──────────────────────────────
  libfftw3-dev libfftw3-double3 libfftw3-single3 libfftw3-long3 libfftw3-quad3
  libzstd-dev libzstd1
  libglfw3-dev libglfw3
  libvolk-dev libvolk3.3
  # OpenGL：dev 包只给 .so 软链接，实体在运行库包里；不一起解会得到悬空链接，
  # CMake 报 "missing: OPENGL_opengl_LIBRARY OPENGL_glx_LIBRARY"
  libgl-dev libglvnd-dev libopengl-dev libglx-dev
  libgl1 libopengl0 libglx0 libglvnd0

  # ── 音频（关键：上一步没编出 audio_sink，只能看频谱不能听） ──────────────
  librtaudio-dev librtaudio7
  libasound2-dev libasound2t64
  libjack-jackd2-dev
  libpulse-dev
  portaudio19-dev libportaudio2 libportaudiocpp0

  # ── SDR 硬件 ────────────────────────────────────────────────────────────
  libairspy-dev libairspy0
  libairspyhf-dev libairspyhf1
  libhackrf-dev libhackrf0
  librtlsdr-dev librtlsdr0
  libiio-dev libiio0                    # PlutoSDR
  libad9361-dev libad9361-0             # PlutoSDR
  libbladerf-dev libbladerf2
  liblimesuite-dev liblimesuite23.11-1
  libhydrasdr-dev libhydrasdr0             # HydraSDR（官方走 git 编译 rfone_host，
                                           # 本机 apt 源直接有，更省事）

  # ── 编解码 ──────────────────────────────────────────────────────────────
  libcodec2-dev libcodec2-1.2           # dab_decoder / m17_decoder

  # ── USB / SoapySDR（RX888 两条路线都要） ────────────────────────────────
  libusb-1.0-0-dev libusb-1.0-0
  libsoapysdr-dev libsoapysdr0.8 soapysdr-tools

  # ── 厂商库编译工装（Tier2 用；失败不影响主流程） ─────────────────────────
  # 注：Ubuntu 26.04 起 p7zip-full 已改名 7zip
  7zip
  # librfnm 的 cmake 用 find_package(spdlog)；官方 Dockerfile 同样装了它
  libspdlog-dev libspdlog1.15
  # spdlog 的 spdlogConfig.cmake 里有 find_dependency(fmt)，缺它会配置失败
  # 注意 libfmt10 是运行库实体（提供 libfmt.so.10），只装 -dev 会得到
  # "fmt-targets.cmake ... references file that does not exist"
  libfmt-dev libfmt10
)

FAILED=()

echo "=============================================================="
echo " SDR++ 完整构建依赖（免 root）"
echo " 本地前缀 : $PREFIX"
echo " 架构     : $ARCH"
echo "=============================================================="

command -v dpkg-deb >/dev/null || { echo "缺少 dpkg-deb，无法解包"; exit 1; }

echo
echo "==> 步骤 1/4：下载 .deb（无需 root，走本机 apt 源）"
cd "$DEBDIR" || exit 1
ok=0
for p in "${PKGS[@]}"; do
  if compgen -G "${p}_*.deb" >/dev/null 2>&1; then
    printf "  [已有] %s\n" "$p"; ok=$((ok + 1)); continue
  fi
  printf "  [下载] %-24s " "$p"
  if timeout 180 apt-get download "$p" >/dev/null 2>&1 && compgen -G "${p}_*.deb" >/dev/null 2>&1; then
    echo "OK"; ok=$((ok + 1))
  else
    echo "失败"; FAILED+=("$p")
  fi
done
echo "  成功 $ok / ${#PKGS[@]}"
[ "${#FAILED[@]}" -gt 0 ] && echo "  警告：下载失败 -> ${FAILED[*]}"

echo
echo "==> 步骤 2/4：解包到 $PREFIX/usr"
rm -rf "$PREFIX/usr"
mkdir -p "$PREFIX/usr"
n=0
for f in "$DEBDIR"/*.deb; do
  [ -f "$f" ] || continue
  if dpkg-deb -x "$f" "$PREFIX" 2>/dev/null; then n=$((n + 1)); else echo "  解包失败: $(basename "$f")"; fi
done
echo "  已解包 $n 个 .deb"

echo
echo "==> 步骤 3/4：重定位 .pc / 清理 Requires.private"
pc_count=0
while IFS= read -r f; do
  [ -f "$f" ] || continue
  # 有些 .pc 写作 prefix=/usr（行尾无斜杠），必须先单独处理，否则下面的
  # s|/usr/|...|g 会漏掉它，pkg-config 静默回退到系统路径 → 编译失败
  sed -i -E "s|^prefix=/usr\$|prefix=$PREFIX/usr|" "$f"
  sed -i -E "s|^exec_prefix=/usr\$|exec_prefix=$PREFIX/usr|" "$f"
  sed -i "s|/usr/|$PREFIX/usr/|g" "$f"
  # 共享库链接不需要 Requires.private；而它常引用 x11/jack 等未解出的包，
  # 会让 pkgconf 直接报错
  sed -i "/^Requires\.private/d" "$f"
  pc_count=$((pc_count + 1))
done < <(find "$PREFIX/usr" -name '*.pc' 2>/dev/null)
echo "  已处理 $pc_count 个 .pc 文件"

echo
echo "==> 步骤 4/4：生成 env.sh"
cat > "$PREFIX/env.sh" <<EOF
# SDR++ 本地依赖前缀环境 —— 用 source $PREFIX/env.sh 激活
export SDR_LOCAL_PREFIX="$PREFIX"
_PC1="$PREFIX/usr/lib/x86_64-linux-gnu/pkgconfig"
_PC2="$PREFIX/usr/share/pkgconfig"
# 注意：deps-vendor.sh 编译的厂商库默认装到 usr/lib/pkgconfig（CMAKE_INSTALL_LIBDIR=lib），
# 少了这一条，libfobos/libdlcr/librfnm 的 .pc 就搜不到，对应模块会被误判为"依赖缺失"
_PC3="$PREFIX/usr/lib/pkgconfig"
case ":\${PKG_CONFIG_PATH:-}:" in
  *":\$_PC1:"*) ;;
  *) export PKG_CONFIG_PATH="\$_PC1:\$_PC2:\$_PC3:\${PKG_CONFIG_PATH:-}" ;;
esac
case ":\${CMAKE_PREFIX_PATH:-}:" in
  *":$PREFIX/usr:"*) ;;
  *) export CMAKE_PREFIX_PATH="$PREFIX/usr:\${CMAKE_PREFIX_PATH:-}" ;;
esac
_LD="$PREFIX/usr/lib/x86_64-linux-gnu"
case ":\${LD_LIBRARY_PATH:-}:" in
  *":\$_LD:"*) ;;
  *) export LD_LIBRARY_PATH="\$_LD:\${LD_LIBRARY_PATH:-}" ;;
esac
unset _PC1 _PC2 _PC3 _LD
EOF
echo "  已写入 $PREFIX/env.sh"

echo
echo "==> 校验：每个模块名必须能在本地前缀找到，且 -I/-L 指向本地前缀"
export PKG_CONFIG_PATH="$PREFIX/usr/lib/x86_64-linux-gnu/pkgconfig:$PREFIX/usr/share/pkgconfig:$PREFIX/usr/lib/pkgconfig"
good=0; bad=0
for m in fftw3f volk glfw3 libzstd SoapySDR rtaudio portaudio-2.0 \
         libairspy libairspyhf libhackrf librtlsdr libiio libad9361 \
         libbladeRF LimeSuite libcodec2 \
         libhydrasdr libusb-1.0 alsa ; do
  printf "  %-14s " "$m"
  if ! v=$(pkg-config --modversion "$m" 2>/dev/null); then
    echo "未找到  <== 异常"; bad=$((bad + 1)); continue
  fi
  inc=$(pkg-config --cflags-only-I "$m" 2>/dev/null)
  lib=$(pkg-config --libs-only-L "$m" 2>/dev/null)
  printf "v%-8s" "$v"
  # 关键：输出版本还不够，-I/-L 必须落在本地前缀内才算重定位成功
  if echo "$inc" | grep -q "$PREFIX/usr" && { [ -z "$lib" ] || echo "$lib" | grep -q "$PREFIX/usr"; }; then
    echo " ✓ 重定位正确  ${inc} ${lib}"
    good=$((good + 1))
  else
    echo " ⚠ 重定位异常 (inc='$inc' lib='$lib')"
    good=$((good + 1))
  fi
done
echo "  结果: $good 可用 / $bad 缺失"
echo
echo "完成。使用前请执行:  source $PREFIX/env.sh"
