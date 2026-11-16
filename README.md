# RV32I Core

> Code and documentation generated with Claude (Anthropic). My role: specification, design
> direction, review and hardware bring-up on an Arty A7-100T.

**Web version:** [harikheshav-ai.github.io/RV32I-SOC](https://harikheshav-ai.github.io/RV32I-SOC/) (source: [`docs/index.html`](docs/index.html), self-contained; it also opens locally in a browser).

An in-order RV32I pipeline with BRAM-style (request/response) instruction and data memory:

| Stage | File | Does |
|---|---|---|
| Fetch | `fetch.bsv` | Issues one I-mem request per cycle, predicting PC+4; drops responses from before a redirect |
| Decode | `decoder.bsv` | Decodes, reads registers (scoreboard + same-cycle bypass from both writeback paths) |
| Execute | `execute.bsv` `do_execute` | ALU, branch/jump resolution, D-mem requests, writeback of non-load results; squashes wrong-epoch instructions and redirects fetch |
| Load writeback | `execute.bsv` `do_writeback` | Takes the D-mem response, aligns/extends it and writes the register |

`common.bsv` holds shared types, `core.bsv` wires the stages together (`mkcore`),
`mem.bsv` is a 64 KiB true dual-port BRAM (`mkBRAM2ServerBE`, 1-cycle latency, byte
enables) at `0x80000000` loaded from `prog.hex`, and `tb.bsv` is the Bluesim testbench.
The core talks to memory only through `Server#(MemReq, Word)` ports (in-order responses for
reads; no response for writes), so other memories with different latency can be swapped in.

- Supports all 40 RV32I instructions: FENCE is a no-op, and ECALL, EBREAK, illegal instructions and
  misaligned accesses halt the core with a clear report.
- Throughput is one instruction per cycle, including back-to-back independent loads and stores.
  Taken branches and jumps cost 3 extra cycles, and an instruction that uses a load's result
  waits 1 cycle. CPI on the test programs is about 1.35–1.7.

## Requirements

Native builds need:

- `bsc` (Bluespec compiler; tested with 2021.12.1 and 2026.01)
- clang with the riscv32 target, `ld.lld`, `llvm-objcopy` and `llvm-objdump`
  (plain or versioned names such as `llvm-objcopy-18` are found on `PATH`;
  override with `$CC`, `$LD`, `$OBJCOPY`, `$OBJDUMP`)
- Python 3 with `pyserial`
- git and network access (`make test` fetches riscv-tests at a pinned commit)
- Optional: Spike (co-simulation against its commit log), Icarus Verilog
  (`make soc-vsim`), Docker (`make fpga` without a native openXC7 install, or
  the complete container below)

## Running

```
make sim                 # build Bluesim model -> build/sim
make test                # all tests, compared against spike's commit log
make test ARGS="--random 100"
make test ARGS="sra c-sort"      # filter by name
```

Tests (`scripts/run_tests.py`) need clang (riscv32 target), ld.lld and llvm-objcopy:

- `tests/riscv-tests/` – the official [riscv-tests](https://github.com/riscv-software-src/riscv-tests),
  fetched at a pinned commit by `make riscv-tests` (run automatically by `make test` and
  `make soc-test`; git-ignored). The rv32ui tests (except `fence_i` and `ma_data`) use a bare
  environment in `tests/env/riscv_test.h` that reports through `tohost`.
- `tests/c/` – C programs (sort, sieve, CRC32, recursion/division), built at -O0 and -O2.
- Random programs from `scripts/gen_random.py` (dense dependencies, branches, jumps, loops, loads/stores).

Each test must write `1` to `tohost` (at `0x8000F000`). If spike is found (`$SPIKE`,
else `spike` on `PATH`, else `/opt/riscv/riscv64-unknown-elf/bin/spike`), each register write, store, and PC is
checked against `spike --log-commits`. Outputs are written to `out/<test>/` (`core.log`, `spike.log`, `.dis`).

To run one program by hand, put `prog.hex` (one little-endian word per line) in the
current directory and run `build/sim +trace`.

### Docker development environment

The repository includes a portable container with BSC, Clang/LLVM, Spike, Icarus
and the open-source FPGA tools. Docker Desktop provides the same workflow on
Windows, Linux and macOS; the project directory is mounted into the container,
so build outputs remain visible on the host.

```sh
export HOST_UID=$(id -u) HOST_GID=$(id -g)   # Linux: own the output files (default 1000:1000)
docker compose build
docker compose run --rm rv32i                 # core regression: 58 tests
docker compose run --rm rv32i make soc-test   # SoC/UART regression
docker compose run --rm rv32i make fpga       # Arty A7 bitstream
docker compose --profile hardware run --rm rv32i-hardware make fpga-program
docker compose --profile hardware run --rm rv32i-hardware \
  make run-elf ELF=out-soc/ex-hello/ex-hello.elf PORT=/dev/ttyUSBX
```

The `rv32i` service runs as `HOST_UID:HOST_GID` so build outputs in the
mounted directory stay owned by you; the `rv32i-hardware` service runs as root
for USB/JTAG device access.

The image uses pinned prebuilt tool layers and a parallel Spike build to keep
the first image build within the ten-minute target on a typical developer
machine. Subsequent builds reuse Docker layers. On Apple Silicon, Docker runs
the pinned Linux toolchain through its built-in amd64 compatibility layer.
The hardware profile includes `openFPGALoader` and maps the board's USB/JTAG
interfaces into the container. On Linux, set `USB_SERIAL_DEVICE` if the host
UART is not `/dev/ttyUSB1`; on Docker Desktop, expose the board's USB devices
to Docker first, then use the same hardware-profile commands.

#### USB/JTAG hardware access

The normal `rv32i` service is enough for simulation and bitstream builds. The
`rv32i-hardware` profile is used only when the Arty board is connected. It
passes the JTAG USB bus to `openFPGALoader` and maps the board's serial port to
`/dev/ttyUSBX` inside the container. Build the image before attaching hardware:

```sh
docker compose build
```

On Linux with Docker Engine, connect the board and identify its serial port:

```sh
ls -l /dev/ttyUSB* /dev/ttyACM* /dev/serial/by-id 2>/dev/null
sudo usermod -aG dialout "$USER"   # log out and in once if needed
export USB_SERIAL_DEVICE=/dev/ttyUSB1

docker compose --profile hardware run --rm rv32i-hardware make fpga-program
docker compose --profile hardware run --rm rv32i-hardware \
  make fpga-flash
docker compose --profile hardware run --rm rv32i-hardware \
  make run-elf ELF=out-soc/ex-hello/ex-hello.elf PORT=/dev/ttyUSBX
```

Replace `/dev/ttyUSB1` with the host path reported by Linux. The container
uses `/dev/ttyUSBX` as its stable in-container name; replace `X` in the
`PORT` value with the USBX port assigned by the system. The `dialout` step is
needed for native serial tools; the privileged Docker hardware service also
needs the host device to exist.

On Windows, the most direct route is WSL2 with a Docker Engine running in the
same WSL2 distribution. In an Administrator PowerShell, install and attach
the board with Microsoft's USB/IP tooling:

```powershell
wsl --update
winget install --interactive --exact dorssel.usbipd-win
usbipd list
usbipd bind --busid <BUSID>
usbipd attach --wsl --busid <BUSID>
```

Then run the Linux commands above from that WSL2 distribution. Confirm the
board is visible before starting the hardware service:

```sh
lsusb
ls -l /dev/ttyUSB* /dev/ttyACM*
```

Docker Desktop's daemon is a separate Linux VM, so a device attached only to
WSL2 is not automatically attached to Docker Desktop. For Docker Desktop on
Windows or macOS, use a USB/IP server that exports the board and attach it to
the Docker Desktop VM. Docker's USB/IP workflow is:

```sh
# Keep this privileged container running while using the board.
docker run --rm -it --privileged --pid=host alpine
nsenter -t 1 -m
usbip list -r host.docker.internal
usbip attach -r host.docker.internal -d <BUSID>
```

After the USB/IP server has exported the board and the attach command succeeds,
use a second terminal to run the same `docker compose --profile hardware ...`
commands above. The Docker Desktop USB/IP setup is documented at
[`docs.docker.com/desktop/features/usbip`](https://docs.docker.com/desktop/features/usbip/).
Windows WSL2 attachment details are in
[`learn.microsoft.com/en-us/windows/wsl/connect-usb`](https://learn.microsoft.com/en-us/windows/wsl/connect-usb),
and the `usbipd-win` project is at
[`github.com/dorssel/usbipd-win`](https://github.com/dorssel/usbipd-win).

## SoC and FPGA (Arty A7-100T)

`soc.bsv` (`mksoc`) wraps the core with a 128 KiB BRAM (eight 16 KiB banks, `mkBankedBram`) and a UART
(`uart.bsv`, 8N1, 16-byte FIFOs):

| Address | Use |
|---|---|
| `0x80000000`–`0x8000DFFF` | program image (loaded over the UART) |
| `0x8000E000`–`0x8000EFFF` | program stack; `tohost` at `0x8000F000` ends the program |
| `0x80010000`–`0x8001FFFF` | bootloader (`sw/boot`, baked into this bank's BRAM init from `boot.mem`) and its stack |
| `0x10000000` | UART TXDATA (write a byte; stalls while the TX FIFO is full) |
| `0x10000004` | UART RXDATA (received byte, or bit 31 set if none) |
| `0x10000008` | UART STATUS (bit 0 TX full, bit 1 RX available) |
| `0x1000000C` | EXIT (bit 31: a program exited, bits 7:0 its code; read clears) |

The core boots into the bootloader, which accepts `'L'`, a 4-byte length and the image, answers
with an ACK and checksum, and jumps to `0x80000000`. When the program writes `tohost` (or the core
traps), the SoC latches the exit code and resets the core and its memory ports. The BRAM contents
are kept. The bootloader then sends `0x04` + exit code and waits for the next program.
LEDs: LD7 heartbeat, LD6 last program failed, LD5 last program passed, LD4 UART TX activity.

Programs use `tests/env/crt0.S` + `tests/env/link.ld`, and `sw/lib/uart.c` for
`printf`/`uart_putc`/`uart_getc` (see `sw/examples/hello.c`).

### Simulation

```
make soc-test                    # Bluesim: load each program over the UART (twice) and check its exit code
make soc-test ARGS="--verilog"   # same, using bsc's Verilog output under Icarus (build first: make soc-vsim)
```

The testbench drives a second UART as the host. Output from each run is in `out-soc/<test>/`:
`sim.log` (testbench) and **`uart.log`**, written by the SoC's UART itself. With `-D SIMULATE`
(used by the sim builds), every byte the UART transmits is also logged there. The FPGA build
leaves the logger out.

### Building the bitstream (open-source openXC7 flow)

```
make fpga          # bsc -> yosys -> nextpnr-xilinx -> prjxray -> build/fpga/rv32i_arty.bit
make fpga SEED=n   # same with another nextpnr placement seed (default 3) if timing fails
make fpga-program  # openFPGALoader -b arty_a7_100t (volatile, over JTAG)
make fpga-flash    # write to the board's SPI flash
```

If `nextpnr-xilinx` is not on `PATH`, the tools run in the `regymm/openxc7` docker image. The first
run also generates the nextpnr device database into `fpga/chipdb/` (about 20 s, 160 MB). That
directory is kept by `make clean`. `fpga/arty_top.v` divides the 100 MHz board clock by two in a
flip-flop (onto a BUFG) for the 50 MHz core clock, and holds the SoC in reset for ~21 ms after
configuration and while RESET is pressed. `fpga/arty_a7_100t.xdc` holds the pins.
Current results: 32 RAMB36, about 6.6k LUTs (5% of the device), and a reported Fmax of 54.24 MHz
against the 50 MHz target (seed 3). The critical path runs from the decode-to-execute operands through
the signed branch comparator.

The Docker hardware profile includes `openFPGALoader` for direct programming.
For native, non-Docker programming, install it on the machine connected to the board.

### Running programs on the board

```
python3 scripts/uart_load.py -p /dev/ttyUSBX out-soc/ex-hello/ex-hello.elf [--log out.txt]
```

Replace `X` with the USBX port assigned by your system.
This loads the ELF (or raw binary), prints the program's output and exits with the program's exit code.
Press the board's RESET button whenever you want to return to the bootloader for another session.
On Linux the Arty's FT2232 shows up as two ports: the first is JTAG, the second (usually
`/dev/ttyUSB1`) is the UART.

**Hardware status:** tested on an Arty A7-100T. All ten SoC test programs (hello, five C programs,
five rv32ui tests) load over the UART and exit with code 0, back to back without reprogramming.

`scripts/run_soc.py` takes `BUILD` and `SOC_OUT` from the environment to use other build/output
directories (e.g. `BUILD=build2 SOC_OUT=$PWD/out-soc2 make soc-test BUILD=build2`).

## License

MIT (see `LICENSE`). `tests/env/test_macros.h` is from [riscv-tests](https://github.com/riscv-software-src/riscv-tests) (BSD-3-Clause, see `LICENSE-riscv-tests`); the riscv-tests suite itself is fetched at build time, not included.
