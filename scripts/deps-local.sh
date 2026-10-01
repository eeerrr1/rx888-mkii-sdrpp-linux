#!/usr/bin/env bash
# deps-local.sh — 免 root 把 SDR++ 的构建依赖部署到本地前缀
#
# 原理：apt-get download 不需要 root（只需能读包索引 + 当前目录可写），
#       再用 dpkg-deb -x 把 .deb 解到 $PREFIX/usr，等价于安装到 /usr。
#       最后重定位 .pc 文件，让 pkg-config / cmake 指向本地前缀。
#
# 用法： bash deps-local.sh
# 产物： $PREFIX/usr 下的头文件 + 库；$PREFIX/env.sh 环境变量脚本

set -uo pipefail

PREFIX="${PREFIX:-/home/tsw/sdr/local}"
PREFIX="${PREFIX%/}"
DEBDIR="$PREFIX/debs"

mkdir -p "$DEBDIR" "$PREFIX/usr" || exit 1

# 需要的包：dev 包提供头文件/.pc/符号链接，运行库包提供 SONAME 实体文件
PKGS=(
  # FFTW (pkg-config: fftw3f)
  libfftw3-dev libfftw3-double3 libfftw3-single3 libfftw3-long3 libfftw3-quad3
  # zstd (pkg-config: libzstd)
  libzstd-dev libzstd1
  # GLFW (pkg-config: glfw3)
  libglfw3-dev libglfw3
  # VOLK (pkg-config: volk)
  libvolk-dev libvolk3.3
  # OpenGL (cmake find_package(OpenGL))
  # 注意：libgl-dev/libopengl-dev/libglx-dev 只提供 .so 软链接（如 libOpenGL.so ->
  # libOpenGL.so.0），实体文件在运行库包里。不一起解出来就会得到悬空链接，
  # CMake 会报 "missing: OPENGL_opengl_LIBRARY OPENGL_glx_LIBRARY"。
  libgl-dev libglvnd-dev libopengl-dev libglx-dev
  libgl1 libopengl0 libglx0 libglvnd0
  # SoapySDR (pkg-config: SoapySDR) —— 用于路线1 soapy_source
  libsoapysdr-dev libsoapysdr0.8 soapysdr-tools
)

FAILED=()

echo "=============================================="
echo " 本地依赖前缀: $PREFIX"
echo "=============================================="

command -v dpkg-deb >/dev/null || { echo "缺少 dpkg-deb，无法解包"; exit 1; }

echo
echo "==> 步骤 1/4：下载 .deb（无需 root）"
cd "$DEBDIR" || exit 1
for p in "${PKGS[@]}"; do
  if compgen -G "${p}_*.deb" >/dev/null 2>&1; then
    printf "  [已有] %s\n" "$p"
    continue
  fi
  printf "  [下载] %-22s " "$p"
  if apt-get download "$p" >/dev/null 2>&1 && compgen -G "${p}_*.deb" >/dev/null 2>&1; then
    echo "OK"
  else
    echo "失败"
    FAILED+=("$p")
  fi
done

if [ "${#FAILED[@]}" -gt 0 ]; then
  echo "  警告：以下包下载失败 -> ${FAILED[*]}"
fi

echo
echo "==> 步骤 2/4：解包到 $PREFIX/usr"
rm -rf "$PREFIX/usr"
mkdir -p "$PREFIX/usr"
n=0
for f in "$DEBDIR"/*.deb; do
  [ -f "$f" ] || continue
  if dpkg-deb -x "$f" "$PREFIX" 2>/dev/null; then
    n=$((n + 1))
  else
    echo "  解包失败: $(basename "$f")"
  fi
done
echo "  已解包 $n 个 .deb"

echo
echo "==> 步骤 3/4：重定位 .pc 与清理 Requires.private"
pc_count=0
while IFS= read -r f; do
  [ -f "$f" ] || continue
  # 幂等：先剥掉历史上可能已注入的本地前缀（脚本会被反复执行，不做这一步
  # 就会每跑一次叠加一层前缀）。注意只剥完整 $PREFIX，不能剥 $PREFIX/usr ——
  # 后者会把已写好的 prefix=$PREFIX/usr 剥成空值，${prefix}/lib 塌成 /lib。
  while grep -qF "$PREFIX" "$f"; do
    sed -i "s|$PREFIX||g" "$f"
  done
  # 注意：有些 .pc 写作 prefix=/usr（行尾无斜杠），必须先单独处理，
  # 否则简单的 s|/usr/|...|g 会漏掉它，导致 pkg-config 静默回退到系统路径。
  sed -i -E "s|^prefix=/usr\$|prefix=$PREFIX/usr|" "$f"
  sed -i -E "s|^exec_prefix=/usr\$|exec_prefix=$PREFIX/usr|" "$f"
  sed -i "s|/usr/|$PREFIX/usr/|g" "$f"
  # 共享库链接不需要 Requires.private，且缺 x11-dev 等会让 pkgconf 报错
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
case ":\${PKG_CONFIG_PATH:-}:" in
  *":\$_PC1:"*) ;;
  *) export PKG_CONFIG_PATH="\$_PC1:\$_PC2:\${PKG_CONFIG_PATH:-}" ;;
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
unset _PC1 _PC2 _LD
EOF
echo "  已写入 $PREFIX/env.sh"

echo
echo "==> 校验（模拟激活后 pkg-config 能否找到，且路径必须指向本地前缀）"
export PKG_CONFIG_PATH="$PREFIX/usr/lib/x86_64-linux-gnu/pkgconfig:$PREFIX/usr/share/pkgconfig"
ok=0; bad=0
for m in fftw3f volk glfw3 libzstd SoapySDR; do
  printf "  %-10s " "$m"
  if ! v=$(pkg-config --modversion "$m" 2>/dev/null); then
    echo "未找到  <== 异常"; bad=$((bad + 1)); continue
  fi
  OUT="$(pkg-config --cflags --libs "$m" 2>&1)"
  printf "v%-9s %s\n" "$v" "$OUT"
  # 关键检查：输出的 -I/-L 必须落在本地前缀内，否则说明重定位失败，
  # 编译时会去系统路径找头文件并失败（fftw3f.pc 就踩过这个坑）。
  if pkg-config --cflags-only-I "$m" 2>/dev/null | grep -q "$PREFIX/usr/include" \
     && pkg-config --libs-only-L "$m" 2>/dev/null | grep -q "$PREFIX/usr/lib"; then
    ok=$((ok + 1))
  else
    echo "      ^ 重定位异常：-I/-L 未指向 $PREFIX"; bad=$((bad + 1))
  fi
done
echo "  结果: $ok 正确 / $bad 异常"
echo
echo "完成。使用前请执行:  source $PREFIX/env.sh"
