#!/usr/bin/env bash
# run-sdrpp.sh — 启动本地构建的 SDR++（含 RX888 / SDDC 源模块）
#
# 说明：
#   SDR++ 的默认模块目录与资源目录都是从编译时的 CMAKE_INSTALL_PREFIX 派生的，
#   所以这里用"安装到本地前缀 + -r 指定配置根"的方式，不需要改任何系统路径。
#
# 用法：
#   bash run-sdrpp.sh            # 正常启动
#   bash run-sdrpp.sh -s         # 服务器模式（无界面，供远程连接）
#   SDDC_FIRMWARE=/path/to.img bash run-sdrpp.sh   # 指定固件镜像
set -uo pipefail

SDR_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL="${INSTALL:-$SDR_DIR/install}"
ROOT="${SDRPP_ROOT:-$SDR_DIR/sdrpp-root}"

# 本地依赖前缀（fftw3f / volk / glfw / zstd / SoapySDR 都在这里，不在系统里）
# shellcheck disable=SC1091
[ -f "$SDR_DIR/local/env.sh" ] && source "$SDR_DIR/local/env.sh"

# 固件：让 sddc_source 能自动找到（模块会按 配置项 -> $SDDC_FIRMWARE -> 常见路径 三级回退）
if [ -z "${SDDC_FIRMWARE:-}" ]; then
    for c in "$SDR_DIR/install/share/sddc/SDDC_FX3.img" \
             "/usr/share/sddc/SDDC_FX3.img" \
             "$SDR_DIR/ExtIO_sddc/SDDC_FX3.img"; do
        if [ -f "$c" ]; then export SDDC_FIRMWARE="$c"; break; fi
    done
fi

# 路线 1（SoapySDR）用的 SoapySDDC 插件。
# SoapySDR 只在标准目录里找插件，我们这套是免 root 装在本地前缀的，
# 所以必须显式告诉它。找不到插件时 soapy_source 会显示空设备列表。
SOAPY_PLUG="$(dirname "$(find "$SDR_DIR/ExtIO_sddc/build" -name 'lib*Support.so' 2>/dev/null | head -1)")"
if [ -n "$SOAPY_PLUG" ] && [ -d "$SOAPY_PLUG" ]; then
    export SOAPY_SDR_PLUGIN_PATH="${SOAPY_SDR_PLUGIN_PATH:+$SOAPY_SDR_PLUGIN_PATH:}$SOAPY_PLUG"
fi

if [ ! -x "$INSTALL/bin/sdrpp" ]; then
    echo "找不到 $INSTALL/bin/sdrpp" >&2
    echo "请先执行:  bash $SDR_DIR/build-sdrpp.sh build" >&2
    exit 1
fi

mkdir -p "$ROOT"

echo "---------------------------------------------------------"
echo " SDR++ 启动信息"
echo "---------------------------------------------------------"
echo " 可执行    : $INSTALL/bin/sdrpp"
echo " 配置根    : $ROOT   (config.json 生成于此)"
echo " 模块目录  : $INSTALL/lib/sdrpp/plugins"
echo "             $(ls -1 "$INSTALL/lib/sdrpp/plugins" 2>/dev/null | tr '\n' ' ')"
echo " 资源目录  : $INSTALL/share/sdrpp"
echo " 固件镜像  : ${SDDC_FIRMWARE:-<未找到>}"
echo " Soapy 插件: ${SOAPY_SDR_PLUGIN_PATH:-<未找到>}"
echo "---------------------------------------------------------"
echo " 用法提示："
echo "   路线 0（原生）：Source 选 'SDDC Source'"
echo "   路线 1（Soapy）：Source 选 'SoapySDR Source'，设备列表里挑 'SDDC :: RX888mk2 ...'"
echo "   两条路线的设备下拉框都会显示真实序列号（不再是写死的测试值）"
echo "   若提示权限错误，先执行: sudo bash $SDR_DIR/setup-root.sh"
echo "   设备卡住时: bash $SDR_DIR/rx888-reset.sh  （打回 DFU 后重来）"
echo "---------------------------------------------------------"
echo

cd "$ROOT" || exit 1
exec "$INSTALL/bin/sdrpp" -r "$ROOT" "$@"
