#!/bin/zsh
# Checks the disk image readers byte for byte: make-images.py writes small Parallels, QCOW2 and VMDK
# images following their specs, with the raw disk each should become; the converter must match it.
set -e
cd "$(dirname "$0")/../.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
xcrun swiftc -O -swift-version 6 -o "$work/convert" Hyperbox/Core/Import/{DiskImage,QCOW2,Parallels,VMDK}.swift Shared/*.swift Tests/DiskImages/main.swift
python3 -I Tests/DiskImages/make-images.py "$work" >/dev/null
failed=0
for pair in parallels-ext.hds:parallels-ext parallels-old.hds:parallels-old Debian.pvm:parallels-chain \
            qcow2-plain.qcow2:qcow2-plain qcow2-ext.qcow2:qcow2-ext qcow2-overlay.qcow2:qcow2-overlay \
            vmdk-sparse.vmdk:vmdk-sparse vmdk-deflate.vmdk:vmdk-deflate vmdk-split.vmdk:vmdk-split; do
    image=${pair%%:*} expected=${pair##*:}
    if "$work/convert" "$work/$image" "$work/$expected.out" && cmp -s "$work/$expected.out" "$work/$expected.raw"; then
        echo "ok    $image ($(du -k "$work/$expected.out" | cut -f1) KB on disk of $(( $(stat -f %z "$work/$expected.out") / 1024 )) KB)"
    else
        echo "FAIL  $image"
        failed=1
    fi
done
exit $failed
