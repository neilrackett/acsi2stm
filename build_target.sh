#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 by Neil Rackett
#
# Builds the firmware and the GemDrive driver for one target.
#
# Meant to run inside the build container, see Makefile:
#
#    make tt     Generic build: ST, STE and TT
#    make mste   Mega STE build, with the cache workaround
#
# The build happens in a copy of the sources, so nothing in the source tree is
# modified. Output goes to build.<target> in the current directory.
#
#  Commands needed in your path
#
#    sed
#    vasmm68k_mot
#    xxd
#    arduino-cli

target="$1"
srcdir="$(readlink -fs "$(dirname "$0")")"
outdir="$PWD/build.$target"
version="$(cat "$srcdir/VERSION")"

case "$target" in
  tt)
    ;;
  mste)
    # Selects the Mega STE driver in asm/GEMDRIVE/mste.i
    export MSTE=1
    version="${version%-tt}-mste"
    ;;
  diag)
    # Diagnostic GEMDRIVE.PRG only, for the generic firmware: it says what
    # it is waiting for when the unit doesn't answer
    export DIAG=1
    ;;
  *)
    echo "Usage: $0 tt|mste|diag"
    exit 1
    ;;
esac

set -e

if [ "$target" = diag ]; then
  workdir="$(mktemp -d)"
  cp -r "$srcdir/asm" "$srcdir/acsi2stm" "$srcdir/build_asm.sh" "$srcdir/VERSION" "$workdir/"
  mkdir "$workdir/tools"
  (
    cd "$workdir/tools"
    "$workdir/build_asm.sh" > "$workdir/build_asm.log" 2>&1
  ) || { cat "$workdir/build_asm.log"; exit 1; }
  mkdir -p "$outdir"
  cp "$workdir/tools/GEMDRIVE.PRG" "$outdir/GDDIAG.PRG"
  echo "Diagnostic driver: $outdir/GDDIAG.PRG"
  rm -r "$workdir"
  exit 0
fi

# The Arduino_STM32 core doesn't compile with newer versions of SdFat
if ! arduino-cli lib list | grep -q 'SdFat - Adafruit Fork *2\.2\.3'; then
  echo "Install SdFat 2.2.3"
  arduino-cli lib install "SdFat - Adafruit Fork@2.2.3" > /dev/null
fi

echo "Copy the sources to a work directory"

workdir="$(mktemp -d)"
cp -r "$srcdir/asm" "$srcdir/acsi2stm" "$srcdir/build_asm.sh" "$workdir/"
echo "$version" > "$workdir/VERSION"
sed -i 's/^\(#define ACSI2STM_VERSION\).*/\1 "'$version'"/' "$workdir/acsi2stm/acsi2stm.h"

echo "Compile the 68k programs and the boot sector for $target"

mkdir "$workdir/tools"
(
  cd "$workdir/tools"
  "$workdir/build_asm.sh" > "$workdir/build_asm.log" 2>&1
) || { cat "$workdir/build_asm.log"; exit 1; }
grep 'GEMDRIVE_boot_bin_len' "$workdir/acsi2stm/GEMDRIVE.boot.h"

compile_arduino() {
  local name="$1"
  arduino-cli compile --build-path "$workdir/Arduino-$name/build" --fqbn "Arduino_STM32:STM32F1:genericSTM32F103C:device_variant=STM32F103C8,upload_method=serialMethod,cpu_speed=speed_72mhz,opt=osstd" --output-dir "$workdir/Arduino-$name" "$workdir/acsi2stm/acsi2stm.ino" > "$workdir/Arduino-$name.log" 2>&1 || { tail -n 30 "$workdir/Arduino-$name.log"; exit 1; }
  grep 'Sketch uses' "$workdir/Arduino-$name.log"
}

echo "Compile release binary"
compile_arduino release

echo "Compile debug binary"
sed -i 's/^#define ACSI_DEBUG .$/#define ACSI_DEBUG 1/' "$workdir/acsi2stm/acsi2stm.h"
compile_arduino debug

echo "Copy the result to $outdir"

mkdir -p "$outdir/hddflash"
cp "$workdir/Arduino-release/acsi2stm.ino.bin" "$outdir/acsi2stm-$version.ino.bin"
cp "$workdir/Arduino-debug/acsi2stm.ino.bin" "$outdir/acsi2stm-$version-debug.ino.bin"
cp "$workdir/tools/GEMDRIVE.PRG" "$outdir/"

# Ready to flash from the Atari: run HDDFLASH.TOS from this directory
cp "$workdir/tools/HDDFLASH.TOS" "$outdir/hddflash/"
cp "$workdir/Arduino-release/acsi2stm.ino.bin" "$outdir/hddflash/HDDFLASH.BIN"

rm -r "$workdir"
