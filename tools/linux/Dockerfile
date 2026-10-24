# Factorio headless for Linux plus what tools/autotest-run.sh needs (bash, python3, GNU coreutils and sed).
# Built by tools/linux/run.sh; the build context is a directory that holds only the official headless archive
# (build/linux/dl-<version>-<linux64|linux-arm64>/), checked against factorio.com's SHA-256 list before the build.
# No account and no Steam: the headless build carries the data of base, Space Age, Quality and Elevated Rails.
# Debian 13: the 2.1 Linux builds need glibc 2.38 or newer (bookworm's 2.36 fails: "GLIBC_2.38 not found").
FROM debian:trixie-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 xz-utils \
 && rm -rf /var/lib/apt/lists/*
ARG FACTORIO_ARCHIVE
ARG FACTORIO_BIN_DIR=x64
COPY ${FACTORIO_ARCHIVE} /tmp/factorio.tar.xz
RUN tar -xJf /tmp/factorio.tar.xz -C /opt \
 && rm /tmp/factorio.tar.xz \
 && test -x /opt/factorio/bin/${FACTORIO_BIN_DIR}/factorio \
 && chmod -R a+rX /opt/factorio
# The runs use the host user's uid (docker run --user) and write only under /tmp and the /out mount.
ENV FACTORIO_BIN=/opt/factorio/bin/${FACTORIO_BIN_DIR}/factorio \
    FACTORIO_READ_DATA=/opt/factorio/data \
    HOME=/tmp
WORKDIR /tmp
