package fetch;

import FIFO :: *;
import ClientServer :: *;
import GetPut :: *;
import common :: *;

// Fetch stage: issues one instruction-memory request per cycle, predicting
// PC+4. Execute corrects mispredictions through redirect(), which flips the
// epoch; responses to requests issued under the old epoch are dropped here,
// and any already passed on are squashed in execute.
interface Ifc_fetch;
  method F2D first;
  method Action deq;
  method Action redirect(Word npc);
endinterface


module mkfetch#(Word startPC, Server#(MemReq, Word) imem)(Ifc_fetch);

  // Port 0: fetch rules, port 1: redirect (redirect wins in the same cycle).
  Reg#(Word) pc[2]    <- mkCReg(2, startPC);
  Reg#(Bool) epoch[2] <- mkCReg(2, False);

  // (pc, epoch) of each outstanding request, in issue order.
  FIFO#(Tuple2#(Word, Bool)) inflight <- mkSizedFIFO(4);
  FIFO#(F2D) f2d <- mkFIFO;

  rule do_request;
    imem.request.put(memRead(pc[0]));
    inflight.enq(tuple2(pc[0], epoch[0]));
    pc[0] <= pc[0] + 4;
  endrule

  rule do_response;
    let inst <- imem.response.get;
    match {.ipc, .iepoch} = inflight.first;
    inflight.deq;
    if (iepoch == epoch[0])
      f2d.enq(F2D { pc: ipc, inst: inst, epoch: iepoch });
  endrule

  method F2D first = f2d.first;
  method Action deq = f2d.deq;

  method Action redirect(Word npc);
    pc[1]    <= npc;
    epoch[1] <= !epoch[1];
  endmethod

endmodule


endpackage
