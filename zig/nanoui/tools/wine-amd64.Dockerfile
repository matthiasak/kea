# Windows programs for nanoui's tests on an arm64 Mac: x86_64 Wine under
# Docker's amd64 emulation (arm64 Wine loops on arm64 VMs with pointer
# authentication). Run x86_64 builds: zig build -Dtarget=x86_64-windows-gnu.
FROM --platform=linux/amd64 debian:trixie
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    wine wine64 xvfb xauth x11-utils imagemagick xdotool fonts-dejavu-core fonts-noto-core \
    && rm -rf /var/lib/apt/lists/*
ENV WINEDEBUG=-all WINEDLLOVERRIDES=mscoree,mshtml=
WORKDIR /work
