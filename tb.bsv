package tb;

import common :: *;
import mem :: *;
import execute :: *;
import core :: *;

// Runs prog.hex until the program writes tohost (riscv-tests convention:
// 1 = pass, (n << 1) | 1 = fail with code n), the core traps, or timeout.
module mktb(Empty);
  Ifc_tbmem   mem  <- mkmem;
  Ifc_execute core <- mkcore(memBase, mem.iport, mem.dport);

  Reg#(Bit#(64)) cycle <- mkReg(0);

  rule tick;
    cycle <= cycle + 1;
  endrule

  rule finish (mem.tohost != 0 || core.halted || cycle == 10000000);
    let code = mem.tohost >> 1;
    $display("[tb] cycles=%0d instret=%0d", cycle, core.instret);
    if (mem.tohost == 1) $display("[tb] PASS");
    else if (mem.tohost != 0) $display("[tb] FAIL (tohost code %0d)", code);
    else if (core.halted) $display("[tb] FAIL (core trapped)");
    else $display("[tb] FAIL (timeout)");
    $finish(0);
  endrule
endmodule

endpackage
