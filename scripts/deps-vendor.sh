#!/usr/bin/env bash
# deps-vendor.sh — 编译 SDR++ 官方构建里「不在 apt 源」的那几个厂商库到本地前缀
#
# 对应 SDR++ 官方 docker_builds/ubuntu_resolute/do_build.sh 中 git clone / wget 的部分：
#   librfnm        (RFNM)         https://github.com/AlexandreRouma/librfnm      cmake
#   libfobos       (FobosSDR)     https://github.com/AlexandreRouma/libfobos    cmake
#   dlcr_host      (Dragon Labs)  https://dragnlabs.com/host-tools/...zip       cmake
#   libperseus-sdr (Perseus)      https://github.com/Microtelecom/libperseus-sdr autotools
#   SDRplay API    (SDRplay)      https://www.sdrplay.com/software/...run        厂商二进制
#
# 全部免 root：装到 $PREFIX/usr，不上系统。
# 任何一个失败都不影响主流程 —— build-sdrpp-full.sh 只对「确实存在 .pc」的模块开 ON。
#
# 用法： bash deps-vendor.sh
# 产物： $PREFIX/usr 下新增 .pc + 头文件 + 库；$PREFIX/vendor.log 记录每个库的结果

set -uo pipefail

PREFIX="${PREFIX:-/home/tsw/sdr/local}"
PREFIX="${PREFIX%/}"
WORK="$PREFIX/vendor"
INS="$PREFIX/usr"
JOBS="$(nproc 2>/dev/null || echo 4)"
LOG="$PREFIX/vendor.log"

mkdir -p "$WORK" "$INS" "$INS/lib" "$INS/include"
: > "$LOG"

[ -f "$PREFIX/env.sh" ] && source "$PREFIX/env.sh"

say()  { echo; echo ">>> $*"; }
note() { echo "    $*"; }

# 记录结果： record <库名> <OK|SKIP|FAIL> <说明>
record() { printf '%-16s %-5s %s\n' "$1" "$2" "$3" | tee -a "$LOG"; }

echo "=============================================================="
echo " 厂商库编译（免 root）  → $INS"
echo "=============================================================="

# ---------------------------------------------------------------------------
# 通用 cmake 构建函数
# ---------------------------------------------------------------------------
build_cmake() {
  local name="$1" src="$2" pc="$3"
  [ -d "$src" ] || { record "$name" SKIP "源码目录不存在"; return; }
  # 清掉可能残留的失败构建缓存，保证重跑结果确定
  rm -rf "$src/build"
  note "cmake 配置…"
  if ! cmake -S "$src" -B "$src/build" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$INS" \
        -DCMAKE_PREFIX_PATH="$INS" \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DBUILD_SHARED_LIBS=ON \
        >"$WORK/$name.cmake.log" 2>&1; then
    record "$name" FAIL "cmake 配置失败 (见 $WORK/$name.cmake.log)"; return
  fi
  note "编译安装…"
  if ! cmake --build "$src/build" -j"$JOBS" --target install \
        >>"$WORK/$name.cmake.log" 2>&1; then
    record "$name" FAIL "编译/安装失败 (见 $WORK/$name.cmake.log)"; return
  fi
  record "$name" OK "已安装"
}

# 处理 vendor 装出来的 .pc：relocatable 一下，保证 -I/-L 指向本地前缀
fix_pc() {
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    sed -i -E "s|^prefix=/usr\$|prefix=$INS|" "$f"
    sed -i -E "s|^prefix=/usr/local\$|prefix=$INS|" "$f"
    sed -i "s|/usr/local/|$INS/|g" "$f"
    sed -i "s|/usr/|$INS/|g" "$f"
    sed -i "/^Requires\.private/d" "$f"
  done < <(find "$INS/lib" "$INS/lib/x86_64-linux-gnu" "$INS/share" -name '*.pc' 2>/dev/null)
}

# ---------------------------------------------------------------------------
# 1) librfnm
# ---------------------------------------------------------------------------
say "1/5 librfnm"
if [ ! -d "$WORK/librfnm" ]; then
  timeout 300 git clone --depth 1 https://github.com/AlexandreRouma/librfnm "$WORK/librfnm" >/dev/null 2>&1 \
    || record librfnm FAIL "git clone 失败"
fi
[ -d "$WORK/librfnm" ] && build_cmake librfnm "$WORK/librfnm" librfnm

# ---------------------------------------------------------------------------
# 2) libfobos
# ---------------------------------------------------------------------------
say "2/5 libfobos"
if [ ! -d "$WORK/libfobos" ]; then
  timeout 300 git clone --depth 1 https://github.com/AlexandreRouma/libfobos "$WORK/libfobos" >/dev/null 2>&1 \
    || record libfobos FAIL "git clone 失败"
fi
[ -d "$WORK/libfobos" ] && build_cmake libfobos "$WORK/libfobos" libfobos

# ---------------------------------------------------------------------------
# 3) dlcr_host (Dragon Labs)
# ---------------------------------------------------------------------------
say "3/5 dlcr_host"
if [ ! -d "$WORK/dlcr_host" ]; then
  if timeout 300 wget -q -O "$WORK/dlcr_host.zip" https://dragnlabs.com/host-tools/dlcr_host_v0.3.0.zip; then
    mkdir -p "$WORK/dlcr_host"
    if command -v unzip >/dev/null; then
      unzip -q "$WORK/dlcr_host.zip" -d "$WORK/dlcr_host" 2>/dev/null \
        || record dlcr FAIL "unzip 失败"
    else
      record dlcr FAIL "缺少 unzip"
    fi
  else
    record dlcr FAIL "wget 下载失败"
  fi
fi
# zip 解出来的顶层就是 cmake 工程（dlcr_host/CMakeLists.txt）。
# 注意：不要用 find 去"找"CMakeLists —— utils/dlcr_*/ 下面也各有一份，
# 抓到子目录会因为 ${CMAKE_SOURCE_DIR}/src 解析错位而报 dlcr.h not found。
if [ -f "$WORK/dlcr_host/CMakeLists.txt" ]; then
  build_cmake dlcr "$WORK/dlcr_host" libdlcr
elif [ -d "$WORK/dlcr_host" ]; then
  record dlcr SKIP "解包目录中未找到顶层 CMakeLists.txt"
fi

# ---------------------------------------------------------------------------
# 4) libperseus-sdr (autotools)
# ---------------------------------------------------------------------------
say "4/5 libperseus-sdr"
# 刻意用 release tarball 而不是 git clone：tarball 里带预生成的 configure，
# 而本机没有 autoconf/automake/libtool，仓库里的 bootstrap.sh 跑不起来。
if [ ! -d "$WORK/libperseus-sdr" ]; then
  mkdir -p "$WORK/libperseus-sdr"
  if timeout 300 wget -q -O "$WORK/perseus.tar.gz" \
       https://github.com/Microtelecom/libperseus-sdr/releases/download/v0.8.2/libperseus_sdr-0.8.2.tar.gz; then
    tar -xzf "$WORK/perseus.tar.gz" -C "$WORK/libperseus-sdr" --strip-components=1 2>/dev/null \
      || record perseus FAIL "tar 解包失败"
  else
    record perseus FAIL "release tarball 下载失败"
  fi
fi
P="$WORK/libperseus-sdr"
if [ -d "$P" ]; then
  (
    cd "$P" || exit 1
    # 仓库若已带预生成的 configure 就直接用；否则才需要 autoreconf
    if [ ! -x ./configure ]; then
      if command -v autoreconf >/dev/null; then
        autoreconf -i >/dev/null 2>&1 || exit 2
      else
        echo "缺少 autoreconf 且仓库无预生成 configure" >&2; exit 3
      fi
    fi
    ./configure --prefix="$INS" >"$WORK/perseus.log" 2>&1 || exit 4
    make -j"$JOBS" >>"$WORK/perseus.log" 2>&1 || exit 5
    make install >>"$WORK/perseus.log" 2>&1 || exit 6
  )
  case $? in
    0) record perseus OK   "autotools 编译安装成功" ;;
    2) record perseus FAIL "autoreconf 失败" ;;
    3) record perseus SKIP "无 configure 且无 autoreconf（可 apt 装 autoconf/automake/libtool 后重试）" ;;
    4) record perseus FAIL "configure 失败" ;;
    5) record perseus FAIL "make 失败" ;;
    6) record perseus FAIL "make install 失败" ;;
  esac
fi

# ---------------------------------------------------------------------------
# 5) SDRplay API（厂商闭源二进制，需 7z 解 .run 自解压包）
# ---------------------------------------------------------------------------
say "5/5 SDRplay API"
if [ ! -d "$WORK/sdrplay" ]; then
  mkdir -p "$WORK/sdrplay"
  if timeout 300 wget -q -O "$WORK/sdrplay/api.run" \
       https://www.sdrplay.com/software/SDRplay_RSP_API-Linux-3.15.2.run; then
    # 7zip 包提供 7zz；优先用本地前缀里的，再退到系统
    SEVENZ=""
    for c in "$INS/../usr/bin/7zz" /usr/bin/7zz /usr/bin/7z /usr/lib/p7zip/7z; do
      [ -x "$c" ] && { SEVENZ="$c"; break; }
    done
    if [ -n "$SEVENZ" ]; then
      ( cd "$WORK/sdrplay" && "$SEVENZ" x -y api.run >/dev/null 2>&1 ) || true
      # 里面通常还有一层 .7z
      INNER="$(find "$WORK/sdrplay" -maxdepth 1 -name '*.7z' | head -1)"
      [ -n "$INNER" ] && "$SEVENZ" x -y -o"$WORK/sdrplay/x" "$INNER" >/dev/null 2>&1 || true
      SRC="$(find "$WORK/sdrplay" -maxdepth 3 -name 'sdrplay_api.h' -printf '%h\n' 2>/dev/null | head -1)"
      SO="$(find "$WORK/sdrplay" -maxdepth 4 -name 'libsdrplay_api.so*' 2>/dev/null | head -1)"
      if [ -n "$SRC" ] && [ -n "$SO" ]; then
        cp -f "$SRC"/*.h "$INS/include/" 2>/dev/null
        cp -Pf "$SO" "$INS/lib/libsdrplay_api.so" 2>/dev/null
        record sdrplay OK "头文件与库已就位"
      else
        record sdrplay FAIL "解包后未找到 sdrplay_api.h / libsdrplay_api.so"
      fi
    else
      record sdrplay SKIP "缺少 7z 解包器"
    fi
  else
    record sdrplay FAIL "wget 下载失败"
  fi
fi

# ---------------------------------------------------------------------------
# 收尾：修 .pc、刷新 ld 缓存无关（不写系统），汇总
# ---------------------------------------------------------------------------
say "重定位新增 .pc"
fix_pc

say "厂商库结果汇总"
cat "$LOG"

echo
echo "下一步： bash build-sdrpp-full.sh    # 会自动按实际可用的 .pc 决定模块 ON/OFF"
