#!/bin/bash
set -e

export ARCH=arm64
export SUBARCH=arm64
# export KSU=1

TC="$HOME/Coding/proton-clang"

# ==== Apply KernelSU backports patch (submodule stays pristine) ====
# These are kernel-side changes that live in the repo (not the ReSukiSU
# submodule): Kconfig (manual+susfs), selinux_hide early backup, sus_path
# app-flag, rules idempotence. Applied BEFORE defconfig so Kconfig edits take
# effect during olddefconfig.
if grep -q "Hooking methods are independent" KernelSU/kernel/Kconfig 2>/dev/null; then
	echo "[build] KernelSU-backports.patch already applied"
else
	(cd KernelSU && git apply ../KernelSU-backports.patch)
	echo "[build] Applied KernelSU-backports.patch"
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
