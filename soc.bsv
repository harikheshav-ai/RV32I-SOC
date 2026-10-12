package soc;

import BRAMCore :: *;
import FIFO :: *;
import FIFOF :: *;
import SpecialFIFOs :: *;
import ClientServer :: *;
import GetPut :: *;
import Clocks :: *;
import DReg :: *;
import Vector :: *;
import common :: *;
import execute :: *;
import core :: *;
import uart :: *;

// SoC for FPGA use: core + 128 KiB BRAM + UART.
//
// Memory map:
//   0x80000000 - 0x8000FFFF  application RAM (programs load at 0x80000000;
//                            a store to tohost at 0x8000F000 ends the program)
//   0x80010000 - 0x8001FFFF  bootloader (initialised from boot.mem, see mkBankedBram) and its stack
//   0x10000000               UART TXDATA  (W: byte to send; stalls while TX FIFO full)
//   0x10000004               UART RXDATA  (R: received byte, or bit 31 set if none)
//   0x10000008               UART STATUS  (R: bit 0 TX FIFO full, bit 1 RX data available)
//   0x1000000C               EXIT         (R: bit 31 set if a program has exited since the
//                                          last read, bits 7:0 its exit code; read clears)
//
// The core boots into the bootloader, which loads a program over the UART
// and jumps to it. When the program writes tohost (or the core traps), the
// exit code ((tohost >> 1) & 0xFF, or 0xFF for a trap) is latched in EXIT and
// the core and its memory ports are reset; the BRAM contents are kept. The
// bootloader then starts again, reports the exit code over the UART and waits
// for the next program.

typedef 15 SocAddrBits;
Word ramBase    = 32'h80000000;
Word bootAddr   = 32'h80010000;
Word tohostAddr = 32'h8000F000;
Bit#(4) ioRegion = 4'h1;

interface Ifc_soc;
  (* always_ready, result = "uart_tx" *)
  method Bit#(1) uart_tx;
  (* always_ready, always_enabled, prefix = "" *)
  method Action uart_rx((* port = "uart_rx" *) Bit#(1) b);
  // {heartbeat, last program failed, last program passed, UART TX activity}
  (* always_ready, result = "leds" *)
  method Bit#(4) leds;
endinterface

interface Ifc_exitCtl;
  method Action exit(Bit#(8) code);     // latch code and reset the core
  method Maybe#(Bit#(8)) status;
  method Action clear;
endinterface


// Request/response port over a raw BRAM port. Read data is captured the cycle
// after the request and can be consumed in that same cycle; credits ensure the
// capture never finds the response buffer full.
module mkBramServer#(BRAM_PORT_BE#(Bit#(SocAddrBits), Word, 4) port)(Server#(MemReq, Word));
  FIFOF#(Word)   resp       <- mkSizedBypassFIFOF(2);
  Reg#(UInt#(2)) credits[2] <- mkCReg(2, 2);
  Reg#(Bool)     pending    <- mkDReg(False);

  (* fire_when_enabled *)
  rule capture (pending);
    resp.enq(port.read);
  endrule

  interface Put request;
    method Action put(MemReq r) if (credits[1] != 0);
      port.put(r.write ? r.byteEn : 0, truncate((r.addr - ramBase) >> 2), r.data);
      if (!r.write) begin
        credits[1] <= credits[1] - 1;
        pending    <= True;
      end
    endmethod
  endinterface

  interface Get response;
    method ActionValue#(Word) get;
      resp.deq;
      credits[0] <= credits[0] + 1;
      return resp.first;
    endmethod
  endinterface
endmodule


// The 128 KiB RAM as eight 4K-word banks. Only the bootloader bank
// (0x80010000) is initialised, from boot.mem.
typedef 12 BankAddrBits;
Integer bootBank = 4;

module mkBankedBram(BRAM_DUAL_PORT_BE#(Bit#(SocAddrBits), Word, 4));
  Vector#(8, BRAM_DUAL_PORT_BE#(Bit#(BankAddrBits), Word, 4)) banks;
  for (Integer i = 0; i < 8; i = i + 1)
    banks[i] <- (i == bootBank)
      ? mkBRAMCore2BELoad(2 ** valueOf(BankAddrBits), False, "boot.mem", False)
      : mkBRAMCore2BE(2 ** valueOf(BankAddrBits), False);

  function BRAM_PORT_BE#(Bit#(SocAddrBits), Word, 4)
      bankedPort(function BRAM_PORT_BE#(Bit#(BankAddrBits), Word, 4) sel(
                   BRAM_DUAL_PORT_BE#(Bit#(BankAddrBits), Word, 4) b),
                 Reg#(Bit#(3)) last) =
    interface BRAM_PORT_BE;
      method Action put(Bit#(4) we, Bit#(SocAddrBits) addr, Word d);
        Bit#(3) bank = truncateLSB(addr);
        sel(banks[bank]).put(we, truncate(addr), d);
        last <= bank;
      endmethod
      method Word read = sel(banks[last]).read;   // bank of the last request
    endinterface;

  Reg#(Bit#(3)) lastA <- mkReg(0);
  Reg#(Bit#(3)) lastB <- mkReg(0);
  function BRAM_PORT_BE#(Bit#(BankAddrBits), Word, 4) portA(BRAM_DUAL_PORT_BE#(Bit#(BankAddrBits), Word, 4) b) = b.a;
  function BRAM_PORT_BE#(Bit#(BankAddrBits), Word, 4) portB(BRAM_DUAL_PORT_BE#(Bit#(BankAddrBits), Word, 4) b) = b.b;

  interface a = bankedPort(portA, lastA);
  interface b = bankedPort(portB, lastB);
endmodule


// Data-side address decoder: UART registers, tohost, or RAM.
module mkDataRouter#(Server#(MemReq, Word) ram, Ifc_uart uart, Ifc_exitCtl ex)(Server#(MemReq, Word));
  FIFO#(Bool) fromIo <- mkSizedFIFO(4);   // source of each outstanding read
  FIFO#(Word) ioResp <- mkSizedFIFO(2);

  interface Put request;
    method Action put(MemReq r);
      if (r.addr[31:28] == ioRegion) begin
        Bit#(2) reg_ = r.addr[3:2];
        if (r.write) begin
          if (reg_ == 0) uart.txPut(r.data[7:0]);
        end
        else begin
          Word v = 0;
          if (reg_ == 1) begin
            v = uart.rxValid ? zeroExtend(uart.rxData) : 32'h80000000;
            if (uart.rxValid) uart.rxDeq;
          end
          else if (reg_ == 2)
            v = zeroExtend({pack(uart.rxValid), pack(uart.txFull)});
          else if (ex.status matches tagged Valid .c) begin
            v = {1'b1, 23'b0, c};
            ex.clear;
          end
          ioResp.enq(v);
          fromIo.enq(True);
        end
      end
      else begin
        if (r.write && (r.addr & ~3) == tohostAddr) ex.exit(truncate(r.data >> 1));
        ram.request.put(r);
        if (!r.write) fromIo.enq(False);
      end
    endmethod
  endinterface

  interface Get response;
    method ActionValue#(Word) get;
      fromIo.deq;
      Word v;
      if (fromIo.first) begin
        v = ioResp.first;
        ioResp.deq;
      end
      else
        v <- ram.response.get;
      return v;
    endmethod
  endinterface
endmodule


// Everything that is reset when a program exits.
module mkCoreSystem#(BRAM_DUAL_PORT_BE#(Bit#(SocAddrBits), Word, 4) bram,
                     Ifc_uart uart, Ifc_exitCtl ex)(Empty);
  Server#(MemReq, Word) iport <- mkBramServer(bram.a);
  Server#(MemReq, Word) dram  <- mkBramServer(bram.b);
  Server#(MemReq, Word) dport <- mkDataRouter(dram, uart, ex);
  Ifc_execute core <- mkcore(bootAddr, iport, dport);

  rule trapped (core.halted);
    ex.exit(8'hFF);
  endrule
endmodule


(* synthesize *)
module mksoc#(parameter Bit#(16) baudDivisor)(Ifc_soc);
  Clock clk <- exposeCurrentClock;
  MakeResetIfc coreRst <- mkReset(2, True, clk);

  BRAM_DUAL_PORT_BE#(Bit#(SocAddrBits), Word, 4) bram <- mkBankedBram;
  Ifc_uart uart <- mkuart(baudDivisor, True);

  Reg#(Maybe#(Bit#(8))) exitCode   <- mkReg(tagged Invalid);
  Reg#(Bit#(2))         lastResult <- mkReg(0);   // {failed, passed}
  Reg#(Bit#(26))        heartbeat  <- mkReg(0);
  Reg#(Bit#(21))        activity   <- mkReg(0);   // UART activity LED stretch

  rule tick;
    heartbeat <= heartbeat + 1;
    if (uart.txd == 0) activity <= '1;
    else if (activity != 0) activity <= activity - 1;
  endrule

  Ifc_exitCtl exitCtl = interface Ifc_exitCtl;
    method Action exit(Bit#(8) code);
      exitCode   <= tagged Valid code;
      lastResult <= (code == 0) ? 2'b01 : 2'b10;
      coreRst.assertReset;
    endmethod
    method Maybe#(Bit#(8)) status = exitCode;
    method Action clear;
      exitCode <= tagged Invalid;
    endmethod
  endinterface;

  let sys <- mkCoreSystem(bram, uart, exitCtl, reset_by coreRst.new_rst);

  method Bit#(1) uart_tx = uart.txd;
  method Action uart_rx(Bit#(1) b) = uart.rxd(b);
  method Bit#(4) leds = {heartbeat[25], lastResult, pack(activity != 0)};
endmodule

endpackage
