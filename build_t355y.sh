#!/bin/bash
# ==============================================================================
# build_t355y.sh
#
# Standalone build script for Samsung SM-T355Y (Galaxy Tab A 8.0 LTE, msm8916)
# derived from the two scripts shipped in this kernel source tree:
#   - build_kernel.sh            (simple single-target example)
#   - build_msm8916_kernel.sh    (multi-device Samsung build dispatcher)
#
# This script exists because build_kernel.sh is hardcoded to a different
# device (gtelwifi_usa) and build_msm8916_kernel.sh expects Samsung's full
# "PLATFORM"/android tree layout (../../android/prebuilts/..., signclient.jar,
# etc.) which is NOT present in this stripped kernel-only source dump.
#
# IMPORTANT — READ BEFORE USING
# ------------------------------------------------------------------------------
# This source tree does NOT contain a defconfig built specifically for
# SM-T355Y (gt58lte, SEA/XSA region). build_msm8916_kernel.sh maps that model
# to VARIANT_DEFCONFIG=msm8916_sec_gt58lte_aus_defconfig, but only these
# gt58-family configs actually exist in arch/arm/configs/:
#     msm8916_sec_gt58lte_tmo_defconfig
#     msm8916_sec_gt58ltebmc_eur_defconfig
#     msm8916_sec_gt58wifi_eur_defconfig
# There is no *_aus / *_xsa / *_sea variant shipped here. This is a limitation
# of the source dump you uploaded, not of this script. You must pick a
# VARIANT_DEFCONFIG below yourself (default = gt58lte_tmo, the closest LTE
# variant) and be aware the resulting kernel may be missing SEA/XSA-specific
# board bring-up bits (RF, regulatory, etc.) unless you obtain the correct
# defconfig from Samsung's official opensource release for SM-T355Y and drop
# it into arch/arm/configs/ before building.
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# 1. Configuration (override any of these via environment variables)
# ------------------------------------------------------------------------------
KERNEL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCH=arm
JOBS="${JOBS:-$(nproc)}"

# Base + variant + selinux defconfig fragments, merged by scripts/kconfig/Makefile
KERNEL_DEFCONFIG="${KERNEL_DEFCONFIG:-msm8916_sec_defconfig}"
VARIANT_DEFCONFIG="${VARIANT_DEFCONFIG:-msm8916_sec_gt58lte_tmo_defconfig}"   # see warning above
SELINUX_DEFCONFIG="${SELINUX_DEFCONFIG:-selinux_defconfig}"

# Toolchain: arm-eabi-4.8, matching what build_kernel.sh / build_msm8916_kernel.sh expect.
# If you already have a toolchain on PATH, set TOOLCHAIN_BIN_PREFIX yourself and
# this script will skip downloading one.
TOOLCHAIN_DIR="${TOOLCHAIN_DIR:-$KERNEL_DIR/../toolchain/arm-eabi-4.8}"
TOOLCHAIN_REPO="${TOOLCHAIN_REPO:-https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/arm/arm-eabi-4.8}"
TOOLCHAIN_BRANCH="${TOOLCHAIN_BRANCH:-idea133}"   # 'master' has the binaries removed upstream
TOOLCHAIN_BIN_PREFIX="${TOOLCHAIN_BIN_PREFIX:-$TOOLCHAIN_DIR/bin/arm-eabi-}"

OUT_DIR="${OUT_DIR:-$KERNEL_DIR/out}"
DIST_DIR="${DIST_DIR:-$KERNEL_DIR/dist}"

BOARD_KERNEL_BASE=0x80000000
BOARD_KERNEL_PAGESIZE=2048
BOARD_KERNEL_TAGS_OFFSET=0x01E00000
BOARD_RAMDISK_OFFSET=0x02000000
BOARD_KERNEL_CMDLINE="console=ttyHSL0,115200,n8 androidboot.console=ttyHSL0 androidboot.hardware=qcom user_debug=31 msm_rtb.filter=0x3F ehci-hcd.park=3 androidboot.bootdevice=7824900.sdhci"

log() { echo -e "\n=== $* ===\n"; }

# ------------------------------------------------------------------------------
# 2. Toolchain
# ------------------------------------------------------------------------------
fetch_toolchain() {
	if [ -x "${TOOLCHAIN_BIN_PREFIX}gcc" ]; then
		log "Toolchain already present at $TOOLCHAIN_DIR"
		return
	fi
	log "Fetching prebuilt arm-eabi-4.8 toolchain (branch: $TOOLCHAIN_BRANCH)"
	mkdir -p "$(dirname "$TOOLCHAIN_DIR")"
	git clone --depth=1 --branch "$TOOLCHAIN_BRANCH" "$TOOLCHAIN_REPO" "$TOOLCHAIN_DIR"
}

# ------------------------------------------------------------------------------
# 3. Host package check (this old prebuilt gcc is a 32-bit binary on Linux)
# ------------------------------------------------------------------------------
check_host_deps() {
	log "Checking host build dependencies"
	local missing=()
	for bin in make bc python2 flex bison openssl; do
		command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
	done
	if [ "${#missing[@]}" -ne 0 ]; then
		echo "Missing tools: ${missing[*]}"
		echo "On Debian/Ubuntu install with:"
		echo "  sudo apt-get update && sudo apt-get install -y \\"
		echo "    build-essential bc python2 flex bison libssl-dev \\"
		echo "    lib32z1 lib32ncurses6 lib32stdc++6 libc6-i386 git"
		exit 1
	fi
	# python2 must resolve as 'python' for the old kbuild scripts
	mkdir -p "$KERNEL_DIR/bin"
	ln -sf "$(command -v python2)" "$KERNEL_DIR/bin/python"
	export PATH="$KERNEL_DIR/bin:$PATH"
}

# ------------------------------------------------------------------------------
# 4. Source fix: sound/soundopt.mk hardcodes GCC flags
#    (-fisolate-erroneous-paths-dereference needs GCC 6+,
#     -mtune=cortex-a57.cortex-a53 needs GCC 5+) that arm-eabi-4.8 (2013,
#    GCC 4.8) doesn't understand, so the build dies compiling sound_core.o
#    and drivers/misc/qcom/qdsp6v2/aac_in.o (both include this file). Wrap
#    every flag in kbuild's cc-option macro so unsupported flags are
#    silently dropped instead of erroring — works with any GCC version.
# ------------------------------------------------------------------------------
patch_soundopt() {
	local f="$KERNEL_DIR/sound/soundopt.mk"
	if grep -q "cc-option" "$f" 2>/dev/null; then
		log "sound/soundopt.mk already patched"
		return
	fi
	log "Patching sound/soundopt.mk for GCC 4.8 compatibility"
	cat > "$f" <<'EOF'

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
}

# ------------------------------------------------------------------------------
# 5. Kernel build
# ------------------------------------------------------------------------------
build_kernel() {
	log "Configuring kernel: $KERNEL_DEFCONFIG + VARIANT=$VARIANT_DEFCONFIG + SELINUX=$SELINUX_DEFCONFIG"
	mkdir -p "$OUT_DIR"

	make -C "$KERNEL_DIR" O="$OUT_DIR" ARCH=$ARCH \
		CROSS_COMPILE="$TOOLCHAIN_BIN_PREFIX" \
		"$KERNEL_DEFCONFIG" \
		VARIANT_DEFCONFIG="$VARIANT_DEFCONFIG" \
		SELINUX_DEFCONFIG="$SELINUX_DEFCONFIG"

	log "Building kernel Image + modules + dtbs ($JOBS jobs)"
	make -C "$KERNEL_DIR" O="$OUT_DIR" ARCH=$ARCH \
		CROSS_COMPILE="$TOOLCHAIN_BIN_PREFIX" -j"$JOBS"
}

# ------------------------------------------------------------------------------
# 6. Package: zImage + dt.img (device tree blob image via in-tree dtbTool)
# ------------------------------------------------------------------------------
package_outputs() {
	log "Packaging outputs"
	mkdir -p "$DIST_DIR"

	local zimage="$OUT_DIR/arch/arm/boot/Image"
	[ -f "$zimage" ] || zimage="$OUT_DIR/arch/arm/boot/zImage"
	cp "$zimage" "$DIST_DIR/zImage"

	if [ -d "$OUT_DIR/arch/arm/boot/dts" ]; then
		"$KERNEL_DIR/tools/dtbTool" -o "$DIST_DIR/dt.img" \
			-s "$BOARD_KERNEL_PAGESIZE" \
			-p "$OUT_DIR/scripts/dtc/" \
			"$OUT_DIR/arch/arm/boot/dts/"
	fi

	(cd "$DIST_DIR" && tar cvf SM-T355Y_kernel.tar zImage $( [ -f dt.img ] && echo dt.img ) )
	log "Done. Output in $DIST_DIR"
	ls -la "$DIST_DIR"
}

main() {
	check_host_deps
	fetch_toolchain
	patch_soundopt
	build_kernel
	package_outputs
}

main "$@"
