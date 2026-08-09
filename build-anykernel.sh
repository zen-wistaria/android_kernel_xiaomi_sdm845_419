#!/bin/bash
set -e

export ANYKERNEL=$(pwd)/AnyKernel3
export PLACE=$HOME/Coding
NAME=ResukiSU-PocoF1-4.19-$(date +%Y%m%d-%H%M)
IMAGE=out/arch/arm64/boot/Image.gz-dtb
cp -r $IMAGE $ANYKERNEL/Image.gz-dtb
cd $ANYKERNEL
zip -r9 $PLACE/$NAME.zip . -x "*.git*" -x "LICENCE" -x "README.md"
