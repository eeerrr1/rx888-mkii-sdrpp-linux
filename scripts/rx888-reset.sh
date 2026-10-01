#!/usr/bin/env bash
# rx888-reset.sh — 把 RX888 MkII 的 FX3 打回 bootloader（DFU）态
#
# 什么时候需要它：
#   1) 设备被某个程序"卡住"（占着不放 / 状态错乱），想从头来一遍；
#   2) 想强制冷启动，让某个驱动自己上传固件（SoapySDDC 就是这样工作的）；
#   3) 不同 SDR 软件之间切换时状态不干净。
#
# 它做的事：向 FX3 发送厂商命令 RESETFX3 (bRequest = 0xB1)。
#   这条命令是 FX3 固件自己实现的「重启回 bootloader」，发送成功后设备会：
#     04b4:00f1 (RX888mk2, 运行态)  ->  04b4:00f3 (WestBridge, DFU 态)
#   注意：控制传输会返回 -4 (LIBUSB_ERROR_NO_DEVICE)，这是**正常现象** ——
#   设备在命令生效的瞬间就断开了。不要把它当成失败。
#
# 用法：
#   bash rx888-reset.sh          # 重置（若设备本就在 DFU 态则直接提示）
#   bash rx888-reset.sh --check  # 只看状态，不做任何操作
set -uo pipefail

SDR_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="${TMPDIR:-/tmp}/rx888_fx3reset"
SRC="${TMPDIR:-/tmp}/rx888_fx3reset.c"

list_dev() { lsusb 2>/dev/null | grep -i "04b4" || true; }

show_state() {
    local line
    line=$(list_dev)
    if [ -z "$line" ]; then
        echo "  未发现 04b4 设备"
        return 1
    fi
    echo "$line" | while read -r l; do echo "  $l"; done
    return 0
}

echo "====================================================="
echo " RX888 MkII —— FX3 复位工具"
echo "====================================================="
echo "--- 当前状态 ---"
show_state || true

if [ "${1:-}" = "--check" ]; then
    echo
    echo "（--check 模式，未做任何改动）"
    exit 0
fi

# 已经在 DFU 态就不用动了
if list_dev | grep -q "04b4:00f3"; then
    echo
    echo "设备已经处于 DFU/bootloader 态，无需重置。"
    echo "下一步可以直接: bash $SDR_DIR/verify-device.sh"
    exit 0
fi

if ! list_dev | grep -q "04b4:00f1"; then
    echo
    echo "既不是 00f1 也不是 00f3 —— 设备可能没插好，或处于未知状态。"
    echo "建议先重新拔插一次 USB，再跑: bash $SDR_DIR/verify-hw.sh"
    exit 1
fi

# 编译小工具（只在需要时做，且不污染仓库）
if [ ! -x "$BIN" ] || [ "$SRC" -nt "$BIN" ]; then
    cat > "$SRC" <<'EOF'
#include <stdio.h>
#include <libusb.h>

int main(void)
{
    libusb_context *ctx = 0;
    if (libusb_init(&ctx) < 0) { fprintf(stderr, "libusb_init failed\n"); return 1; }

    libusb_device **list = 0;
    ssize_t n = libusb_get_device_list(ctx, &list);
    int hit = 0;

    for (ssize_t i = 0; i < n; i++) {
        struct libusb_device_descriptor d;
        if (libusb_get_device_descriptor(list[i], &d) < 0) continue;
        if (d.idVendor != 0x04b4) continue;
        if (d.idProduct != 0x00f1 && d.idProduct != 0x00f3) continue;

        libusb_device_handle *h = 0;
        if (libusb_open(list[i], &h) != 0) {
            fprintf(stderr, "打不开 04b4:%04x（udev 权限？先跑 sudo bash setup-root.sh）\n",
                    d.idProduct);
            continue;
        }
        hit = 1;
        printf("向 04b4:%04x 发送 RESETFX3 (bRequest=0xB1)...\n", d.idProduct);
        int r = libusb_control_transfer(h, 0x40, 0xB1, 0, 0, 0, 0, 5000);
        printf("  control_transfer = %d\n", r);
        if (r == LIBUSB_ERROR_NO_DEVICE)
            printf("  -4 = 设备已断开重启，这正是预期结果。\n");
        libusb_close(h);
    }

    libusb_free_device_list(list, 1);
    libusb_exit(ctx);
    if (!hit) fprintf(stderr, "未找到可操作的 04b4 设备\n");
    return hit ? 0 : 1;
}
EOF
    if ! gcc "$SRC" -o "$BIN" -I /usr/include/libusb-1.0 -lusb-1.0 2>/dev/null; then
        echo "编译复位工具失败（缺 gcc 或 libusb-1.0-dev）" >&2
        exit 1
    fi
fi

echo
"$BIN"
rc=$?

echo
echo "--- 等待重新枚举 ---"
for i in $(seq 1 20); do
    sleep 1
    if list_dev | grep -q "04b4:00f3"; then
        echo "  第 ${i}s 已回到 DFU 态:"
        show_state
        echo
        echo "下一步（不需要 sudo）："
        echo "  bash $SDR_DIR/verify-device.sh     # 会重新上传固件并跑完整验证"
        exit 0
    fi
done

echo "  20s 内未看到 00f3。当前状态:"
show_state || true
echo "  建议重新拔插一次 USB。"
exit "$rc"
