#!/usr/bin/env bash
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# ReSukiSU + SUSFS kernel builder for Xiaomi Poco F1 (beryllium), sdm845, 4.19
# ---------------------------------------------------------------------------

# ---- Configurable variables -----------------------------------------------
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${OUT_DIR:-${ROOT_DIR}/out}"
DIST_DIR="${DIST_DIR:-${ROOT_DIR}/dist}"
TOOLCHAIN_DIR="${TOOLCHAIN_DIR:-${HOME}/Coding/proton-clang}"
JOBS="${JOBS:-$(nproc)}"
KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-zen}"
KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-linux}"

# ReSukiSU commit to pin (reproducible build). beaaea0 = v4.1.0-1341-gbeaaea0e
RESUKISU_COMMIT="${RESUKISU_COMMIT:-beaaea0eb895dc41e7b9bf5e3f39e57aa9635bab}"
RESUKISU_REPO="https://github.com/ReSukiSU/ReSukiSU.git"

# Backports applied on top of ReSukiSU (committed with a recognizable name)
KSU_BACKPORT_PATCH="${ROOT_DIR}/KernelSU-backports.patch"
KSU_BACKPORT_COMMIT="ReSukiSU backports: independent hooks, sus_path app-flag, ksu_init_rc_hook"

DEFCONFIG_FRAGMENTS=(
	"arch/arm64/configs/vendor/sdm845-perf_defconfig"
	"arch/arm64/configs/vendor/xiaomi/sdm845-common.config"
	"arch/arm64/configs/vendor/xiaomi/beryllium.config"
)

export ARCH=arm64
export SUBARCH=arm64

# ---- Helpers ---------------------------------------------------------------
log() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

# ---- Setup ReSukiSU submodule at pinned commit + apply backports ----------
setup_resukisu() {
	if [[ ! -e "${ROOT_DIR}/KernelSU/.git" ]]; then
		log "Cloning ReSukiSU"
		git clone --filter=blob:none "$RESUKISU_REPO" "${ROOT_DIR}/KernelSU"
	fi

	log "Checking out ReSukiSU ${RESUKISU_COMMIT}"
	git -C "${ROOT_DIR}/KernelSU" fetch --unshallow 2>/dev/null ||
		git -C "${ROOT_DIR}/KernelSU" fetch --depth=1 origin "$RESUKISU_COMMIT"
	git -C "${ROOT_DIR}/KernelSU" checkout --detach "$RESUKISU_COMMIT"

	log "Wiring drivers/kernelsu"
	ln -sfn ../KernelSU/kernel "${ROOT_DIR}/drivers/kernelsu"
	grep -qE 'obj-\$\(CONFIG_KSU\)\s*\+= kernelsu/' "${ROOT_DIR}/drivers/Makefile" ||
		printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> "${ROOT_DIR}/drivers/Makefile"
	grep -q 'source "drivers/kernelsu/Kconfig"' "${ROOT_DIR}/drivers/Kconfig" ||
		sed -i '/^endmenu/i source "drivers/kernelsu/Kconfig"' "${ROOT_DIR}/drivers/Kconfig"

	# Apply + commit backports with a recognizable name (idempotent)
	if git -C "${ROOT_DIR}/KernelSU" log --oneline | grep -q "ReSukiSU backports:"; then
		log "KernelSU backports already committed"
	else
		git -C "${ROOT_DIR}/KernelSU" checkout -- kernel/ 2>/dev/null || true
		log "Applying KernelSU backports"
		(cd "${ROOT_DIR}/KernelSU" && git apply "${KSU_BACKPORT_PATCH}")
		git -C "${ROOT_DIR}/KernelSU" add -A
		git -C "${ROOT_DIR}/KernelSU" commit -m "$KSU_BACKPORT_COMMIT"
		log "Committed KernelSU backports"
	fi
}

# ---- Configure kernel (defconfig + KSU) ------------------------------------
# Use KCONFIG_NONINTERACTIVE + default answers so kconfig never blocks on
# (NEW) options during olddefconfig/syncconfig.
configure() {
	export KCONFIG_NONINTERACTIVE=1
	log "Merging defconfig"
	mkdir -p "$OUT_DIR"
	scripts/kconfig/merge_config.sh -O "$OUT_DIR" "${DEFCONFIG_FRAGMENTS[@]}" < /dev/null || true
	make -C "$ROOT_DIR" O="$OUT_DIR" ARCH=arm64 olddefconfig < /dev/null

	# Vendor techpack drivers are not clang-clean; relax -Werror
	log "Disabling -Werror in techpack"
	find "$ROOT_DIR/techpack" -name Kbuild -o -name Makefile |
		xargs grep -l -- "-Werror" 2>/dev/null |
		xargs -r sed -i 's/-Werror/-Wno-error/g' || true

	grep -qx 'CONFIG_KSU=y' "$OUT_DIR/.config" ||
		die "CONFIG_KSU was not enabled"
}

# ---- Build ----------------------------------------------------------------
build() {
	log "Building kernel with ${JOBS} jobs"
	export LD_LIBRARY_PATH="$TOOLCHAIN_DIR/lib:${LD_LIBRARY_PATH:-}"
	export KCONFIG_NONINTERACTIVE=1

	# KSU compat: 4.19 QTI exposes selinux_state struct (not legacy policydb).
	# Passed via KCFLAGS so KSU_COMMIT_SHA does not turn -dirty.
	make -C "$ROOT_DIR" -j"$JOBS" O="$OUT_DIR" < /dev/null \
		ARCH=arm64 \
		CC="$TOOLCHAIN_DIR/bin/clang" \
		CLANG_TRIPLE=aarch64-linux-gnu- \
		CROSS_COMPILE="$TOOLCHAIN_DIR/bin/aarch64-linux-gnu-" \
		CROSS_COMPILE_ARM32=arm-linux-gnueabi- \
		AR="$TOOLCHAIN_DIR/bin/llvm-ar" \
		NM="$TOOLCHAIN_DIR/bin/llvm-nm" \
		OBJCOPY="$TOOLCHAIN_DIR/bin/llvm-objcopy" \
		OBJDUMP="$TOOLCHAIN_DIR/bin/llvm-objdump" \
		STRIP="$TOOLCHAIN_DIR/bin/llvm-strip" \
		LLVM_IAS=1 \
		KBUILD_BUILD_USER="$KBUILD_BUILD_USER" \
		KBUILD_BUILD_HOST="$KBUILD_BUILD_HOST" \
		KCFLAGS=-DKSU_COMPAT_HAS_SELINUX_STATE

	[[ -s "$OUT_DIR/arch/arm64/boot/Image.gz-dtb" ]] ||
		die "Image.gz-dtb was not produced"
	log "Build complete"
	printf 'Image: %s\n' "$OUT_DIR/arch/arm64/boot/Image.gz-dtb"
}

# ---- Collect artifacts -----------------------------------------------------
collect() {
	local boot="$OUT_DIR/arch/arm64/boot"
	[[ -s "$boot/Image.gz-dtb" ]] || die "Image.gz-dtb missing"
	rm -rf "$DIST_DIR"
	mkdir -p "$DIST_DIR"
	cp -f "$boot/Image.gz" "$boot/Image.gz-dtb" "$OUT_DIR/.config" "$DIST_DIR/"
	log "Artifacts collected"
	printf 'Dist: %s\n' "$DIST_DIR"
}

usage() {
  cat <<EOF
Usage: $0 [build|setup|config|collect|clean]

Environment overrides:
  JOBS=N                Parallel build jobs (default: nproc)
  OUT_DIR=path          Kernel output directory
  DIST_DIR=path         Collected artifacts directory (default: ./dist)
  TC=path               Toolchain directory (default: ~/Coding/proton-clang)
  KBUILD_BUILD_USER=user Build user in kernel version string (default: zen)
  KBUILD_BUILD_HOST=host Build host in kernel version string (default: ubuntu)
  RESUKISU_COMMIT=sha   ReSukiSU revision to check out
EOF
}

clean() {
  log "Removing generated build output"
  rm -rf "$OUT_DIR"
}

# ---- Main -----------------------------------------------------------------
main() {
	cd "$ROOT_DIR"
	[[ -f Makefile && -d "arch/arm64/configs/vendor/xiaomi" ]] ||
		die "place build.sh in the kernel source root"
	for c in git make sed grep nproc; do need "$c"; done

	case "${1:-build}" in
		build)   setup_resukisu; configure; build; collect ;;
		collect) collect ;;
		setup)   setup_resukisu ;;
		config)  configure ;;
		clean)   clean ;;
		-h|--help|help) usage ;;
		*) usage >&2; exit 2 ;;
	esac
}

main "$@"
