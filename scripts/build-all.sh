#!/usr/bin/env bash
# build-all.sh — RX888 MkII / SDR++ 本地构建统一入口（全程无需 root）
#
# 用法：
#   bash build-all.sh deps      # ① 免 root 部署构建依赖到 ./local（apt-get download + dpkg-deb -x）
#   bash build-all.sh sdrpp     # ② 编译并安装 SDR++（含 sddc_source 模块）到 ./install
#   bash build-all.sh soapy     # ③ 可选：编译 ExtIO_sddc 的 SoapySDDC 插件（备选路线）
#   bash build-all.sh all       # ①+②（最常用）
#   bash build-all.sh verify    # ④ 端到端设备验证（需先 sudo bash setup-root.sh）
#   bash build-all.sh run       # ⑤ 启动 SDR++
#
# 说明：本脚本是入口壳，实际工作在 deps-local.sh / build-sdrpp.sh / verify-device.sh 里，
#      那三个脚本也可以单独调用。
set -uo pipefail

SDR_DIR="$(cd "$(dirname "$0")" && pwd)"
PREFIX="${SDR_LOCAL_PREFIX:-$SDR_DIR/local}"
INSTALL="${INSTALL:-$SDR_DIR/install}"
JOBS="$(nproc 2>/dev/null || echo 4)"
CM="${CM:-/home/tsw/.workbuddy/binaries/python/envs/default/bin/cmake}"
command -v "$CM" >/dev/null 2>&1 || CM="cmake"

say() { echo; echo ">>> $*"; }

step_deps() {
    say "① 部署构建依赖（免 root）"
    bash "$SDR_DIR/deps-local.sh"
}

step_sdrpp() {
    say "② 编译 SDR++（含打过补丁的 sddc_source）"
    bash "$SDR_DIR/build-sdrpp.sh" build
}

step_soapy() {
    say "③ 编译 ExtIO_sddc / SoapySDDC（备选路线）"
    local SRC="$SDR_DIR/ExtIO_sddc"
    [ -d "$SRC" ] || { echo "找不到 $SRC"; return 1; }
    [ -f "$PREFIX/env.sh" ] && source "$PREFIX/env.sh"

    "$CM" -S "$SRC" -B "$SRC/build" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$INSTALL" \
        -DCMAKE_PREFIX_PATH="$PREFIX/usr" || return 1

    # 只编 SoapySDDC 目标。不要跑无目标的全量 make：unittest/ 会用 ExternalProject
    # 从 GitHub 克隆 CppUnitTestFramework，而本机对 GitHub 极不稳定，会长时间卡住。
    "$CM" --build "$SRC/build" --target SDDCSupport -j"$JOBS" || return 1

    echo
    echo "  产物:"
    find "$SRC/build" \( -name 'libSDDCSupport.so' -o -name 'libSDDC_CORE.a' \) 2>/dev/null | sed 's/^/    /'

    local PLUG
    PLUG="$(find "$SRC/build" -name 'libSDDCSupport.so' -printf '%h\n' 2>/dev/null | head -1)"
    if [ -n "$PLUG" ]; then
        echo
        echo "  启用方式（把插件目录加进 SoapySDR 搜索路径）:"
        echo "    export SOAPY_SDR_PLUGIN_PATH=$PLUG"
        echo "    export PATH=$PREFIX/usr/bin:\$PATH      # SoapySDRUtil 在本地前缀里"
        echo "    SoapySDRUtil --info                     # 应出现 'Available factories... SDDC'"
        echo "    SoapySDRUtil --probe=driver=sddc        # 需要先跑过 setup-root.sh 才有权限"
        echo
        echo "  在 SDR++ 里用这条路线：Source 选 'SoapySDR Source'，参数 driver=sddc"
    fi
}

step_verify() { say "④ 端到端设备验证"; bash "$SDR_DIR/verify-device.sh" "${1:-}"; }
step_run()    { say "⑤ 启动 SDR++";      bash "$SDR_DIR/run-sdrpp.sh"; }

case "${1:-all}" in
    deps)   step_deps ;;
    sdrpp)  step_sdrpp ;;
    soapy)  step_soapy ;;
    verify) step_verify "${2:-}" ;;
    run)    step_run ;;
    all)    step_deps && step_sdrpp ;;
    *)      echo "未知步骤: $1"; echo "可用: deps | sdrpp | soapy | verify | run | all"; exit 1 ;;
esac
