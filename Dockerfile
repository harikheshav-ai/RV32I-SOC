# syntax=docker/dockerfile:1.7
#
# The openXC7 image supplies the FPGA flow used by Makefile.  The image is
# pinned to linux/amd64 because the official BSC Linux package is x86-64;
# Docker Desktop runs it transparently on Windows, Linux, and macOS.
ARG OPENXC7_IMAGE=regymm/openxc7@sha256:35c910739e3a4b40850b85de31ebc8954985a66e982009f09123b70dbb0e75da
FROM --platform=linux/amd64 ${OPENXC7_IMAGE}

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG BSC_VERSION=2026.01
ARG BSC_SHA256=6d13db288cf268dc1331f05b277c414b4ff1c1ab9618a6526ba16ad29e484e43
ARG SPIKE_VERSION=v1.1.0

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      git \
      make \
      build-essential \
      clang \
      lld \
      llvm \
      iverilog \
      python3 \
      python3-pip \
      python3-serial \
      pypy3 \
      pkg-config \
      libboost-all-dev \
      device-tree-compiler \
      openfpgaloader \
 && rm -rf /var/lib/apt/lists/*

# The openXC7 base image uses its own Python environment. Install pyserial
# into that interpreter as well as the system package so the default python3
# runs uart_load.py.
RUN /prjxray/env/bin/python3 -m pip install --no-cache-dir pyserial

# Install the official prebuilt Bluespec compiler.  Keeping the version and
# digest here makes image rebuilds deterministic and avoids a source build.
RUN mkdir -p /opt/bsc \
 && curl -fsSL "https://github.com/B-Lang-org/bsc/releases/download/${BSC_VERSION}/bsc-${BSC_VERSION}-ubuntu-24.04.tar.gz" -o /tmp/bsc.tar.gz \
 && echo "${BSC_SHA256}  /tmp/bsc.tar.gz" | sha256sum -c - \
 && tar -xzf /tmp/bsc.tar.gz --strip-components=1 -C /opt/bsc \
 && rm /tmp/bsc.tar.gz

# Spike is built once in the image so the normal regression compares every
# commit against the reference simulator without requiring a host install.
# Spike 1.1.0 expects standard integer definitions with modern GCC. Supplying
# that header explicitly keeps the parallel build fast and portable.
RUN git clone --depth 1 --branch "${SPIKE_VERSION}" \
      https://github.com/riscv-software-src/riscv-isa-sim.git /tmp/riscv-isa-sim \
 && mkdir /tmp/riscv-isa-sim/build \
 && cd /tmp/riscv-isa-sim/build \
 && CXXFLAGS="-include cstdint" ../configure --prefix=/opt/riscv --enable-commitlog \
 && make -j"$(nproc)" \
 && make install \
 && rm -rf /tmp/riscv-isa-sim

ENV PATH="/opt/bsc/bin:/opt/riscv/bin:/nextpnr-xilinx/bin:/nextpnr-xilinx/xilinx/bin:${PATH}" \
    BLUESPECDIR=/opt/bsc/lib \
    BSC=/opt/bsc/bin/bsc \
    CC=clang \
    LD=ld.lld \
    OBJCOPY=llvm-objcopy \
    SPIKE=/opt/riscv/bin/spike \
    PRJXRAY_DB=/nextpnr-xilinx/xilinx/external/prjxray-db/artix7 \
    NEXTPNR_PY=/nextpnr-xilinx/xilinx/python

WORKDIR /workspace

RUN bsc -help >/dev/null \
 && clang --version >/dev/null \
 && llvm-objcopy --version >/dev/null \
 && iverilog -V >/dev/null \
 && spike --help >/dev/null 2>&1 \
 && yosys -V >/dev/null \
 && nextpnr-xilinx --help >/dev/null 2>&1 \
 && openFPGALoader --help >/dev/null 2>&1 \
 && python3 -c "import serial"

# Source is mounted at runtime.  The default is a complete, Spike-checked
# regression; override the command for soc-test, soc-vsim, or fpga.
CMD ["make", "test"]
