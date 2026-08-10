#!/bin/bash
# ==============================================================================
# build-gt58.sh
#
# Kernel build script for Samsung SM-T355Y (Galaxy Tab A 8.0 LTE, msm8916).
#
# This is test.sh (MIUI/umi build script: ccache, AnyKernel3 zip packaging,
# dts backup/restore, susfs-friendly layout) with its device-specific pieces
# replaced by the toolchain/arch/defconfig values from core.sh, which is the
# script that has actually built this kernel successfully:
#   - ARCH=arm            (was arm64)
#   - arm-eabi-4.8 gcc    (was Neutron Clang, aarch64)
#   - msm8916_sec_defconfig + VARIANT_DEFCONFIG + SELINUX_DEFCONFIG
#     (was vendor/umi_defconfig — that's a different device's defconfig)
#   - sound/soundopt.mk GCC-4.8 compat patch (required, see core.sh)
#   - python2 shim (old kbuild scripts call `python`, need it to resolve py2)
#
# Kept from test.sh: ccache, dts backup/restore around the build, AnyKernel3
# zip packaging at the end.
#
# TODO / verify before relying on this:
#   - dtbo.img: msm8916/Lollipop-era kernels normally don't produce one.
#     Copy is now conditional so it won't hard-fail; delete the block below
#     if your device never had dtbo to begin with.
#   - anykernel/anykernel.sh is assumed to already exist in your tree (same
#     assumption test.sh made) — this script does not create it.
#   - VARIANT_DEFCONFIG default below matches core.sh's chosen fallback
#     (gt58lte_tmo) since no exact SM-T355Y/gt58lte_aus defconfig ships in
#     this source. Override via env if you have the correct one.
# ==============================================================================

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

# ---------------- Patch sound/soundopt.mk for GCC 4.8 compatibility ----------------
# Required: this file hardcodes GCC 5+/6+-only flags that arm-eabi-4.8 chokes
# on when compiling sound_core.o and qdsp6v2/aac_in.o. Wrap in cc-option so
# unsupported flags are silently dropped instead of erroring the build.
SOUNDOPT="$KERNEL_DIR/sound/soundopt.mk"
if [ -f "$SOUNDOPT" ] && ! grep -q "cc-option" "$SOUNDOPT" 2>/dev/null; then
  echo "Patching sound/soundopt.mk for GCC 4.8 compatibility..."
  cat > "$SOUNDOPT" <<'EOF'

ccflags-y ?=
ccflags-y += -O1 \
          $(call cc-option,-fthread-jumps) \
          $(call cc-option,-falign-functions) \
          $(call cc-option,-falign-jumps) \
          $(call cc-option,-falign-loops) \
          $(call cc-option,-falign-labels) \
          $(call cc-option,-fcrossjumping) \
          $(call cc-option,-fcse-follow-jumps) \
          $(call cc-option,-fcse-skip-blocks) \
          $(call cc-option,-fexpensive-optimizations) \
          $(call cc-option,-fgcse) \
          $(call cc-option,-fgcse-lm) \
          $(call cc-option,-fhoist-adjacent-loads) \
          $(call cc-option,-finline-small-functions) \
          $(call cc-option,-findirect-inlining) \
          $(call cc-option,-fipa-cp) \
          $(call cc-option,-fipa-sra) \
          $(call cc-option,-fisolate-erroneous-paths-dereference) \
          $(call cc-option,-foptimize-sibling-calls) \
          $(call cc-option,-foptimize-strlen) \
          $(call cc-option,-fpeephole2) \
          $(call cc-option,-frerun-cse-after-loop) \
          $(call cc-option,-fstrict-aliasing) \
          $(call cc-option,-ftree-switch-conversion) \
          $(call cc-option,-ftree-tail-merge) \
          $(call cc-option,-ftree-pre) \
          $(call cc-option,-ftree-vrp) \
          $(call cc-option,-mtune=cortex-a57.cortex-a53)
EOF
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

# dtbo.img: only copy if it actually exists (this kernel generation likely
# has no dtbo concept — see header note above).
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
