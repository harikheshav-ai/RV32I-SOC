package decoder;

import FIFO :: *;
import Vector :: *;
import common :: *;
import fetch :: *;

// Decode stage: decodes the instruction and reads the register file.
// A scoreboard stalls on RAW/WAW hazards with instructions still in flight;
// the value being written back in the current cycle is bypassed.
interface Ifc_decoder;
  method D2E first;
  method Action deq;
  // Called by execute once per non-load instruction leaving the pipeline
  // (including squashed ones) to release the scoreboard entry for rd.
  method Action writeback(RIdx rd, Maybe#(Word) value);
  // Called by the writeback stage when load data returns from memory.
  method Action writebackLoad(RIdx rd, Word value);
endinterface


function DecodedInst decode(Word inst);
  Bit#(7) opcode = inst[6:0];
  RIdx    rd     = inst[11:7];
  Bit#(3) funct3 = inst[14:12];
  RIdx    rs1    = inst[19:15];
  RIdx    rs2    = inst[24:20];
  Bit#(7) funct7 = inst[31:25];

  Word immI = signExtend(inst[31:20]);
  Word immS = signExtend({inst[31:25], inst[11:7]});
  Word immB = signExtend({inst[31], inst[7], inst[30:25], inst[11:8], 1'b0});
  Word immU = {inst[31:12], 12'b0};
  Word immJ = signExtend({inst[31], inst[19:12], inst[20], inst[30:21], 1'b0});

  DecodedInst d = DecodedInst {
    iType: ILLEGAL, aluOp: Add, funct3: funct3, rd: 0, rs1: rs1, rs2: rs2,
    useRs1: False, useRs2: False, srcImm: False, imm: 0
  };

  // ALU op from funct3/funct7 (shared by OP and OP-IMM).
  AluOp op = case (funct3)
    3'b000: ((opcode == 7'b0110011 && funct7 == 7'b0100000) ? Sub : Add);
    3'b001: Sll;
    3'b010: Slt;
    3'b011: Sltu;
    3'b100: Xor;
    3'b101: (funct7 == 7'b0100000 ? Sra : Srl);
    3'b110: Or;
    3'b111: And;
  endcase;

  case (opcode)
    7'b0110111: begin // LUI
      d.iType = LUI; d.rd = rd; d.imm = immU;
    end
    7'b0010111: begin // AUIPC
      d.iType = AUIPC; d.rd = rd; d.imm = immU;
    end
    7'b1101111: begin // JAL
      d.iType = JAL; d.rd = rd; d.imm = immJ;
    end
    7'b1100111: if (funct3 == 0) begin // JALR
      d.iType = JALR; d.rd = rd; d.imm = immI; d.useRs1 = True;
    end
    7'b1100011: if (funct3 != 3'b010 && funct3 != 3'b011) begin // BRANCH
      d.iType = BRANCH; d.imm = immB; d.useRs1 = True; d.useRs2 = True;
    end
    7'b0000011: if (funct3 != 3'b011 && funct3 != 3'b110 && funct3 != 3'b111) begin // LOAD
      d.iType = LOAD; d.rd = rd; d.imm = immI; d.useRs1 = True;
    end
    7'b0100011: if (funct3 <= 3'b010) begin // STORE
      d.iType = STORE; d.imm = immS; d.useRs1 = True; d.useRs2 = True;
    end
    7'b0010011: begin // OP-IMM
      Bool shift = funct3 == 3'b001 || funct3 == 3'b101;
      Bool legal = !shift || funct7 == 7'b0000000 || (funct3 == 3'b101 && funct7 == 7'b0100000);
      if (legal) begin
        d.iType = ALU; d.aluOp = op; d.rd = rd; d.imm = immI;
        d.useRs1 = True; d.srcImm = True;
      end
    end
    7'b0110011: begin // OP
      Bool alt = funct3 == 3'b000 || funct3 == 3'b101;
      if (funct7 == 7'b0000000 || (alt && funct7 == 7'b0100000)) begin
        d.iType = ALU; d.aluOp = op; d.rd = rd; d.useRs1 = True; d.useRs2 = True;
      end
    end
    7'b0001111: if (funct3 == 3'b000) begin // FENCE (no-op on this in-order core)
      d.iType = FENCE;
    end
    7'b1110011: begin // SYSTEM
      if (inst == 32'h00000073) d.iType = ECALL;
      else if (inst == 32'h00100073) d.iType = EBREAK;
    end
  endcase

  return d;
endfunction


module mkdecoder#(Ifc_fetch fetch)(Ifc_decoder);

  // Port 0: load writeback, port 1: execute writeback, port 2: decode.
  // Decode sees values written back in the same cycle (bypass) and the
  // cleared busy bits.
  Vector#(32, Array#(Reg#(Word))) rf   <- replicateM(mkCReg(3, 0));
  Vector#(32, Array#(Reg#(Bool))) busy <- replicateM(mkCReg(3, False));

  FIFO#(D2E) d2e <- mkFIFO;

  function Word readReg(RIdx r) = (r == 0) ? 0 : rf[r][2];

  let f     = fetch.first;
  let dInst = decode(f.inst);
  Bool stall = (dInst.useRs1 && busy[dInst.rs1][2])
            || (dInst.useRs2 && busy[dInst.rs2][2])
            || (dInst.rd != 0 && busy[dInst.rd][2]);

  rule do_decode (!stall);
    fetch.deq;
    d2e.enq(D2E {
      pc: f.pc, inst: f.inst, dInst: dInst,
      rv1: readReg(dInst.rs1), rv2: readReg(dInst.rs2), epoch: f.epoch
    });
    if (dInst.rd != 0) busy[dInst.rd][2] <= True;
  endrule

  method D2E first = d2e.first;
  method Action deq = d2e.deq;

  method Action writeback(RIdx rd, Maybe#(Word) value);
    if (rd != 0) begin
      busy[rd][1] <= False;
      if (value matches tagged Valid .v) rf[rd][1] <= v;
    end
  endmethod

  method Action writebackLoad(RIdx rd, Word value);
    if (rd != 0) begin
      busy[rd][0] <= False;
      rf[rd][0]   <= value;
    end
  endmethod

endmodule


endpackage
