#!/usr/bin/env bash
# Build a Linux arm64 rootfs with node + pi + pi-acp for the kelivo PRoot
# sandbox (form A: kelivo spawns the agent inside a bundled userland).
#
# Runs on GHA (x86_64) using qemu-user-static to chroot into arm64.
# Produces build/rootfs.tar.gz — NO secrets, clean runtime image.
set -euo pipefail

ROOTFS=build/rootfs
OUT=build/rootfs.tar.gz
ARCH=arm64

echo "==> installing debootstrap + qemu"
sudo apt-get update -y
sudo apt-get install -y debootstrap qemu-user-static binfmt-support

echo "==> debootstrap (foreign, $ARCH)"
sudo rm -rf "$ROOTFS"
sudo debootstrap --foreign --arch=$ARCH --variant=minbase \
  stable "$ROOTFS" http://deb.debian.org/debian

echo "==> copy qemu + second stage"
sudo cp "$(command -v qemu-aarch64-static)" "$ROOTFS/usr/bin/"
sudo chroot "$ROOTFS" /debootstrap/debootstrap --second-stage

echo "==> install node + npm"
sudo chroot "$ROOTFS" bash -c '
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    nodejs npm ca-certificates curl
'

echo "==> install pi + pi-acp (global)"
sudo chroot "$ROOTFS" bash -c '
  export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
  npm install -g @earendil-works/pi-coding-agent pi-acp
'

echo "==> verify"
sudo chroot "$ROOTFS" bash -c '
  export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
  node --version
  pi --version || true
  command -v pi-acp || echo "pi-acp missing!"
'

echo "==> pack"
sudo tar -C "$ROOTFS" -czf "$OUT" .
sudo chown "$(id -u):$(id -g)" "$OUT"
ls -lh "$OUT"
echo "DONE: $OUT"
