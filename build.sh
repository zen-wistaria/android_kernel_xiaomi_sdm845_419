#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "ERROR: script exited at line $LINENO (exit code $?)"' ERR

# ---------------------------------------------------------------------------
# Kernel builder for Xiaomi Poco F1 (beryllium), sdm845, 4.19
# ---------------------------------------------------------------------------

# ---- Configurable variables -----------------------------------------------
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${OUT_DIR:-${ROOT_DIR}/out}"
DIST_DIR="${DIST_DIR:-${ROOT_DIR}/dist}"
TOOLCHAIN_DIR="${TOOLCHAIN_DIR:-${HOME}/Coding/proton-clang}"
JOBS="${JOBS:-$(nproc)}"
KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-zen}"
KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-linux}"

# NoMount commit to pin (reproducible build)
NOMOUNT_REPO="https://github.com/maxsteeel/nomount.git"
NOMOUNT_COMMIT="${NOMOUNT_COMMIT:-bf1847f98fed382369c43bfd652cd93774b9b8e3}"

# BakaSU commit to pin (reproducible build)
BAKASU_COMMIT="${BAKASU_COMMIT:-d5e9e025b8b49155f8014684d64c91742b465f65}"
BAKASU_REPO="https://github.com/Baka-SU/BakaSU.git"

DEFCONFIG_FRAGMENTS=(
	"arch/arm64/configs/vendor/sdm845-perf_defconfig"
	"arch/arm64/configs/vendor/xiaomi/sdm845-common.config"
	"arch/arm64/configs/vendor/xiaomi/beryllium.config"
)
export ARCH=arm64
export SUBARCH=arm64
TC="$HOME/Coding/proton-clang"

# ---- Helpers ---------------------------------------------------------------
log() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

# ---- Setup NoMount submodule at pinned commit ---------------------------
setup_nomount() {
	if [[ ! -e "${ROOT_DIR}/NoMount/.git" ]]; then
		log "Cloning NoMount"
		git clone --filter=blob:none "$NOMOUNT_REPO" "${ROOT_DIR}/NoMount"
	fi
	
	log "Checking out NoMount ${NOMOUNT_COMMIT}"
	git -C "${ROOT_DIR}/NoMount" fetch --unshallow origin 2>/dev/null || true
	git -C "${ROOT_DIR}/NoMount" checkout --detach "$NOMOUNT_COMMIT"

    log "Wiring NoMount"
    ln -sfn ../NoMount/kernel/src "${ROOT_DIR}/fs/nomount"
    grep -qE 'obj-\$\(CONFIG_NOMOUNT\)\s*\+= nomount/' "${ROOT_DIR}/fs/Makefile" ||
        printf '\nobj-$(CONFIG_NOMOUNT) += nomount/\n' >> "${ROOT_DIR}/fs/Makefile"
    grep -q 'source "fs/nomount/Kconfig"' "${ROOT_DIR}/fs/Kconfig" ||
        sed -i '/^endmenu/i source "fs/nomount/Kconfig"' "${ROOT_DIR}/fs/Kconfig"
}

# ---- Setup BakaSU submodule at pinned commit + apply backports ----------
setup_bakasu() {
	if [[ ! -e "${ROOT_DIR}/KernelSU/.git" ]]; then
		log "Cloning BakaSU"
		git clone --filter=blob:none "$BAKASU_REPO" "${ROOT_DIR}/KernelSU"
	fi

	log "Checking out BakaSU ${BAKASU_COMMIT}"
	# Full history is required so KSU_LOCAL_VERSION (rev-list --count) stays
	# ~4355 -> KSU_VERSION 35055. A shallow checkout would yield a tiny count
	# and a too-low version code.
	if [ "$(git -C "${ROOT_DIR}/KernelSU" rev-parse --is-shallow-repository 2>/dev/null)" = "true" ]; then
		git -C "${ROOT_DIR}/KernelSU" fetch --unshallow origin 2>/dev/null || true
	fi
	git -C "${ROOT_DIR}/KernelSU" checkout --detach "$BAKASU_COMMIT"

	log "Wiring drivers/kernelsu"
	ln -sfn ../KernelSU/kernel "${ROOT_DIR}/drivers/kernelsu"
	grep -qE 'obj-\$\(CONFIG_KSU\)\s*\+= kernelsu/' "${ROOT_DIR}/drivers/Makefile" ||
		printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> "${ROOT_DIR}/drivers/Makefile"
	grep -q 'source "drivers/kernelsu/Kconfig"' "${ROOT_DIR}/drivers/Kconfig" ||
		sed -i '/^endmenu/i source "drivers/kernelsu/Kconfig"' "${ROOT_DIR}/drivers/Kconfig"
}

# ---- Configure kernel (defconfig) ------------------------------------
# Use KCONFIG_NONINTERACTIVE + default answers so kconfig never blocks on
# (NEW) options during olddefconfig/syncconfig.
configure() {
	export KCONFIG_NONINTERACTIVE=1
	log "Merging defconfig"
	mkdir -p "$OUT_DIR"
	scripts/kconfig/merge_config.sh -m -O "$OUT_DIR" "${DEFCONFIG_FRAGMENTS[@]}" < /dev/null || true
	make -C "$ROOT_DIR" O="$OUT_DIR" ARCH=arm64 \
		CC="$TOOLCHAIN_DIR/bin/clang" \
		CLANG_TRIPLE=aarch64-linux-gnu- \
		CROSS_COMPILE="$TOOLCHAIN_DIR/bin/aarch64-linux-gnu-" \
		LLVM_IAS=1 \
		olddefconfig < /dev/null

	# Vendor techpack drivers are not clang-clean; relax -Werror
	log "Disabling -Werror in techpack"
	find "$ROOT_DIR/techpack" -name Kbuild -o -name Makefile |
		xargs grep -l -- "-Werror" 2>/dev/null |
		xargs -r sed -i 's/-Werror/-Wno-error/g' || true
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

anykernel() {
    log "Creating AnyKernel zip"

    IMAGE="$DIST_DIR/Image.gz-dtb"
    ANYKERNEL="$ROOT_DIR/AnyKernel3"
    NAME="kernel-4.19-PocoF1-$(date +%Y%m%d-%H%M)"

    if [ -f "$IMAGE" ]; then
        cp "$IMAGE" "$ANYKERNEL/Image.gz-dtb"

        (
            cd "$ANYKERNEL" || exit 1

            zip -r9 "$DIST_DIR/$NAME.zip" . \
                -x "*.git*" \
                -x "LICENCE" \
                -x "README.md"
        ) > /dev/null || die "Failed to create AnyKernel zip"

        log "AnyKernel zip created: $DIST_DIR/$NAME.zip"
    else
        die "Image.gz-dtb missing"
    fi
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
EOF
}

clean() {
  log "Removing generated build output"
  rm -rf "$OUT_DIR" "$DIST_DIR"
}

# ---- Main -----------------------------------------------------------------
main() {
	cd "$ROOT_DIR"
	[[ -f Makefile && -d "arch/arm64/configs/vendor/xiaomi" ]] ||
		die "place build.sh in the kernel source root"
	for c in git make sed grep nproc; do need "$c"; done

	case "${1:-build}" in
		build)   setup_nomount; setup_bakasu; configure; build; collect; anykernel ;;
		collect) collect ;;
		config)  configure ;;
		setup)   setup_nomount; setup_bakasu ;;
		anykernel) anykernel ;;
		clean)   clean ;;
		-h|--help|help) usage ;;
		*) usage >&2; exit 2 ;;
	esac
}

main "$@"
