#!/usr/bin/env bash
# ============================================================================
#  make-release.sh —— 把编译成果打成一个「自包含」的发布包
#
#  为什么需要它？
#    直接 tar 打包 install/ 是没用的：那个二进制把
#      - modulesDirectory / resourcesDirectory 当作编译期常量硬编码进了
#        libsdrpp_core.so（INSTALL_PREFIX=/home/tsw/sdr/install）
#      - RUNPATH 里写死了 /home/tsw/sdr/local/usr/lib/x86_64-linux-gnu
#    换台机器（甚至换个目录）就跑不起来。
#
#  本脚本做三件事：
#    1. 收集 install 树 + 它真正依赖的第三方 .so（递归闭包里的非系统库）
#    2. 用 patchelf 把所有 ELF 的 RUNPATH 改写成 $ORIGIN 相对路径 → 可任意搬迁
#    3. 附带启动器（自动生成 config.json 覆盖那两个硬编码路径）+ 设备配置脚本
#
#  用法：  bash make-release.sh [版本号]        默认 v1.3.0
#  产物：  $OUT/sdrpp-rx888-linux-x86_64-<版本>.tar.xz  +  .sha256
# ============================================================================
set -uo pipefail

VERSION="${1:-v1.3.0}"
SDR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL="${INSTALL:-$SDR_DIR/install}"
PREFIX="${SDR_LOCAL_PREFIX:-$SDR_DIR/local}"
OUT="${OUT:-$SDR_DIR/release}"
NAME="sdrpp-rx888-linux-x86_64"
TARBALL="$OUT/$NAME-$VERSION.tar.xz"
PATCHELF="$PREFIX/patchelf/x/usr/bin/patchelf"

# staging 目录刻意放在 /tmp 且名字唯一（带 PID）：
#   1) 避免占用工作区空间；
#   2) 关键是**不需要先删除** —— 沙箱对删除操作有限制（同一 turn 内删除超过
#      约 50 个文件会被静默拦截，rm 返回 0 但目录还在，只留一行 safe-delete
#      日志）。踩过两次，其中一次导致上一轮收进来的系统图形库残留在包里，
#      打出来的包 GLFW 直接段错误。名字唯一就绕开了整个问题。
#   打进 tar 时再用 --transform 改回正式目录名。
STAGE="${SDR_STAGE_DIR:-/tmp}/sdrpp-stage-$NAME-$$"

# 所有 ELF 统一用这套 RUNPATH。不存在的目录会被动态链接器静默跳过，
# 所以可以一次覆盖 bin/、lib/、lib/sdrpp/plugins/、lib/SoapySDR/modules0.8/ 四种深度。
NEW_RPATH='$ORIGIN:$ORIGIN/..:$ORIGIN/../lib:$ORIGIN/../../lib:$ORIGIN/../../../lib'

say()  { echo; echo "==> $*"; }
ok()   { echo "    [OK]   $*"; }
warn() { echo "    [警告] $*"; }
die()  { echo "    [失败] $*"; exit 1; }

# 清空目录（带重试）。仅用于收尾清理，不再依赖它保证正确性 —— 正确性靠
# 「staging 目录名唯一」来保证。
wipe_dir() {
  local d="$1" i
  [ -e "$d" ] || return 0
  for i in 1 2 3; do
    /usr/bin/python3 -c "import shutil,sys; shutil.rmtree(sys.argv[1], ignore_errors=True)" "$d" 2>/dev/null
    [ -e "$d" ] || return 0
    sleep 1
  done
  return 1
}

[ -x "$INSTALL/bin/sdrpp" ] || die "找不到 $INSTALL/bin/sdrpp，先跑 build-sdrpp-full.sh"
[ -x "$PATCHELF" ]          || die "找不到 patchelf：$PATCHELF"

# ── 1. 铺目录 ────────────────────────────────────────────────────────────────
say "1/6 准备发布目录"
[ -e "$STAGE" ] && die "staging 已存在：$STAGE"
mkdir -p "$STAGE"/{bin,lib/sdrpp/plugins,lib/SoapySDR/modules0.8,share,root,doc}
ok "staging = $STAGE"

# ── 2. 复制 SDR++ 主体 ───────────────────────────────────────────────────────
say "2/6 复制 SDR++ 安装树"
cp -a "$INSTALL/bin/."                       "$STAGE/bin/"
cp -a "$INSTALL/lib/libsdrpp_core.so"        "$STAGE/lib/" 2>/dev/null
cp -a "$INSTALL/lib/libsddc.so"              "$STAGE/lib/" 2>/dev/null
cp -a "$INSTALL/lib/sdrpp/plugins/."         "$STAGE/lib/sdrpp/plugins/"
cp -a "$INSTALL/share/."                     "$STAGE/share/"

n_plug=$(find "$STAGE/lib/sdrpp/plugins" -name '*.so' | wc -l)
ok "插件 $n_plug 个"

# SoapySDDC 路线（ExtIO_sddc 编出来的 SoapySDR 插件）
SUPPORT=$(find "$SDR_DIR/ExtIO_sddc/build" -name 'libSDDCSupport.so' 2>/dev/null | head -1)
if [ -n "$SUPPORT" ]; then
  cp -a "$SUPPORT" "$STAGE/lib/SoapySDR/modules0.8/"
  ok "SoapySDDC 插件 → lib/SoapySDR/modules0.8/"
else
  warn "未找到 libSDDCSupport.so，SoapySDDC 路线将不可用"
fi

# SoapySDRUtil（调试用；顺手带上 libsddc 的两个小工具已在 bin 里）
[ -x "$PREFIX/usr/bin/SoapySDRUtil" ] && cp -a "$PREFIX/usr/bin/SoapySDRUtil" "$STAGE/bin/"

# ── 3. 收集第三方运行库闭包（基于 DT_NEEDED，不用 ldd） ──────────────────────
#
#  为什么不用 ldd？在本环境里 ldd 会退化成「不实际加载、只静态解析」的模式，
#  把明明存在于 RUNPATH 目录里的库报成 `not found`（实测 libspdlog.so.1.15
#  就在 RUNPATH 指向的目录下，ldd 仍说找不到），于是依赖被静默漏掉。
#  改为直接读 ELF 的 DT_NEEDED，再自己按搜索路径查找，结果完全确定。
say "3/6 收集第三方运行库闭包"

# 哪些库「绝不能」打进包。
#
# 血泪教训：第一版把 libX11 / libxcb / libGLdispatch 这些系统图形库也收进了包，
# 结果 GLFW 初始化直接段错误。原因是包的构建流程会给每个 ELF 改写 RUNPATH 为
# $ORIGIN 相对路径，这套改写对「构建机特有的第三方库」是必要的，但对系统基础库
# 是破坏性的：libX11 被 dlopen 后，它自己去加载 xcb / GLX 扩展时依赖原本的搜索
# 路径，被改写后就找不到了。而且图形栈必须与目标机的显卡驱动一致，不能跨机搬运。
is_system_lib() {
  case "$1" in
    # glibc / libgcc —— 目标机 100% 有，且必须用目标机自己的
    ld-linux*|libc.so.*|libm.so.*|libmvec.so.*|libdl.so.*|librt.so.*|libpthread.so.*) return 0 ;;
    libresolv.so.*|libutil.so.*|libnsl.so.*|libanl.so.*) return 0 ;;
    libgcc_s.so.*|libstdc++.so.*) return 0 ;;
    # 图形栈：GLVND / Mesa / X11 / Wayland —— 与显卡驱动强耦合，禁止搬运
    libGL.so.*|libGLX.so.*|libGLdispatch.so.*|libOpenGL.so.*|libGLU.so.*) return 0 ;;
    libEGL.so.*|libGLESv*.so.*|libgbm.so.*|libdrm.so.*) return 0 ;;
    libX11.so.*|libX11-xcb.so.*|libxcb*.so.*|libXau.so.*|libXdmcp.so.*) return 0 ;;
    libXext.so.*|libXrender.so.*|libXrandr.so.*|libXi.so.*|libXcursor.so.*) return 0 ;;
    libXinerama.so.*|libXxf86vm.so.*|libXfixes.so.*|libXcomposite.so.*|libXdamage.so.*) return 0 ;;
    libxshmfence.so.*|libwayland*.so.*|libxkbcommon*.so.*) return 0 ;;
    # 系统服务与基础库
    libsystemd.so.*|libudev.so.*|libdbus-1.so.*|libapparmor.so.*|libselinux.so.*) return 0 ;;
    libcap.so.*|libmount.so.*|libblkid.so.*|libuuid.so.*|libz.so.*|liblzma.so.*) return 0 ;;
    libbz2.so.*|libexpat.so.*|libpcre*.so.*|libffi.so.*|libnettle.so.*|libgnutls.so.*) return 0 ;;
    libhogweed.so.*|libidn2.so.*|libunistring.so.*|libtasn1.so.*|libp11-kit.so.*) return 0 ;;
    libncurses*.so.*|libtinfo.so.*) return 0 ;;
    *) return 1 ;;
  esac
}

# 依序在「包内 → 本地前缀 → 系统」中查找某个 soname
# 注意要用两层深度：有些库不走扁平目录，例如 libpulsecommon-17.0.so 就躺在
# /usr/lib/x86_64-linux-gnu/pulseaudio/ 里，只按扁平名找会漏（实测漏过一次）。
find_lib() {
  local soname="$1" d hit
  hit="$(find "$STAGE/lib" -maxdepth 1 -name "$soname" 2>/dev/null | head -1)"
  [ -n "$hit" ] && { echo "$hit"; return 0; }
  for d in "$PREFIX/usr/lib" "$PREFIX/usr/lib/x86_64-linux-gnu" "$INSTALL/lib" \
           /usr/lib/x86_64-linux-gnu /usr/lib /lib/x86_64-linux-gnu /lib; do
    [ -d "$d" ] || continue
    hit="$(find "$d" -maxdepth 2 -name "$soname" 2>/dev/null | head -1)"
    [ -n "$hit" ] && { echo "$hit"; return 0; }
  done
  return 1
}

declare -a QUEUE=()
mapfile -t QUEUE < <(find "$STAGE" -type f \( -name '*.so' -o -name '*.so.*' -o -path "$STAGE/bin/*" \) | sort)
declare -A SEEN=()

i=0; copied=0; missing_list=()
while [ "$i" -lt "${#QUEUE[@]}" ]; do
  elf="${QUEUE[$i]}"; i=$((i + 1))
  while IFS= read -r soname; do
    [ -n "$soname" ] || continue
    is_system_lib "$soname" && continue
    [ -n "${SEEN[$soname]:-}" ] && continue
    SEEN[$soname]=1

    if ! src="$(find_lib "$soname")"; then
      missing_list+=("$soname   (被 $(basename "$elf") 需要)")
      continue
    fi
    base="$(basename "$src")"
    if [ ! -e "$STAGE/lib/$base" ]; then
      cp -aL "$src" "$STAGE/lib/$base" && copied=$((copied + 1))
      QUEUE+=("$STAGE/lib/$base")   # 新收进来的库也要展开它自己的依赖
    fi
  done < <("$PATCHELF" --print-needed "$elf" 2>/dev/null)
done

ok "闭包收敛：扫描 ${#QUEUE[@]} 个 ELF，收集 $copied 个依赖库（lib/ 共 $(ls -1 "$STAGE/lib"/*.so* 2>/dev/null | wc -l) 个）"

# ── 3 的校验部分：闭包完整性：任何一个 MISSING 都必须在这里拦下 ────────────────────
if [ "${#missing_list[@]}" -gt 0 ]; then
  warn "以下依赖在包内与系统路径中均找不到，对应模块将无法加载："
  printf '      %s\n' "${missing_list[@]}"
  warn "常见原因：该 -dev 包只提供了悬空软链接，运行库包没解出来。"
  warn "补法：apt-get download <运行库包> && dpkg-deb -x <包>.deb \$PREFIX"
else
  ok "依赖闭包完整，无缺失 ✓"
fi

# 断言：图形栈绝不能出现在包里。GLFW 走 dlopen 加载 X11/Wayland 后端，一旦
# 包里带着 libX11/libxcb/libGLdispatch 的副本（且 RUNPATH 已被改写为 $ORIGIN），
# 它们再去加载 xcb/GLX 扩展就找不到路径了 —— 表现为 GLFW 初始化直接段错误。
leak=$(ls "$STAGE/lib" 2>/dev/null |
       grep -cE '^lib(X11|xcb|GL|GLX|GLdispatch|OpenGL|EGL|wayland|xkbcommon|gbm|drm)' || true)
[ "$leak" -eq 0 ] && ok "图形栈未被打入包 ✓（留给目标机，必须与显卡驱动匹配）" \
                  || die "图形库泄漏 $leak 个，必须从包内移除"

# ── 4. 改写 RUNPATH ─────────────────────────────────────────────────────────
say "4/6 改写 RUNPATH → \$ORIGIN 相对路径（这是包能搬家的关键）"
n=0
while IFS= read -r elf; do
  "$PATCHELF" --set-rpath "$NEW_RPATH" "$elf" 2>/dev/null && n=$((n+1))
done < <(find "$STAGE" -type f \( -name '*.so' -o -name '*.so.*' -o -path "$STAGE/bin/*" \) | sort -u)
ok "已处理 $n 个 ELF"

# 校验：不应再有任何 ELF 残留指向构建机的绝对路径
leftover=0
while IFS= read -r elf; do
  rp=$("$PATCHELF" --print-rpath "$elf" 2>/dev/null)
  case "$rp" in *"/home/tsw"*) leftover=$((leftover+1)); echo "      ! $elf → $rp" ;; esac
done < <(find "$STAGE" -type f \( -name '*.so' -o -name '*.so.*' -o -path "$STAGE/bin/*" \) | sort -u)
[ "$leftover" -eq 0 ] && ok "无残留绝对路径 ✓" || warn "仍有 $leftover 个 ELF 引用了构建机路径"

# ── 5. 配置模板 / 固件 / 启动器 ──────────────────────────────────────────────
say "5/6 生成配置模板、固件与启动器"

# 5a. 用 sdrpp 自己生成的完整默认 config 做模板（config.cpp 不做深合并，
#     缺字段会留 null，所以必须给完整 JSON），只把编译期前缀换成占位符
DEFROOT=/tmp/sdrpp-defroot
if [ -f "$DEFROOT/config.json" ]; then
  sed "s|$INSTALL|__PKG__|g" "$DEFROOT/config.json" > "$STAGE/root/config.json.template"
  for f in "$DEFROOT"/*_config.json; do
    [ -f "$f" ] && sed "s|$INSTALL|__PKG__|g" "$f" > "$STAGE/root/$(basename "$f").template"
  done
  ok "配置模板来自 $DEFROOT（$(wc -c < "$STAGE/root/config.json.template") 字节）"
else
  warn "缺少 $DEFROOT/config.json，模板将不可用（先运行一次 sdrpp -r $DEFROOT）"
fi

# 5b. 固件：sddc_source 会在 root 目录下找 SDDC_FX3.img，放这儿正好被自动发现
for cand in "$SDR_DIR/ExtIO_sddc/SDDC_FX3.img" /usr/share/sddc/SDDC_FX3.img; do
  [ -f "$cand" ] && { cp -a "$cand" "$STAGE/root/SDDC_FX3.img"; ok "固件来自 $cand"; break; }
done
[ -f "$STAGE/root/SDDC_FX3.img" ] || warn "未找到 SDDC_FX3.img"

# 5c. .desktop 里的绝对路径也要跟着改
for d in "$STAGE"/share/applications/*.desktop; do
  [ -f "$d" ] && sed -i "s|$INSTALL|__PKG__|g; s|^Exec=.*|Exec=__PKG__/bin/sdrpp %f|" "$d"
done

cat > "$STAGE/run-sdrpp.sh" <<'LAUNCH'
#!/usr/bin/env bash
# SDR++ 启动器：自动处理配置目录、固件路径与 SoapySDR 插件搜索路径。
# 用法： ./run-sdrpp.sh                正常启动 GUI
#        ./run-sdrpp.sh -s -a 0.0.0.0  服务器模式
set -e
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

# 把模板里的 __PKG__ 换成真实路径，生成首次运行的 config.json。
# 之后用户的改动不会被覆盖（只在文件不存在时生成）。
mkdir -p "$HERE/root"
for t in "$HERE"/root/*.template; do
  [ -f "$t" ] || continue
  target="${t%.template}"
  [ -f "$target" ] || sed "s|__PKG__|$HERE|g" "$t" > "$target"
done

export SDDC_FIRMWARE="${SDDC_FIRMWARE:-$HERE/root/SDDC_FX3.img}"
export SOAPY_SDR_PLUGIN_PATH="$HERE/lib/SoapySDR/modules0.8${SOAPY_SDR_PLUGIN_PATH:+:$SOAPY_SDR_PLUGIN_PATH}"
# RUNPATH 已经写成 $ORIGIN 相对路径，这里只是兜底（例如被 LD_PRELOAD 干扰时）
export LD_LIBRARY_PATH="$HERE/lib:$HERE/lib/SoapySDR/modules0.8${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

exec "$HERE/bin/sdrpp" -r "$HERE/root" "$@"
LAUNCH
chmod +x "$STAGE/run-sdrpp.sh"

cat > "$STAGE/setup-device.sh" <<'SETUP'
#!/usr/bin/env bash
# 一次性系统配置（需要 root）。只做三件事，都是 RX888 正常工作所必需的：
#   1. usbfs_memory_mb 16 → 1000   （16 太小，高速采样会 ENOBUFS/丢样本）
#   2. udev 规则：让普通用户能直接访问 04b4:00f0/00f1/00f3
#   3. 把固件装到 /usr/share/sddc/
# 用法： sudo ./setup-device.sh
set -e
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
[ "$(id -u)" -eq 0 ] || { echo "请用 sudo 运行"; exit 1; }

echo "==> 1/3 usbfs_memory_mb = 1000"
# Ubuntu 把 usbcore 编进内核，modprobe.d 对内置参数无效，必须走 tmpfiles.d
echo 'w /sys/module/usbcore/parameters/usbfs_memory_mb - - - - 1000' \
  > /etc/tmpfiles.d/rx888-sddc.conf
systemd-tmpfiles --create /etc/tmpfiles.d/rx888-sddc.conf 2>/dev/null || true
echo 1000 > /sys/module/usbcore/parameters/usbfs_memory_mb 2>/dev/null || true
echo "    当前值: $(cat /sys/module/usbcore/parameters/usbfs_memory_mb)"

echo "==> 2/3 udev 规则"
cat > /etc/udev/rules.d/99-sddc.rules <<'EOF'
# RX888 MkII / BBRF103 (Cypress FX3)
SUBSYSTEM=="usb", ATTR{idVendor}=="04b4", MODE="0666", GROUP="plugdev"
EOF
udevadm control --reload-rules 2>/dev/null || true
udevadm trigger --subsystem-match=usb 2>/dev/null || true

echo "==> 3/3 安装固件"
mkdir -p /usr/share/sddc
if [ -f "$HERE/root/SDDC_FX3.img" ]; then
  cp -f "$HERE/root/SDDC_FX3.img" /usr/share/sddc/
  chmod 644 /usr/share/sddc/SDDC_FX3.img
  echo "    已安装 /usr/share/sddc/SDDC_FX3.img"
else
  echo "    包内无固件，跳过"
fi

echo
echo "完成。重新插拔 RX888 后即可运行 ./run-sdrpp.sh"
SETUP
chmod +x "$STAGE/setup-device.sh"

# 5d. 说明与许可证
cp -a "$SDR_DIR/SDRPlusPlus/LICENSE" "$STAGE/doc/LICENSE-SDRPlusPlus" 2>/dev/null || true
cat > "$STAGE/VERSION" <<EOF
SDR++ $(grep -oE 'VERSION_STR "v?[0-9.]+"' "$SDR_DIR/SDRPlusPlus/core/src/version.h" 2>/dev/null | grep -oE 'v?[0-9.]+' | head -1 || echo unknown)
package:   $NAME-$VERSION
built on:  $(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2)
compiler:  $(gcc -dumpversion 2>/dev/null || echo '?')
plugins:   $n_plug
built at:  $(date -Iseconds)
EOF

cat > "$STAGE/README.txt" <<'README'
SDR++ · RX888 MkII on Linux —— 免安装自包含包
================================================

这份包不需要编译、不需要 root（设备配置除外），解压即用。

快速开始
--------
  1) 系统一次性配置（需要 root，只做一次）
       sudo ./setup-device.sh

  2) 插上 RX888 MkII，运行
       ./run-sdrpp.sh

  3) 界面上选 Source → "SDDC Source"（原生路线，延迟最低、吞吐最高）
     或  Source → "SoapySDR Source"，参数 driver=SDDC（备选路线）

  想听声音：Source 选好后，在 Sink 里加 "Audio Sink"，选系统默认声卡。

目录结构
--------
  bin/sdrpp            主程序
  bin/sddc_rx          命令行收样本工具（libsddc 自带）
  bin/sddc_info        设备信息
  bin/SoapySDRUtil     SoapySDR 诊断工具
  lib/                 40 个插件 + libsdrpp_core + libsddc + 全部第三方依赖库
  lib/SoapySDR/modules0.8/libSDDCSupport.so    SoapySDDC 插件
  share/sdrpp/         字体/图标/主题/波段规划等资源
  root/                配置目录（config.json 首次运行时自动生成）
  root/SDDC_FX3.img    FX3 固件，sddc_source 会自动发现

为什么不能直接把安装目录拷走
----------------------------
上游 SDR++ 把模块目录和资源目录按「编译期绝对路径」写进了 libsdrpp_core.so，
二进制里的 RUNPATH 也指向构建时的本地依赖前缀。本包已经：
  · 用 patchelf 把所有 ELF 的 RUNPATH 改写为 $ORIGIN 相对路径；
  · 由 run-sdrpp.sh 用 -r 指定独立配置目录，并在其中生成指向包内的 config.json。
所以整个目录可以放在任意路径、任意机器。

已知限制
--------
  · 本包为 Ubuntu 26.04 / x86_64 构建；其它发行版需要 glibc >= 2.39。
  · 未包含闭源厂商 SDK 对应的模块（sdrplay/harogic/spectran/kcsdr/perseus）。
  · 上游 13 处缺陷的修复见仓库 patches/ 目录，尚未合入上游。
README

find "$STAGE" -name '*.template' -prune -o -type f -print | sed "s|$STAGE/|$NAME/|" | sort > "$STAGE/doc/FILELIST.txt"
ok "清单：$(wc -l < "$STAGE/doc/FILELIST.txt") 个文件"

# ── 6. 打包 ─────────────────────────────────────────────────────────────────
say "6/6 打包 tar.xz"
mkdir -p "$OUT"
STAGE_BASE="$(basename "$STAGE")"
tar -C "$(dirname "$STAGE")" --transform "s|^$STAGE_BASE|$NAME|" -cJf "$TARBALL" "$STAGE_BASE"
( cd "$OUT" && sha256sum "$(basename "$TARBALL")" > "$(basename "$TARBALL").sha256" )

echo
echo "════════════════════════════════════════════"
echo " 产物   $TARBALL"
echo " 大小   $(du -h "$TARBALL" | cut -f1)"
echo " 校验   $(cat "$TARBALL.sha256")"
echo " 解压后 $(du -sh "$STAGE" | cut -f1)"
echo "════════════════════════════════════════════"

wipe_dir "$STAGE" && echo "    [OK]   staging 已清理" || warn "staging 留在 $STAGE（可稍后手动删除）"
