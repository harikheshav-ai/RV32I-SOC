package mem;

import BRAM :: *;
import ClientServer :: *;
import GetPut :: *;
import common :: *;

// 64 KiB true dual-port BRAM at 0x80000000 (1-cycle read latency, byte-enable
// writes), initialised from prog.hex (one 32-bit word per line). Port A serves
// instruction fetch, port B data. A store to tohostAddr is captured for the
// testbench.
typedef 14 MemAddrBits;
Word memBase    = 32'h80000000;
Word tohostAddr = 32'h8000F000;

interface Ifc_tbmem;
  interface Server#(MemReq, Word) iport;
  interface Server#(MemReq, Word) dport;
  method Word tohost;
endinterface

module mkmem(Ifc_tbmem);
  BRAM_Configure cfg = defaultValue;
  cfg.memorySize   = 2 ** valueOf(MemAddrBits);
  cfg.latency      = 1;
  cfg.outFIFODepth = 3;   // latency + 2: sustains one read per cycle
  cfg.loadFormat   = tagged Hex "prog.hex";

  BRAM2PortBE#(Bit#(MemAddrBits), Word, 4) bram <- mkBRAM2ServerBE(cfg);
  Reg#(Word) rg_tohost <- mkReg(0);

  function BRAMRequestBE#(Bit#(MemAddrBits), Word, 4) toBram(MemReq r) =
    BRAMRequestBE {
      writeen: r.write ? r.byteEn : 0,
      responseOnWrite: False,
      address: truncate((r.addr - memBase) >> 2),
      datain: r.data
    };

  interface Server iport;
    interface Put request;
      method Action put(MemReq r) = bram.portA.request.put(toBram(r));
    endinterface
    interface Get response = bram.portA.response;
  endinterface

  interface Server dport;
    interface Put request;
      method Action put(MemReq r);
        bram.portB.request.put(toBram(r));
        if (r.write && (r.addr & ~3) == tohostAddr) rg_tohost <= r.data;
      endmethod
    endinterface
    interface Get response = bram.portB.response;
  endinterface

  method Word tohost = rg_tohost;
endmodule

endpackage
