#!/bin/bash

set -euo pipefail

echo "Compile is beginning..."

KERNEL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCH=arm

# ---------------- Toolchain & env setup ----------------
TOOLCHAIN_DIR="${TOOLCHAIN_DIR:-$KERNEL_DIR/../toolchain/arm-eabi-4.8}"
TOOLCHAIN_REPO="${TOOLCHAIN_REPO:-https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/arm/arm-eabi-4.8}"
TOOLCHAIN_BRANCH="${TOOLCHAIN_BRANCH:-idea133}"   # 'master' has the binaries removed upstream
CROSS_COMPILE="${CROSS_COMPILE:-$TOOLCHAIN_DIR/bin/arm-eabi-}"

export CCACHE_DIR="${CCACHE_DIR:-$HOME/.cache/ccache_mikernel}"
export CCACHE_COMPILERCHECK=content
export CCACHE_SLOPPINESS=time_macros,include_file_mtime,include_file_ctime
export PATH="/usr/lib/ccache:$PATH"

KERNEL_DEFCONFIG="${KERNEL_DEFCONFIG:-msm8916_sec_defconfig}"
VARIANT_DEFCONFIG="${VARIANT_DEFCONFIG:-msm8916_sec_gt58lte_tmo_defconfig}"
SELINUX_DEFCONFIG="${SELINUX_DEFCONFIG:-selinux_defconfig}"

dts_source="${dts_source:-arch/arm/boot/dts}"

MAKE_ARGS="ARCH=$ARCH \
  O=out \
  CROSS_COMPILE=$CROSS_COMPILE"

echo "TOOLCHAIN_DIR: [$TOOLCHAIN_DIR]"
echo "CCACHE_DIR: [$CCACHE_DIR]"
echo "KERNEL_DEFCONFIG: [$KERNEL_DEFCONFIG]"
echo "VARIANT_DEFCONFIG: [$VARIANT_DEFCONFIG]"

# ---------------- Fetch toolchain if missing ----------------
if [ ! -x "${CROSS_COMPILE}gcc" ]; then
  echo "Fetching prebuilt arm-eabi-4.8 toolchain (branch: $TOOLCHAIN_BRANCH)..."
  mkdir -p "$(dirname "$TOOLCHAIN_DIR")"
  git clone --depth=1 --branch "$TOOLCHAIN_BRANCH" "$TOOLCHAIN_REPO" "$TOOLCHAIN_DIR"
  chmod -R +x "$TOOLCHAIN_DIR/bin"
fi

# ---------------- Host dependency / python2 shim ----------------
for bin in make bc flex bison openssl; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: missing host tool: $bin" >&2; exit 1; }
done
if command -v python2 >/dev/null 2>&1; then
  mkdir -p "$KERNEL_DIR/bin"
  ln -sf "$(command -v python2)" "$KERNEL_DIR/bin/python"
  export PATH="$KERNEL_DIR/bin:$PATH"
elif ! command -v python >/dev/null 2>&1; then
  echo "ERROR: need python2 (or a 'python' shim pointing at it) for old kbuild scripts." >&2
  exit 1
fi

# ---------------- Sanity check: toolchain resolvable ----------------
if ! command -v "${CROSS_COMPILE}gcc" >/dev/null 2>&1; then
  echo "ERROR: ${CROSS_COMPILE}gcc not found on PATH. Check TOOLCHAIN_DIR." >&2
  exit 1
fi

# ---------------- Back up dts (kept from test.sh, arm32 path) ----------------
if [ -d "$dts_source" ] && [ ! -d ".dts.bak" ]; then
  cp -a "$dts_source" .dts.bak
fi

# ---------------- Config generation ----------------
if [ ! -f "out/.config" ]; then
  echo "Generating defconfig [$KERNEL_DEFCONFIG + $VARIANT_DEFCONFIG + $SELINUX_DEFCONFIG]......."
  make $MAKE_ARGS "$KERNEL_DEFCONFIG" \
    VARIANT_DEFCONFIG="$VARIANT_DEFCONFIG" \
    SELINUX_DEFCONFIG="$SELINUX_DEFCONFIG"
else
  echo "Existing out/.config found, skipping defconfig generation."
fi

# ---------------- Build ----------------
make $MAKE_ARGS -j"$(nproc)"

if [ -f "out/arch/arm/boot/Image" ] || [ -f "out/arch/arm/boot/zImage" ]; then
    echo "Kernel image exists. Build successful."
else
    echo "No kernel image found in out/arch/arm/boot/. Build failed."
    exit 1
fi

echo "Generating [out/arch/arm/boot/dtb]......"
find out/arch/arm/boot/dts -name '*.dtb' -exec cat {} + >out/arch/arm/boot/dtb

# Restore original dts
if [ -d ".dts.bak" ]; then
  rm -rf "${dts_source}"
  mv .dts.bak "${dts_source}"
else
  echo "WARNING: .dts.bak not found, skipping dts restore."
fi

rm -rf anykernel/kernels/
mkdir -p anykernel/kernels/gt58/

echo ".............Exporting the required images............."

zimage="out/arch/arm/boot/Image"
[ -f "$zimage" ] || zimage="out/arch/arm/boot/zImage"
cp "$zimage" anykernel/kernels/gt58/
cp out/arch/arm/boot/dtb anykernel/kernels/gt58/

if [ -f "out/arch/arm/boot/dtbo.img" ]; then
  cp out/arch/arm/boot/dtbo.img anykernel/kernels/gt58/
else
  echo "NOTE: out/arch/arm/boot/dtbo.img not found — skipping (expected on this kernel)."
fi

echo "Build finished."

# ------------- Package flashable zip -------------
cd anykernel
ZIP_FILENAME=SM-T355Y-Kernel_v1.zip
zip -r9 "$ZIP_FILENAME" ./* -x .git .gitignore 'out/*' './*.zip'
mv "$ZIP_FILENAME" ../
cd ..
echo "Done. The flashable zip is: [./$ZIP_FILENAME]"
