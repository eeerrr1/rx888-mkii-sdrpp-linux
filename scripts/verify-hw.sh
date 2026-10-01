#!/usr/bin/env bash
# RX888 MkII 环境自检（不需要 root）
# 用法:  bash verify-hw.sh
PASS=0; FAIL=0; WARN=0
ok()   { echo "  [通过] $1"; PASS=$((PASS+1)); }
bad()  { echo "  [失败] $1"; FAIL=$((FAIL+1)); }
warn() { echo "  [注意] $1"; WARN=$((WARN+1)); }

echo "=============== RX888 MkII 环境自检 ==============="
echo

echo "1. USB 设备是否存在"
DEV=""
for d in /sys/bus/usb/devices/*/; do
    if [ -f "$d/idVendor" ] && [ "$(cat "$d/idVendor" 2>/dev/null)" = "04b4" ]; then DEV="$d"; fi
done
if [ -z "$DEV" ]; then
    bad "未找到 04b4 设备。检查线缆/供电，或设备已被其他程序占用（lsusb 确认）"
else
    PID=$(cat "$DEV/idProduct")
    SPD=$(cat "$DEV/speed")
    VER=$(cat "$DEV/version")
    ok "找到设备 $DEV (idProduct=$PID, USB $VER)"
    case "$PID" in
        00f1) ok  "运行态固件已加载 (04b4:00f1)" ;;
        00f3) warn "处于 bootloader/DFU 态 (04b4:00f3) —— 需要上传 SDDC_FX3.img 后才能出流" ;;
        *)    warn "未知 idProduct=$PID" ;;
    esac

    echo
    echo "2. 链路速率（RX888 MkII 满速需 256MB/s，必须 USB3.0）"
    echo "   实测: ${SPD} Mbps"
    if [ "$SPD" -ge 5000 ] 2>/dev/null; then
        ok "USB 3.0 及以上，满足带宽要求"
    elif [ "$SPD" -ge 10000 ] 2>/dev/null; then
        ok "USB 3.1/3.2"
    else
        bad "当前为 USB 2.0 (480Mbps)。理论可用带宽约 280Mbps，远低于 2048Mbps 需求"
        echo "         -> 请把线缆插到 USB 3.0 端口（蓝色口 / 或支持 10Gbps 的 USB-C 口）"
        echo "         -> 本机可用的高速总线："
        lsusb -t 2>/dev/null | grep -E "20000M|10000M|5000M" | sed 's/^/           /'
    fi
fi

echo
echo "3. USBFS 缓冲（默认 16MB 会导致 LIBUSB_ERROR_NO_MEM / 丢样本）"
UM=$(cat /sys/module/usbcore/parameters/usbfs_memory_mb 2>/dev/null || echo "?")
if [ "$UM" = "0" ]; then ok "usbfs_memory_mb=0（无限制）"
elif [ "$UM" != "?" ] && [ "$UM" -ge 256 ] 2>/dev/null; then ok "usbfs_memory_mb=$UM MB"
else warn "usbfs_memory_mb=$UM MB，建议 >= 256（运行 sudo bash setup-root.sh）"; fi

echo
echo "4. 设备节点权限"
NODE=""
if [ -n "$DEV" ]; then
    BUS=$(cat "$DEV/busnum" 2>/dev/null); DEVNUM=$(cat "$DEV/devnum" 2>/dev/null)
    [ -n "$BUS" ] && [ -n "$DEVNUM" ] && NODE="/dev/bus/usb/$(printf %03d $BUS)/$(printf %03d $DEVNUM)"
fi
if [ -n "$NODE" ] && [ -e "$NODE" ]; then
    PERM=$(stat -c '%A %U:%G' "$NODE")
    echo "   $NODE  ->  $PERM"
    if [ -w "$NODE" ]; then ok "当前用户可读写"
    else bad "当前用户不可写（需 udev 规则，见 setup-root.sh）"; fi
else
    warn "无法定位设备节点"
fi

echo
echo "5. 构建依赖"
for p in libusb-1.0 fftw3f zstd glfw3 soapysdr; do
    V=$(pkg-config --modversion $p 2>/dev/null)
    if [ -n "$V" ]; then ok "pkg-config $p = $V"; else bad "缺少 $p 开发包"; fi
done
for t in gcc g++ cmake ninja git; do
    command -v $t >/dev/null 2>&1 && ok "工具 $t" || bad "缺少工具 $t"
done

echo
echo "=================== 汇总 ==================="
echo "  通过 $PASS / 注意 $WARN / 失败 $FAIL"
[ "$FAIL" -eq 0 ] && echo "  结论: 可以进入构建阶段" || echo "  结论: 先解决上面的【失败】项"
exit 0
