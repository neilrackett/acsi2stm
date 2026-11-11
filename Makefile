# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 by Neil Rackett
#
# Builds the firmware and the GemDrive driver in the build container.
#
#    make image   Build the container image (once), see Dockerfile
#    make tt      Generic build: ST, STE and TT. "make st" is the same build.
#    make mste    Mega STE build, with the cache workaround
#    make         Both
#
# Each build goes to build.<target>: the firmware, its debug variant, the
# matching GEMDRIVE.PRG and a hddflash folder to flash from the Atari.
# The source tree is not modified.
#
# Use "make DOCKER=podman" to build with podman.

DOCKER ?= docker
IMAGE ?= acsi2stm

TARGETS := tt mste

.PHONY: all st image clean $(TARGETS)

all: $(TARGETS)

st: tt

$(TARGETS):
	$(DOCKER) run --rm --mount type=bind,source="$(CURDIR)",target=/acsi2stm $(IMAGE) ./build_target.sh $@

# vasm is only provided for x86-64
image:
	$(DOCKER) build --platform linux/amd64 -t $(IMAGE) .

clean:
	rm -rf build.tt build.mste
