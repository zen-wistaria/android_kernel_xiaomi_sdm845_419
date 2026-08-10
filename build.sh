#!/bin/bash
set -e

export ARCH=arm64
export SUBARCH=arm64
# export KSU=1

TC="$HOME/Coding/proton-clang"

# ==== Apply + commit KernelSU backports patch ====
# Backports (Kconfig independent hooks, sus_path app-flag, ksu_init_rc_hook)
# are applied to the ReSukiSU submodule and committed with a recognizable
# name so changes stay visible in `git log KernelSU`. Idempotent: skips if the
# commit already exists.
KSU_BACKPORT_COMMIT="ReSukiSU backports: independent hooks, sus_path app-flag, ksu_init_rc_hook"
if git -C KernelSU log --oneline | grep -q "ReSukiSU backports:"; then
	echo "[build] KernelSU backports already committed"
else
	git -C KernelSU checkout -- kernel/ 2>/dev/null
	(cd KernelSU && git apply ../KernelSU-backports.patch)
	git -C KernelSU add -A
	git -C KernelSU commit -m "$KSU_BACKPORT_COMMIT"
	echo "[build] Committed KernelSU backports"
fi

# ==== Merge defconfig ====
mkdir -p out
scripts/kconfig/merge_config.sh -O out \
  arch/arm64/configs/vendor/sdm845-perf_defconfig \
  arch/arm64/configs/vendor/xiaomi/sdm845-common.config \
  arch/arm64/configs/vendor/xiaomi/beryllium.config || true

make ARCH=arm64 O=out olddefconfig

# ==== Disable -Werror in techpack (vendor drivers not clang-clean) ====
find techpack -name Kbuild -o -name Makefile | xargs grep -l -- "-Werror" 2>/dev/null | xargs -r sed -i 's/-Werror/-Wno-error/g'

# ==== Compile ====
export LD_LIBRARY_PATH="$TC/lib:$LD_LIBRARY_PATH"

# KSU compat: 4.19 QTI exposes selinux_state struct (not the legacy global
# policydb). Passed via KCFLAGS so the ReSukiSU submodule stays pristine and
# KSU_COMMIT_SHA does not turn -dirty from a patched Kbuild.
make -j$(nproc) O=out \
  ARCH=arm64 \
  CC="$TC/bin/clang" \
  CLANG_TRIPLE=aarch64-linux-gnu- \
  CROSS_COMPILE="$TC/bin/aarch64-linux-gnu-" \
  CROSS_COMPILE_ARM32=arm-linux-gnueabi- \
  AR="$TC/bin/llvm-ar" \
  NM="$TC/bin/llvm-nm" \
  OBJCOPY="$TC/bin/llvm-objcopy" \
  OBJDUMP="$TC/bin/llvm-objdump" \
  STRIP="$TC/bin/llvm-strip" \
  LLVM_IAS=1 \
  KCFLAGS=-DKSU_COMPAT_HAS_SELINUX_STATE
