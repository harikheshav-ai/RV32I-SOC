package execute;

import FIFO :: *;
import ClientServer :: *;
import GetPut :: *;
import common :: *;
import fetch :: *;
import decoder :: *;

// Execute stage: ALU, branch resolution, memory requests and writeback of
// non-load results. Loads complete in a separate writeback rule when the
// memory response arrives. Mispredicted control flow redirects fetch and
// flips the execute epoch; instructions carrying the old epoch are squashed.
interface Ifc_execute;
  method Bool halted;
  method Bool failed;   // halted because of a trap (illegal/misaligned/ecall/ebreak)
  method Bit#(64) instret;
endinterface


function Word alu(AluOp op, Word a, Word b);
  Bit#(5) sh = b[4:0];
  return case (op)
    Add:  (a + b);
    Sub:  (a - b);
    Sll:  (a << sh);
    Slt:  (signedLT(a, b) ? 1 : 0);
    Sltu: (a < b ? 1 : 0);
    Xor:  (a ^ b);
    Srl:  (a >> sh);
    Sra:  signedShiftRight(a, sh);
    Or:   (a | b);
    And:  (a & b);
  endcase;
endfunction

function Bool branchTaken(Bit#(3) funct3, Word a, Word b);
  return case (funct3)
    3'b000: (a == b);
    3'b001: (a != b);
    3'b100: signedLT(a, b);
    3'b101: signedGE(a, b);
    3'b110: (a < b);
    3'b111: (a >= b);
    default: False;
  endcase;
endfunction


module mkexecute#(Ifc_fetch fetch, Ifc_decoder dec, Server#(MemReq, Word) dmem)(Ifc_execute);

  Reg#(Bool)     eEpoch   <- mkReg(False);
  Reg#(Bool)     rg_halt  <- mkReg(False);
  Reg#(Bool)     rg_fail  <- mkReg(False);
  Reg#(Bit#(64)) rg_count <- mkReg(0);
  Reg#(Bool)     trace    <- mkReg(False);
  Reg#(Bool)     started  <- mkReg(False);

  FIFO#(E2W) e2w <- mkFIFO;   // loads waiting for data

  rule do_init (!started);
`ifndef FPGA
    let t <- $test$plusargs("trace");
    trace <= t;
`endif
    started <= True;
  endrule

  rule do_execute (started && !rg_halt);
    let e = dec.first;
    dec.deq;
    let d = e.dInst;

    if (e.epoch != eEpoch) begin
      // Wrong-path instruction: squash, but release its scoreboard entry.
      dec.writeback(d.rd, tagged Invalid);
    end
    else begin
      Word pc4    = e.pc + 4;
      Word nextPc = pc4;
      Word addr   = e.rv1 + d.imm;
      Bit#(5) bitOff = {addr[1:0], 3'b0};
      Maybe#(Word) result = tagged Invalid;
      Bool trap = False;
      String why = "";

      case (d.iType)
        ALU:    result = tagged Valid alu(d.aluOp, e.rv1, d.srcImm ? d.imm : e.rv2);
        LUI:    result = tagged Valid d.imm;
        AUIPC:  result = tagged Valid (e.pc + d.imm);
        JAL:    begin result = tagged Valid pc4; nextPc = e.pc + d.imm; end
        JALR:   begin result = tagged Valid pc4; nextPc = (e.rv1 + d.imm) & ~1; end
        BRANCH: if (branchTaken(d.funct3, e.rv1, e.rv2)) nextPc = e.pc + d.imm;
        LOAD: begin
          Bool misaligned = (d.funct3[1:0] == 2'b01 && addr[0] != 0)
                         || (d.funct3[1:0] == 2'b10 && addr[1:0] != 0);
          if (misaligned) begin trap = True; why = "misaligned load"; end
          else begin
            dmem.request.put(memRead(addr));
            e2w.enq(E2W { pc: e.pc, inst: e.inst, rd: d.rd, funct3: d.funct3, addr: addr });
          end
        end
        STORE: begin
          Bool misaligned = (d.funct3[1:0] == 2'b01 && addr[0] != 0)
                         || (d.funct3[1:0] == 2'b10 && addr[1:0] != 0);
          if (misaligned) begin trap = True; why = "misaligned store"; end
          else begin
            Bit#(4) be = case (d.funct3[1:0])
              2'b00: (4'b0001 << addr[1:0]);
              2'b01: (4'b0011 << addr[1:0]);
              default: 4'b1111;
            endcase;
            dmem.request.put(MemReq { write: True, byteEn: be, addr: addr, data: e.rv2 << bitOff });
          end
        end
        FENCE:   noAction;
        ECALL:   begin trap = True; why = "ecall"; end
        EBREAK:  begin trap = True; why = "ebreak"; end
        ILLEGAL: begin trap = True; why = "illegal instruction"; end
      endcase

      if (!trap && nextPc[1:0] != 0) begin trap = True; why = "misaligned jump target"; end

      if (trap) begin
        $display("[execute] trap: %s at pc 0x%08h (inst 0x%08h)", why, e.pc, e.inst);
        rg_halt <= True;
        rg_fail <= True;
        dec.writeback(d.rd, tagged Invalid);
      end
      else begin
        if (d.iType != LOAD) dec.writeback(d.rd, result);  // loads: do_writeback
        rg_count <= rg_count + 1;
        if (nextPc != pc4) begin
          fetch.redirect(nextPc);
          eEpoch <= !eEpoch;
        end

        // Commit log in spike --log-commits format (loads log in do_writeback).
        if (trace && d.iType != LOAD) begin
          $write("core   0: 3 0x%08h (0x%08h)", e.pc, e.inst);
          if (result matches tagged Valid .v &&& d.rd != 0)
            $write(" x%0d%s 0x%08h", d.rd, d.rd < 10 ? "  " : " ", v);
          if (d.iType == STORE) case (d.funct3[1:0])
            2'b00: $write(" mem 0x%08h 0x%02h", addr, e.rv2[7:0]);
            2'b01: $write(" mem 0x%08h 0x%04h", addr, e.rv2[15:0]);
            default: $write(" mem 0x%08h 0x%08h", addr, e.rv2);
          endcase
          $display("");
        end
      end
    end
  endrule

  // Load data returns from memory: align, extend and write back. Fires before
  // do_execute each cycle, so commits are logged in program order.
  rule do_writeback;
    let l = e2w.first;
    e2w.deq;
    let resp <- dmem.response.get;
    Word w = resp >> {l.addr[1:0], 3'b0};
    Word v = case (l.funct3)
      3'b000: signExtend(w[7:0]);
      3'b001: signExtend(w[15:0]);
      3'b100: zeroExtend(w[7:0]);
      3'b101: zeroExtend(w[15:0]);
      default: w;
    endcase;
    dec.writebackLoad(l.rd, v);
    if (trace) begin
      $write("core   0: 3 0x%08h (0x%08h)", l.pc, l.inst);
      if (l.rd != 0) $write(" x%0d%s 0x%08h", l.rd, l.rd < 10 ? "  " : " ", v);
      $display(" mem 0x%08h", l.addr);
    end
  endrule

  method Bool halted = rg_halt;
  method Bool failed = rg_fail;
  method Bit#(64) instret = rg_count;

endmodule


endpackage
