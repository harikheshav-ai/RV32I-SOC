BSC      ?= $(shell command -v bsc)
BSDIR    ?= $(abspath $(dir $(BSC))/../lib)
BUILD    := build
FLAGS    := -aggressive-conditions -show-schedule
BSCFLAGS := -bdir $(BUILD) -simdir $(BUILD) -info-dir $(BUILD) $(FLAGS)
SRCS     := $(wildcard *.bsv)

# The SoC deliberately calls always-on BRAM/UART methods from the core's
# soft-reset domain, which triggers G0043 (multiple resets) on every core rule.
SOCFLAGS := $(FLAGS) -suppress-warnings G0043

.PHONY: riscv-tests sim test soc-sim soc-vsim soc-test fpga-verilog fpga fpga-program fpga-flash run-elf clean

# ---- riscv-tests (fetched at a pinned commit; git-ignored) ----
RISCV_TESTS     := tests/riscv-tests
RISCV_TESTS_URL := https://github.com/riscv-software-src/riscv-tests.git
RISCV_TESTS_REV := 7b68f7b91f827f8d94cc1c57ff123752c5c8f704

riscv-tests: $(RISCV_TESTS)/isa/rv32ui/add.S

$(RISCV_TESTS)/isa/rv32ui/add.S:
	git init -q $(RISCV_TESTS)
	git -C $(RISCV_TESTS) fetch -q --depth 1 $(RISCV_TESTS_URL) $(RISCV_TESTS_REV)
	git -C $(RISCV_TESTS) checkout -q FETCH_HEAD

# ---- core co-simulation against spike ----
sim: $(BUILD)/sim

$(BUILD)/sim: $(SRCS)
	@mkdir -p $(BUILD)
	$(BSC) -u -sim $(BSCFLAGS) -g mktb tb.bsv
	$(BSC) -sim $(BSCFLAGS) -e mktb -o $@

test: sim riscv-tests
	python3 scripts/run_tests.py $(ARGS)

# ---- SoC simulation (program loaded over UART) ----
SOCSIM := $(BUILD)/socsim
soc-sim: $(SOCSIM)/sim

$(SOCSIM)/sim: $(SRCS)
	@mkdir -p $(SOCSIM)
	$(BSC) -u -sim -D SIMULATE -bdir $(SOCSIM) -simdir $(SOCSIM) -info-dir $(SOCSIM) $(SOCFLAGS) -g mktb_soc tb_soc.bsv
	$(BSC) -sim -bdir $(SOCSIM) -simdir $(SOCSIM) -info-dir $(SOCSIM) -e mktb_soc -o $@

# Same, from the generated Verilog with Icarus.
SOCVSIM := $(BUILD)/socvsim
soc-vsim: $(SOCVSIM)/vsim

$(SOCVSIM)/vsim: $(SRCS)
	@mkdir -p $(SOCVSIM)
	$(BSC) -u -verilog -D SIMULATE -bdir $(SOCVSIM) -vdir $(SOCVSIM) -info-dir $(SOCVSIM) $(SOCFLAGS) -g mktb_soc tb_soc.bsv
	iverilog -g2005 -DTOP=mktb_soc -y $(BSDIR)/Verilog -o $@ \
	  $(BSDIR)/Verilog/main.v $(SOCVSIM)/mktb_soc.v $(SOCVSIM)/mksoc.v

soc-test: soc-sim riscv-tests
	python3 scripts/run_soc.py $(ARGS)

# ---- FPGA (Arty A7-100T), open-source openXC7 flow ----
# yosys -> nextpnr-xilinx -> prjxray fasm2frames -> xc7frames2bit.
# Tools run natively if nextpnr-xilinx is on PATH (then set PRJXRAY_DB to the
# prjxray-db artix7 directory and NEXTPNR_PY to nextpnr-xilinx/xilinx/python);
# otherwise they run in the openXC7 docker image.
FPGA      := $(BUILD)/fpga
PART      := xc7a100tcsg324-1
FPGA_MHZ  := 50   # must match the core clock in fpga/arty_top.v
SEED      ?= 3    # nextpnr placement seed; try another if timing fails
CHIPDB    ?= $(CURDIR)/fpga/chipdb/$(PART).bin
# Pinned to the same digest as the Dockerfile base image.
OPENXC7_IMAGE ?= regymm/openxc7@sha256:35c910739e3a4b40850b85de31ebc8954985a66e982009f09123b70dbb0e75da

ifeq ($(shell command -v nextpnr-xilinx),)
XC7        = docker run --rm -u $(shell id -u):$(shell id -g) -v $(CURDIR):$(CURDIR) -w $(CURDIR)/$(FPGA) $(OPENXC7_IMAGE)
PRJXRAY_DB ?= /nextpnr-xilinx/xilinx/external/prjxray-db/artix7
NEXTPNR_PY ?= /nextpnr-xilinx/xilinx/python
else
XC7        = cd $(FPGA) &&
endif

fpga-verilog: $(SRCS) sw/boot/* fpga/arty_top.v
	@mkdir -p $(FPGA)/verilog
	$(BSC) -u -verilog -D FPGA -bdir $(FPGA) -vdir $(FPGA)/verilog -info-dir $(FPGA) $(SOCFLAGS) -g mksoc soc.bsv
	python3 scripts/bsv_libs.py $(BSDIR)/Verilog $(FPGA)/verilog
	python3 scripts/run_soc.py --boot $(FPGA)
	cp fpga/arty_top.v $(FPGA)/verilog/

# nextpnr-xilinx device database: generated once (~20 s), kept across `make clean`.
$(CHIPDB):
	@mkdir -p $(dir $@) $(FPGA)
	$(XC7) bash -c "pypy3 $(NEXTPNR_PY)/bbaexport.py --device $(PART) --bba $(@:.bin=.bba) && bbasm -l $(@:.bin=.bba) $@ && rm $(@:.bin=.bba)"

fpga: fpga-verilog $(CHIPDB)
	$(XC7) yosys -q -l yosys.log -p "read_verilog -defer verilog/*.v; synth_xilinx -flatten -abc9 -arch xc7 -top arty_top; tee -q -o utilization.txt stat; write_json arty.json"
	$(XC7) nextpnr-xilinx --chipdb $(CHIPDB) --xdc $(CURDIR)/fpga/arty_a7_100t.xdc --json arty.json --fasm arty.fasm --freq $(FPGA_MHZ) --seed $(SEED) --log nextpnr.log --quiet
	@grep "Max frequency" $(FPGA)/nextpnr.log | tail -1
	$(XC7) bash -c "fasm2frames --part $(PART) --db-root $(PRJXRAY_DB) arty.fasm > arty.frames 2>/dev/null && xc7frames2bit --part_file $(PRJXRAY_DB)/$(PART)/part.yaml --part_name $(PART) --frm_file arty.frames --output_file rv32i_arty.bit"
	@echo "bitstream: $(FPGA)/rv32i_arty.bit"

# Programming uses openFPGALoader, included in the Docker hardware profile.
fpga-program:
	openFPGALoader -b arty_a7_100t $(FPGA)/rv32i_arty.bit

fpga-flash:
	openFPGALoader -b arty_a7_100t -f $(FPGA)/rv32i_arty.bit

run-elf:
	@test -n "$(ELF)" || (echo "usage: make run-elf ELF=path/to/program.elf [PORT=/dev/ttyUSBX]"; exit 2)
	python3 scripts/uart_load.py -p "$(or $(PORT),/dev/ttyUSBX)" "$(ELF)"

clean:
	rm -rf $(BUILD) out out-soc
