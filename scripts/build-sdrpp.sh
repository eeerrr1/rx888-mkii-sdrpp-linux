#!/usr/bin/env bash
# build-sdrpp.sh — 使用本地依赖前缀构建打过补丁的 SDR++（含 sddc_source）
#
# 无需 root。依赖来自 /home/tsw/sdr/local（由 deps-local.sh 部署）。
#
# 用法：
#   bash build-sdrpp.sh setup     # 只配置
#   bash build-sdrpp.sh build     # 配置 + 编译
#   bash build-sdrpp.sh clean     # 清理后重建

set -uo pipefail

SRC="${SRC:-/home/tsw/sdr/SDRPlusPlus}"
BUILD="$SRC/build"
INSTALL="${INSTALL:-/home/tsw/sdr/install}"
CM="${CM:-/home/tsw/.workbuddy/binaries/python/envs/default/bin/cmake}"
NV="$(nproc 2>/dev/null || echo 4)"
PREFIX="${SDR_LOCAL_PREFIX:-/home/tsw/sdr/local}"

[ -f "$PREFIX/env.sh" ] && source "$PREFIX/env.sh"

# 只编译验证 RX888 所需的模块，其余全部关闭（避免拉入 airspy/rtlsdr/plutosdr/uhd 等
# 一堆未安装的依赖，让配置在无关模块上失败）
WANT="OPT_BUILD_SDDC_SOURCE OPT_BUILD_SOAPY_SOURCE OPT_BUILD_FILE_SOURCE OPT_BUILD_RADIO"

echo "==> 源码:  $SRC"
echo "==> 构建:  $BUILD"
echo "==> cmake: $CM"

if ! [ -x "$CM" ]; then
  echo "找不到 cmake: $CM"
  exit 1
fi

FLAGS=()
while read -r o; do
  case " $WANT " in
    *" $o "*) FLAGS+=("-D$o=ON") ;;
    *)        FLAGS+=("-D$o=OFF") ;;
  esac
done < <(grep -oP '(?<=^option\()OPT_BUILD_[A-Z0-9_]+' "$SRC/CMakeLists.txt")

echo "==> 启用模块: $WANT"
echo "==> 其余 $((${#FLAGS[@]} - 4)) 个模块关闭"

case "${1:-build}" in
  clean) rm -rf "$BUILD" ;;
esac

echo
echo "===== 配置 ====="
# rpath 说明：SDR++ 默认假设你会 make install，构建树里的二进制找不到 libsdrpp_core.so。
# 这里显式把构建树内各层目录和本地依赖前缀都写进 rpath，构建产物即可直接运行：
#   $ORIGIN          构建根（sdrpp 旁边的 libsdrpp_core.so）
#   $ORIGIN/..       模块上一层（source_modules/xxx/*.so 找 libsdrpp_core.so）
#   $ORIGIN/libsddc  sddc_source 自己 add_subdirectory 出来的 libsddc.so
RPATH="\$ORIGIN"
RPATH="$RPATH;\$ORIGIN/.."
RPATH="$RPATH;\$ORIGIN/../lib"
RPATH="$RPATH;\$ORIGIN/../.."
RPATH="$RPATH;\$ORIGIN/../../lib"
RPATH="$RPATH;\$ORIGIN/../../.."
RPATH="$RPATH;\$ORIGIN/libsddc"
RPATH="$RPATH;$PREFIX/usr/lib/x86_64-linux-gnu"

"$CM" -S "$SRC" -B "$BUILD" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$INSTALL" \
  -DCMAKE_PREFIX_PATH="$PREFIX/usr" \
  -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON \
  -DCMAKE_INSTALL_RPATH="$RPATH" \
  "${FLAGS[@]}" 2>&1 | tail -40

if [ ! -f "$BUILD/CMakeCache.txt" ]; then
  echo
  echo "!!! 配置失败，未能生成 CMakeCache.txt"
  exit 1
fi

if [ "${1:-build}" = "setup" ]; then
  echo
  echo "配置完成（setup 模式，未编译）"
  exit 0
fi

echo
echo "===== 编译（-j$NV）====="
"$CM" --build "$BUILD" -j"$NV" 2>&1 | tail -40

echo
echo "===== 产物 ====="
find "$BUILD" -maxdepth 3 -type f \( -name 'sdrpp' -o -name '*.so' \) -printf '%10s  %p\n' 2>/dev/null | head -20

echo
echo "===== 安装到 $INSTALL ====="
"$CM" --install "$BUILD" 2>&1 | tail -30

echo
echo "===== 安装树结构 ====="
for d in bin lib lib/sdrpp/plugins share/sdrpp; do
  printf "  %-20s " "$d/"
  if [ -d "$INSTALL/$d" ]; then
    echo "$(find "$INSTALL/$d" -maxdepth 1 -type f | wc -l) 个文件"
  else
    echo "(不存在)"
  fi
done
echo "  --- 模块 ---"
ls -1 "$INSTALL/lib/sdrpp/plugins" 2>/dev/null | sed 's/^/    /'
echo "  --- 资源 ---"
ls -1 "$INSTALL/share/sdrpp" 2>/dev/null | sed 's/^/    /'

echo
echo "===== 冒烟测试：直接运行已安装的二进制（不设 LD_LIBRARY_PATH）====="
if [ -x "$INSTALL/bin/sdrpp" ]; then
  if OUT=$(env -u LD_LIBRARY_PATH "$INSTALL/bin/sdrpp" -h 2>&1); then
    echo "  运行 OK"
    echo "$OUT" | grep -i "sdr++" | head -2 | sed 's/^/    /'
  else
    echo "  运行失败:"; echo "$OUT" | head -5 | sed 's/^/    /'
  fi
fi
