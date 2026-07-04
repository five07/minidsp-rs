#!/usr/bin/env bash

# Snipped from https://github.com/librespot-org/librespot/blob/dev/contrib/docker-build-pi-armv6hf.sh and edited for libusb
# Originally snipped and tucked from https://github.com/plietar/librespot/pull/202/commits/21549641d39399cbaec0bc92b36c9951d1b87b90
# and further inputs from https://github.com/kingosticks/librespot/commit/c55dd20bd6c7e44dd75ff33185cf50b2d3bd79c3

set -eux

# Collect Paths
SYSROOT="/pi-tools/arm-bcm2708/arm-bcm2708hardfp-linux-gnueabi/arm-bcm2708hardfp-linux-gnueabi/sysroot"
TOOLCHAIN="/pi-tools/arm-bcm2708/gcc-linaro-arm-linux-gnueabihf-raspbian-x64/"
GCC="$TOOLCHAIN/bin"
GCC_SYSROOT="$GCC/gcc-sysroot"


# Download dependencies to a tmp dir
if [ ! -d /tmp/debs ]; then
  mkdir -p /tmp/deb-download
  pushd /tmp/deb-download
  mkdir /tmp/debs
  git clone https://github.com/Ragnaroek/rust-on-raspberry-docker.git
  cd rust-on-raspberry-docker/apt
  # raspbian.raspberrypi.org dropped its buster suite; legacy.raspbian.org keeps
  # EOL suites around indefinitely.
  sed -i 's#raspbian.raspberrypi.org#legacy.raspbian.org#' sources.list
  ./install-keys.sh
  ./download.sh libhidapi-libusb0 libhidapi-dev libusb-1.0-0-dev libc6-dev libssl-dev libudev-dev
  mv *.deb /tmp/debs
  popd
fi

export PATH=$TOOLCHAIN/bin/:$PATH
export PKG_CONFIG_LIBDIR=${SYSROOT}/usr/lib/arm-linux-gnueabihf/pkgconfig/
export PKG_CONFIG_SYSROOT_DIR=$SYSROOT
export PKG_CONFIG_ALL_STATIC=on

# Link the compiler
export TARGET_CC="$GCC/arm-linux-gnueabihf-gcc"

# Create wrapper around gcc to point to rpi sysroot
echo -e '#!/bin/bash' "\n$TARGET_CC --sysroot $SYSROOT \"\$@\"" > $GCC_SYSROOT
chmod +x $GCC_SYSROOT

if [ ! -f /tmp/sysroot-dl ]; then
  # Add extra target dependencies to our rpi sysroot
  for path in /tmp/debs/*; do
    dpkg -x $path $SYSROOT
  done
  touch /tmp/sysroot-dl
fi

# NB: the official rust Docker images set CARGO_HOME=/usr/local/cargo, not
# ~/.cargo — writing to ~/.cargo/config.toml is silently ignored.
CARGO_CONFIG_DIR="${CARGO_HOME:-$HOME/.cargo}"
mkdir -p "$CARGO_CONFIG_DIR"

# point cargo to use gcc wrapper as linker. Also force the host (build
# script/proc-macro) linker off rustc's self-contained lld: under x86_64-on-
# arm64 QEMU emulation (e.g. Docker on Apple Silicon), rust-lld reliably
# segfaults linking proc-macro cdylibs (e.g. thiserror-impl). bfd doesn't hit
# this.
echo -e '[target.arm-unknown-linux-gnueabihf]\nlinker = "gcc-sysroot"\nstrip = { path = "arm-linux-gnueabihf-strip" }\nobjcopy = { path = "arm-linux-gnueabihf-objcopy" }\n\n[target.x86_64-unknown-linux-gnu]\nrustflags = ["-C", "link-arg=-fuse-ld=bfd"]' > "$CARGO_CONFIG_DIR/config.toml"

# NB: don't also export a blanket RUSTFLAGS here — a plain RUSTFLAGS env var
# fully overrides *all* config-file rustflags (every target, not just the one
# it's meant for), which would blow away the x86_64 (host) bfd override above.
# The per-target CARGO_TARGET_..._LINKER env var below is sufficient for the
# ARM cross target.
export CC_ARM_UNKNOWN_LINUX_GNUEABIHF=gcc-sysroot
export CARGO_TARGET_ARM_UNKNOWN_LINUX_GNUEABIHF_LINKER="gcc-sysroot -ldl"

# fix hidapi build issue
export CFLAGS="-std=c99"

# Overwrite libc and libpthread with the new ones since the sysroot ones are outdated
cp $SYSROOT/lib/arm-linux-gnueabihf/libc-2.28.so $SYSROOT/lib/libc.so.6
cp $SYSROOT/lib/arm-linux-gnueabihf/libdl-2.28.so $SYSROOT/lib/libdl.so.2
cp $SYSROOT/lib/arm-linux-gnueabihf/libpthread-2.28.so $SYSROOT/lib/libpthread.so.0

# Remove conflicting static libraries
rm -f $SYSROOT/usr/lib/arm-linux-gnueabihf/libdl.a
rm -f $SYSROOT/usr/lib/arm-linux-gnueabihf/libpthread.a

CMD=$1
shift

# Build
cargo $CMD --target arm-unknown-linux-gnueabihf "$@"

