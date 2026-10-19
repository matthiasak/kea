# Windows programs for nanoui's tests: Wine runs arm64 Windows builds
# (zig build -Dtarget=aarch64-windows-gnu) on a virtual display. Debian's
# Wine 10 (Ubuntu 24.04's Wine 9 cannot unwind arm64 code built with
# pointer authentication, and hangs).
FROM debian:trixie
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    wine wine64 xvfb xauth x11-utils imagemagick xdotool fonts-dejavu-core fonts-noto-core \
    && rm -rf /var/lib/apt/lists/*
ENV WINEDEBUG=-all WINEDLLOVERRIDES=mscoree,mshtml=
WORKDIR /work
