#!/usr/bin/env bash
# setup-root.sh — RX888 MkII on Linux：一次性特权准备（只需要跑一次）
#
# 用法：
#   sudo bash setup-root.sh                # 只做"必须特权"的两件事（推荐，最小改动）
#   sudo bash setup-root.sh --with-deps    # 额外用 apt 安装系统级构建依赖
#
# 为什么必须要 root —— 只有两件事：
#   1) udev 规则：让普通用户能打开 04b4:00f1（运行态）与 04b4:00f3（DFU/bootloader）。
#      否则 libusb 一律返回 -3 = LIBUSB_ERROR_ACCESS，表现为
#      "Found uninitialized device" 之后立刻 "Failed to open device: -3"。
#   2) usbfs_memory_mb：内核默认只给 USBFS 16MB。RX888 在高采样率下单次传输
#      可达数十 MB，16MB 会导致丢样本或 LIBUSB_ERROR_NO_MEM。
#
# 其余东西（SDR++ 的全部构建依赖）已经用免 root 方式部署在 /home/<user>/sdr/local，
# 见同目录 deps-local.sh，所以默认不再动系统包。
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "请用 sudo 运行: sudo bash $0 [--with-deps]" >&2
    exit 1
fi

TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || echo tsw)}"
TARGET_USER="${TARGET_USER:-tsw}"
FW_SRC="${SDDC_FIRMWARE:-/home/$TARGET_USER/sdr/ExtIO_sddc/SDDC_FX3.img}"
WITH_DEPS=0
[ "${1:-}" = "--with-deps" ] && WITH_DEPS=1

echo "=============================================="
echo " RX888 MkII 特权环境准备"
echo " 目标用户: $TARGET_USER"
echo "=============================================="

# ---------------------------------------------------------------------------
# 可选：系统级构建依赖
# ---------------------------------------------------------------------------
if [ "$WITH_DEPS" -eq 1 ]; then
    echo
    echo "[可选] 安装系统级构建依赖"
    apt-get update -qq
    apt-get install -y --no-install-recommends \
        build-essential cmake ninja-build git pkg-config \
        libusb-1.0-0-dev libusb-1.0-0 \
        libfftw3-dev libzstd-dev libglfw3-dev libvolk-dev \
        libgl-dev libglu1-mesa-dev \
        libsoapysdr-dev soapysdr-tools
    echo "  完成"
fi

# ---------------------------------------------------------------------------
# 1/4  usbfs_memory_mb
# ---------------------------------------------------------------------------
echo
echo "=============================================="
echo " 1/4  放大 USBFS 缓冲（16MB -> 1000MB）"
echo "=============================================="
if [ -w /sys/module/usbcore/parameters/usbfs_memory_mb ]; then
    OLD=$(cat /sys/module/usbcore/parameters/usbfs_memory_mb)
    echo 1000 > /sys/module/usbcore/parameters/usbfs_memory_mb
    echo "  $OLD MB -> $(cat /sys/module/usbcore/parameters/usbfs_memory_mb) MB（本次立即生效）"
else
    echo "  [警告] 无法写入 usbfs_memory_mb"
fi

# 持久化：Ubuntu 的 usbcore 是编进内核的（不是模块），所以 /etc/modprobe.d 无效，
# 必须用 systemd-tmpfiles，每次开机由 systemd 写 sysfs。
# 注意：本地管理员配置应放 /etc/tmpfiles.d/（会覆盖 /usr/lib/tmpfiles.d/ 里的同名包配置）。
cat > /etc/tmpfiles.d/rx888-sddc.conf <<'EOF'
# RX888 MkII (libsddc/libusb) —— 放大 USBFS 缓冲，防止高采样率下丢样本
w /sys/module/usbcore/parameters/usbfs_memory_mb - - - - 1000
EOF
chmod 644 /etc/tmpfiles.d/rx888-sddc.conf
echo "  已写入 /etc/tmpfiles.d/rx888-sddc.conf（开机自动生效）"

# 立刻按新配置应用一次（验证配置本身语法正确）
if command -v systemd-tmpfiles >/dev/null 2>&1; then
    if systemd-tmpfiles --create /etc/tmpfiles.d/rx888-sddc.conf 2>/dev/null; then
        echo "  systemd-tmpfiles 应用成功，当前值: $(cat /sys/module/usbcore/parameters/usbfs_memory_mb) MB"
    else
        echo "  [注意] systemd-tmpfiles 未能应用（已用直接写 sysfs 兜底）"
    fi
fi

# ---------------------------------------------------------------------------
# 2/4  udev 规则
# ---------------------------------------------------------------------------
echo
echo "=============================================="
echo " 2/4  安装 udev 规则"
echo "=============================================="
cat > /etc/udev/rules.d/99-sddc.rules <<EOF
# BBRF103 / HF103 / RX888 / RX888 MkII / Mk3  (Cypress EZ-USB FX3)
# 运行态固件
SUBSYSTEM=="usb", ATTR{idVendor}=="04b4", ATTR{idProduct}=="00f1", MODE="0666", TAG+="uaccess"
# bootloader / DFU 态（固件上传入口，必须先能开这个才能上传固件）
SUBSYSTEM=="usb", ATTR{idVendor}=="04b4", ATTR{idProduct}=="00f3", MODE="0666", TAG+="uaccess"
# 新版固件（RaspSDR/rx888 等）使用的 PID，留作将来兼容
SUBSYSTEM=="usb", ATTR{idVendor}=="04b4", ATTR{idProduct}=="3ddc", MODE="0666", TAG+="uaccess"
EOF
chmod 644 /etc/udev/rules.d/99-sddc.rules
udevadm control --reload-rules
udevadm trigger --subsystem-match=usb --action=change
sleep 2
echo "  已写入 /etc/udev/rules.d/99-sddc.rules"

# 立刻复核：已插着的设备节点是否已变得可读写（trigger 通常够用，但个别情况下
# 需要重新枚举，这里做一次兜底，避免用户还要拔插一次）
echo "  --- 复核已插入设备的节点权限 ---"
NEED_REPLUG=0
for d in /sys/bus/usb/devices/*/; do
    [ -f "$d/idVendor" ] || continue
    [ "$(cat "$d/idVendor" 2>/dev/null)" = "04b4" ] || continue
    BUS=$(cat "$d/busnum"); DN=$(cat "$d/devnum")
    NODE="/dev/bus/usb/$(printf %03d "$BUS")/$(printf %03d "$DN")"
    if [ -e "$NODE" ]; then
        # 若规则未命中，直接按规则意图修正一次（等价于 udev 要做的 MODE 修改）
        if [ "$(stat -c '%a' "$NODE")" != "666" ]; then
            chmod 666 "$NODE" 2>/dev/null && \
                echo "  $(basename "$d") -> $NODE 已置为 666（$(stat -c '%A %U:%G' "$NODE")）"
        else
            echo "  $(basename "$d") -> $NODE 权限正常：$(stat -c '%A %U:%G' "$NODE")"
        fi
    else
        echo "  $(basename "$d") -> $NODE 节点不存在"
        NEED_REPLUG=1
    fi
done
[ "$NEED_REPLUG" -eq 1 ] && echo "  [提示] 有个别设备节点不存在，可能需要重新拔插一次 USB"

# ---------------------------------------------------------------------------
# 3/4  固件镜像
# ---------------------------------------------------------------------------
echo
echo "=============================================="
echo " 3/4  安装固件镜像"
echo "=============================================="
install -d -m 0755 /usr/share/sddc
if [ ! -f "$FW_SRC" ]; then
    # 兜底：在常见位置自动搜一遍
    for cand in \
        "/home/$TARGET_USER/sdr/ExtIO_sddc/SDDC_FX3.img" \
        "/home/$TARGET_USER/sdr/ExtIO_sddc/build/SDDC_FX3.img" \
        "/opt/sddc/SDDC_FX3.img"; do
        [ -f "$cand" ] && { FW_SRC="$cand"; break; }
    done
    if [ ! -f "$FW_SRC" ]; then
        FW_FOUND=$(find "/home/$TARGET_USER/sdr" -maxdepth 3 -name '*.img' 2>/dev/null | head -1)
        [ -n "$FW_FOUND" ] && FW_SRC="$FW_FOUND"
    fi
fi
if [ -f "$FW_SRC" ]; then
    install -m 0644 "$FW_SRC" /usr/share/sddc/SDDC_FX3.img
    echo "  已安装: /usr/share/sddc/SDDC_FX3.img ($(stat -c%s /usr/share/sddc/SDDC_FX3.img) 字节)"
    echo "  来源:   $FW_SRC"
else
    echo "  [警告] 未找到固件镜像: $FW_SRC"
    echo "         固件在 ExtIO_sddc 仓库根目录，请手动复制到 /usr/share/sddc/SDDC_FX3.img"
fi

# 让所有用户都能读到（免 root 工具要用）
[ -f /usr/share/sddc/SDDC_FX3.img ] && chmod 0644 /usr/share/sddc/SDDC_FX3.img || true

# ---------------------------------------------------------------------------
# 4/4  复核
# ---------------------------------------------------------------------------
echo
echo "=============================================="
echo " 4/4  复核"
echo "=============================================="
echo "--- usbfs_memory_mb ---"
cat /sys/module/usbcore/parameters/usbfs_memory_mb 2>/dev/null || echo "  读取失败"

echo "--- udev 规则命中情况 ---"
found=0
for d in /sys/bus/usb/devices/*/; do
    [ -f "$d/idVendor" ] || continue
    [ "$(cat "$d/idVendor" 2>/dev/null)" = "04b4" ] || continue
    found=1
    PID=$(cat "$d/idProduct")
    SPD=$(cat "$d/speed")
    BUS=$(cat "$d/busnum"); DN=$(cat "$d/devnum")
    NODE="/dev/bus/usb/$(printf %03d "$BUS")/$(printf %03d "$DN")"
    echo "  设备: $(basename "$d")  idProduct=$PID  speed=${SPD}Mbps  USB $(cat "$d/version")"
    echo "  节点: $NODE -> $([ -e "$NODE" ] && stat -c '%A %U:%G' "$NODE" || echo '不存在')"

    # 注意：DFU/bootloader 态（00f3）下 FX3 在硬件上就关闭了 SuperSpeed 信号，
    # 无论插在哪个口都只会显示 480 Mbps（Cypress AN76405 明确说明）。
    # 所以只有"已加载固件的运行态"才适合用速率判断端口好坏。
    case "$PID" in
        00f1|3ddc)
            if [ "${SPD%%.*}" -lt 5000 ] 2>/dev/null; then
                echo "  >>> 警告: 已加载固件却只有 ${SPD}Mbps —— 说明端口或线缆是 USB 2.0，"
                echo "            此时做不了全带宽接收。本机可用的高速总线："
                lsusb -t 2>/dev/null | grep -E "20000M|10000M|5000M" | sed 's/^/              /'
            else
                echo "  >>> 运行态且链路 ≥5Gbps，端口与线缆正确"
            fi
            ;;
        00f3)
            echo "  >>> 处于 DFU/bootloader 态：此时 480Mbps 属正常现象，"
            echo "            载入固件后设备会重新枚举为 04b4:00f1，届时再判断速率。"
            ;;
    esac
done
[ "$found" -eq 1 ] || echo "  未发现 04b4 设备（检查线缆/供电）"

echo
echo "=============================================="
echo " 完成。下一步（以 $TARGET_USER 身份，不要用 sudo）："
echo "   bash /home/$TARGET_USER/sdr/verify-device.sh"
echo "=============================================="
