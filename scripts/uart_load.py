#!/usr/bin/env python3
"""Load a program into the RV32I SoC over the UART, print its output and
exit with its exit code.

usage: uart_load.py [-p PORT] [-b BAUD] [--log FILE] [--timeout S] program.(elf|bin)

The Arty's FTDI chip exposes two ports; the UART is normally the second one.
Use -p /dev/ttyUSBX for the port exposed inside the Docker hardware service.
Protocol: see sw/boot/boot.c.
"""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile
import time

import serial

ACK, NAK, EOT = 0x06, 0x15, 0x04
APP_MAX = 0xE000


def load_image(path):
    data = open(path, "rb").read()
    if data[:4] != b"\x7fELF":
        return data
    objcopy = shutil.which("llvm-objcopy") or shutil.which("llvm-objcopy-17") \
        or shutil.which("riscv64-unknown-elf-objcopy") or "llvm-objcopy"
    with tempfile.TemporaryDirectory() as d:
        out = os.path.join(d, "prog.bin")
        subprocess.run([objcopy, "-O", "binary", "--remove-section=.tohost", path, out], check=True)
        return open(out, "rb").read()


class Port:
    def __init__(self, ser, log):
        self.ser, self.log = ser, log

    def byte(self, deadline):
        while time.time() < deadline:
            b = self.ser.read(1)
            if b:
                return b[0]
        raise TimeoutError

    def show(self, b):
        if b == 0x0D:
            return
        sys.stdout.write(chr(b))
        sys.stdout.flush()
        if self.log:
            self.log.write(chr(b))
            self.log.flush()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("program")
    ap.add_argument("-p", "--port", default="/dev/ttyUSBX")
    ap.add_argument("-b", "--baud", type=int, default=115200)
    ap.add_argument("--log", help="also write program output to this file")
    ap.add_argument("--timeout", type=float, default=0, help="seconds to wait for exit (0 = forever)")
    args = ap.parse_args()

    image = load_image(args.program)
    if len(image) > APP_MAX:
        sys.exit("image is %d bytes; at most %d fit below the stack" % (len(image), APP_MAX))

    ser = serial.Serial(args.port, args.baud, timeout=0.1)
    log = open(args.log, "w") if args.log else None
    port = Port(ser, log)
    ser.reset_input_buffer()

    # Handshake: retry 'L' until the bootloader answers (it ignores other bytes).
    for attempt in range(5):
        ser.write(b"L")
        try:
            deadline = time.time() + 1.0
            while True:
                b = port.byte(deadline)
                if b == ACK:
                    break
                port.show(b)   # e.g. the bootloader banner
            break
        except TimeoutError:
            continue
    else:
        sys.exit("no answer from the bootloader on %s (press the board's RESET button?)" % args.port)

    ser.write(len(image).to_bytes(4, "little"))
    ser.write(image)
    ser.flush()

    deadline = time.time() + 5 + len(image) * 12 / args.baud
    while True:
        b = port.byte(deadline)
        if b == ACK:
            break
        if b == NAK:
            sys.exit("bootloader rejected the image size")
    csum = int.from_bytes(bytes(port.byte(deadline) for _ in range(4)), "little")
    if csum != sum(image) & 0xFFFFFFFF:
        sys.exit("checksum mismatch: board %08x, host %08x" % (csum, sum(image) & 0xFFFFFFFF))
    print("[loaded %d bytes]" % len(image), file=sys.stderr)

    forever = args.timeout <= 0
    deadline = time.time() + (args.timeout if not forever else 1e9)
    try:
        while True:
            b = port.byte(deadline)
            if b == EOT:
                code = port.byte(time.time() + 1)
                break
            port.show(b)
    except TimeoutError:
        sys.exit("\n[timeout waiting for the program to exit]")
    except KeyboardInterrupt:
        sys.exit("\n[interrupted; press RESET on the board before loading again]")
    print("[exit code %d%s]" % (code, " (core trapped)" if code == 0xFF else ""), file=sys.stderr)
    sys.exit(code)


if __name__ == "__main__":
    main()
