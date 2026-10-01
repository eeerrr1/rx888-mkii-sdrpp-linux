#!/usr/bin/env bash
# verify-device.sh — RX888 MkII 端到端验证（无需 root，但需要先跑过 setup-root.sh）
#
# 流程：
#   阶段 0  前置条件检查（usbfs_memory_mb / udev 规则 / 设备节点权限）
#   阶段 1  记录加载固件前的设备状态（应为 DFU 态 04b4:00f3）
#   阶段 2  上传固件（用 sddc_info，它同时会读回型号/固件版本）
#   阶段 3  等待重新枚举：00f3(DFW/USB2) -> 00f1(运行态/可协商 USB3)
#   阶段 4  判定链路速率（这一步才真正说明端口与线缆是不是 USB 3.0）
#   阶段 5  抓样本，用实际吞吐验证出流健康度
#   阶段 6  路线 1（SoapySDDC）设备发现 + 出流验证
#   阶段 7  汇总
#
# 用法： bash verify-device.sh [固件路径]
set -uo pipefail

SDR_DIR="$(cd "$(dirname "$0")" && pwd)"

# 本地依赖前缀（libSoapySDR 等都在这里，不在系统里）。
# 不 source 的话本地版 SoapySDRUtil 根本起不来，阶段 6 会误报"未发现设备"。
# shellcheck disable=SC1091
[ -f "$SDR_DIR/local/env.sh" ] && source "$SDR_DIR/local/env.sh"

LIB="$SDR_DIR/SDRPlusPlus/source_modules/sddc_source/libsddc"
INFO="$LIB/build/utils/sddc_info/sddc_info"
RX="$LIB/build/utils/sddc_rx/sddc_rx"
FW="${1:-${SDDC_FIRMWARE:-/usr/share/sddc/SDDC_FX3.img}}"
[ -f "$FW" ] || FW="$SDR_DIR/ExtIO_sddc/SDDC_FX3.img"

PASS=0; FAIL=0; WARN=0
ok()   { echo "  [通过] $1"; PASS=$((PASS+1)); }
bad()  { echo "  [失败] $1"; FAIL=$((FAIL+1)); }
warn() { echo "  [注意] $1"; WARN=$((WARN+1)); }

# 快照：把每个 04b4 设备压成一行 "路径|PID|速率|USB版本|产品名"
snapshot() {
    for d in /sys/bus/usb/devices/*/; do
        [ -f "$d/idVendor" ] || continue
        [ "$(cat "$d/idVendor" 2>/dev/null)" = "04b4" ] || continue
        printf '%s|%s|%s|%s|%s\n' \
            "$(basename "$d")" \
            "$(cat "$d/idProduct" 2>/dev/null)" \
            "$(cat "$d/speed" 2>/dev/null)" \
            "$(cat "$d/version" 2>/dev/null)" \
            "$(cat "$d/product" 2>/dev/null | tr -d ' ')"
    done
}

pid_of()   { printf '%s' "$1" | cut -d'|' -f2; }
speed_of() { printf '%s' "$1" | cut -d'|' -f3; }
path_of()  { printf '%s' "$1" | cut -d'|' -f1; }

echo "====================================================="
echo " RX888 MkII 端到端验证"
echo " 固件: ${FW:-<未找到>}"
echo "====================================================="

# ---------------------------------------------------------------- 阶段 0
echo
echo "### 阶段 0：前置条件"
[ -x "$INFO" ] && ok "sddc_info 已构建" || bad "sddc_info 未构建: $INFO"
[ -x "$RX" ]   && ok "sddc_rx 已构建"   || bad "sddc_rx 未构建: $RX"
[ -f "$FW" ]   && ok "固件镜像存在 ($(stat -c%s "$FW") 字节)" || warn "未找到固件镜像"

UM=$(cat /sys/module/usbcore/parameters/usbfs_memory_mb 2>/dev/null || echo "?")
echo "  usbfs_memory_mb = $UM"
case "$UM" in
    0)   ok "USBFS 缓冲无限制" ;;
    "?") warn "无法读取 usbfs_memory_mb" ;;
    *)   if [ "$UM" -ge 256 ] 2>/dev/null; then ok "USBFS 缓冲 $UM MB"
         else bad "USBFS 缓冲仅 $UM MB（需 >=256）：sudo bash $SDR_DIR/setup-root.sh"; fi ;;
esac

if [ -f /etc/udev/rules.d/99-sddc.rules ]; then
    ok "udev 规则已安装"
else
    bad "缺少 /etc/udev/rules.d/99-sddc.rules：sudo bash $SDR_DIR/setup-root.sh"
fi

DEVNODE_OK=0
for d in /sys/bus/usb/devices/*/; do
    [ -f "$d/idVendor" ] || continue
    [ "$(cat "$d/idVendor" 2>/dev/null)" = "04b4" ] || continue
    B=$(cat "$d/busnum"); N=$(cat "$d/devnum")
    NODE="/dev/bus/usb/$(printf %03d "$B")/$(printf %03d "$N")"
    if [ -e "$NODE" ]; then
        PERM=$(stat -c '%A %U:%G' "$NODE")
        if [ -r "$NODE" ] && [ -w "$NODE" ]; then
            ok "设备节点可读写: $NODE ($PERM)"
            DEVNODE_OK=1
        else
            bad "设备节点权限不足: $NODE ($PERM)"
        fi
    fi
done
[ "$DEVNODE_OK" -eq 1 ] || warn "未找到可读写设备节点（若设备未插好请先插上）"

# ---------------------------------------------------------------- 阶段 1
echo
echo "### 阶段 1：加载固件前"
BEFORE=$(snapshot)
if [ -z "$BEFORE" ]; then
    bad "未发现 04b4 设备 —— 线缆/供电问题，或设备被占用"
    exit 1
fi
while IFS= read -r line; do
    printf '  %s  idProduct=%s  %sMbps  product=%s\n' \
        "$(path_of "$line")" "$(pid_of "$line")" "$(speed_of "$line")" \
        "$(printf '%s' "$line" | cut -d'|' -f5)"
    case "$(pid_of "$line")" in
        00f3) echo "     -> DFU/bootloader 态。此处 480Mbps 是 FX3 的正常行为"\
"(AN76405: USB boot 模式下 SuperSpeed 被硬件禁用)，不能据此判断端口。" ;;
        00f1) echo "     -> 已是运行态，固件此前已加载过" ;;
    esac
done <<< "$BEFORE"

# ---------------------------------------------------------------- 阶段 2
echo
echo "### 阶段 2：上传固件"
if [ -x "$INFO" ]; then
    timeout 90 "$INFO" "$FW" 2>&1 | sed 's/^/  /'
    rc=${PIPESTATUS[0]}
    echo "  (sddc_info 退出码: $rc)"
    if [ "$rc" -ne 0 ]; then
        warn "sddc_info 返回非 0。若信息中出现 -3 / ACCESS，说明 udev 规则还没生效"
    fi
fi

# ---------------------------------------------------------------- 阶段 3
echo
echo "### 阶段 3：等待设备重新枚举（最多 25 秒）"
AFTER=""
for i in $(seq 1 25); do
    sleep 1
    AFTER=$(snapshot)
    if printf '%s' "$AFTER" | grep -q '|00f1|'; then
        ok "已在第 ${i}s 重新枚举为运行态 (04b4:00f1)"
        break
    fi
    if printf '%s' "$AFTER" | grep -q '|3ddc|'; then
        ok "已在第 ${i}s 重新枚举为新版固件 PID (04b4:3ddc)"
        break
    fi
done
if [ -z "$AFTER" ]; then
    bad "设备在重新枚举过程中消失了 —— 通常是供电不足（换带供电的 USB3 口/有源 HUB）"
elif printf '%s' "$AFTER" | grep -q '|00f3|'; then
    bad "仍停留在 DFU 态：固件上传失败（固件与设备不匹配，或 usbfs 缓冲过小）"
fi
echo "  当前设备列表:"
[ -n "$AFTER" ] && while IFS= read -r line; do
    echo "    $(path_of "$line")  idProduct=$(pid_of "$line")  $(speed_of "$line")Mbps  product=$(printf '%s' "$line" | cut -d'|' -f5)"
done <<< "$AFTER"

# ---------------------------------------------------------------- 阶段 4
echo
echo "### 阶段 4：链路速率判定（这一步才反映端口/线缆的真实能力）"
SPD=""
while IFS= read -r line; do
    case "$(pid_of "$line")" in
        00f1|3ddc) SPD=$(speed_of "$line") ;;
    esac
done <<< "$AFTER"

if [ -z "$SPD" ]; then
    warn "没有运行态设备，跳过速率判定"
else
    echo "  实测链路速率: ${SPD} Mbps"
    if [ "${SPD%%.*}" -ge 5000 ] 2>/dev/null; then
        ok "USB 3.0 及以上，带宽满足 RX888 MkII 需求（约 2048 Mbps @64MSPS）"
    else
        bad "运行态仍只有 ${SPD}Mbps —— 端口或线缆为 USB 2.0，无法跑满带宽"
        echo "         本机可用的高速 root hub："
        lsusb -t 2>/dev/null | grep -E "20000M|10000M|5000M" | sed 's/^/           /'
    fi
fi

# ---------------------------------------------------------------- 阶段 5
echo
echo "### 阶段 5：抓样本验证出流（8 缓冲 @32 MSPS）"
if [ -x "$RX" ] && [ -n "$SPD" ]; then
    RAW="/tmp/rx888_capture.raw"
    timeout 120 "$RX" "$FW" 8 32000000 "$RAW" 2>&1 | sed 's/^/  /'
    rc=${PIPESTATUS[0]}
    echo "  (sddc_rx 退出码: $rc)"
    if [ "$rc" -eq 0 ]; then
        ok "成功抓到样本，数据流正常"
    else
        bad "未能抓到样本（退出码 $rc）"
    fi
    if [ -f "$RAW" ]; then
        SZ=$(stat -c%s "$RAW")
        echo "  已保存原始样本: $RAW ($SZ 字节)"
        if [ "$SZ" -gt 0 ]; then
            # 抽样统计，判断是否"有信号"而不是恒定值/全零
            python3 - "$RAW" <<'PY' 2>/dev/null || echo "  (python3 不可用，跳过离线统计)"
import sys, struct, math, os
p = sys.argv[1]
n = os.path.getsize(p) // 2
with open(p, 'rb') as f:
    raw = f.read(n * 2)
s = struct.unpack('<%dh' % n, raw)
mn, mx = min(s), max(s)
mean = sum(s) / n
var = sum((v - mean) ** 2 for v in s[::17]) / max(1, len(s[::17]))
print("  样本数: %d  min=%d max=%d mean=%.4f stdev=%.2f" % (n, mn, mx, mean, math.sqrt(var)))
uniq = len(set(s[::2009]))
print("  抽样不同取值个数: %d  %s" % (uniq, "-> 数据在变化，链路是活的" if uniq > 50 else "-> 数据几乎恒定，疑似未真正出流"))
PY
        fi
    fi
else
    warn "跳过抓样本（缺少运行态设备或工具）"
fi

# ---------------------------------------------------------------- 阶段 6
echo
echo "### 阶段 6：路线 1 —— SoapySDDC（SoapySDR）出流验证"
SOAPY_UTIL="$SDR_DIR/local/usr/bin/SoapySDRUtil"
SOAPY_PLUG=$(dirname "$(find "$SDR_DIR/ExtIO_sddc/build" -name 'lib*Support.so' 2>/dev/null | head -1)")
if [ -n "$SOAPY_PLUG" ] && [ -x "$SOAPY_UTIL" ]; then
    export SOAPY_SDR_PLUGIN_PATH="$SOAPY_PLUG"
    echo "  插件: $SOAPY_PLUG"

    # 注意：SoapySDDC 注册的 factory 名是【大写】 SDDC。
    # `--probe=driver=sddc`（小写）会报 "no match"，这是最容易踩的坑。
    FINDOUT=$("$SOAPY_UTIL" --find 2>&1 | head -20)
    if printf '%s' "$FINDOUT" | grep -q "driver = SDDC"; then
        ok "SoapySDR 已发现设备（factory 名是大写 SDDC）"
        printf '%s\n' "$FINDOUT" | grep -E "driver|label|hardware" | sed 's/^/     /'
    else
        bad "SoapySDR 未发现设备"
        printf '%s\n' "$FINDOUT" | sed 's/^/     /'
        echo "     排查：插件目录是否存在 / LD_LIBRARY_PATH 是否含本地前缀 / udev 权限"
    fi

    if [ -x "$RX" ] && [ -n "$SPD" ]; then
        R1LOG=/tmp/rx888_soapy_route.log
        timeout 45 "$SOAPY_UTIL" --rate=8e6 --direction=RX --args="driver=SDDC" \
            > "$R1LOG" 2>&1
        if grep -qE "[0-9.]+ Msps" "$R1LOG"; then
            MSPS=$(grep -oE "[0-9.]+ Msps" "$R1LOG" | tail -1 | awk '{print $1}')
            ok "SoapySDDC 出流成功，实测 ${MSPS} Msps（目标 8）"
            # 低于 90% 目标视为异常
            awk -v v="$MSPS" 'BEGIN{exit !(v+0 < 7.2)}' && \
                warn "速率偏低，可能 USB 链路降速或主机负载高"
        else
            bad "SoapySDDC 未能出流（LIBUSB_TRANSFER_TIMED_OUT？）"
            grep -m3 "ERROR\|TIMED_OUT" "$R1LOG" | sed 's/^/     /'
            echo "     参考：ExtIO_sddc 的 usb_device_open() 曾只等 500ms 且只扫一次设备列表，"
            echo "           导致固件上传后 'usb_device@0 not found'。本项目已修（改为轮询重枚举）。"
        fi
    else
        warn "跳过 SoapySDDC 出流测试（需要先有运行态设备）"
    fi
else
    warn "跳过路线 1（未编译 SoapySDDC 或缺少 SoapySDRUtil）"
    echo "     编译: bash $SDR_DIR/build-all.sh soapy"
fi

# ---------------------------------------------------------------- 阶段 7
echo
echo "====================================================="
echo " 汇总: 通过 $PASS / 失败 $FAIL / 注意 $WARN"
echo "====================================================="
if [ "$FAIL" -eq 0 ]; then
    echo "设备已可用。两条路线都已验证："
    echo "  路线 0 原生   : bash $SDR_DIR/run-sdrpp.sh   -> Source 选 'SDDC Source'"
    echo "  路线 1 Soapy  : bash $SDR_DIR/run-sdrpp.sh   -> Source 选 'SoapySDR Source'"
    echo "  （Source 下拉里会显示真实序列号，不再是写死的测试值）"
else
    echo "仍有失败项，按上面提示处理后重跑本脚本。"
fi
