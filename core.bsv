package core;

import ClientServer :: *;
import common :: *;
import fetch :: *;
import decoder :: *;
import execute :: *;

// In-order RV32I pipeline: fetch -> decode/regread -> execute -> load writeback,
// with separate request/response instruction and data memory ports.
module mkcore#(Word startPC, Server#(MemReq, Word) imem, Server#(MemReq, Word) dmem)(Ifc_execute);
  Ifc_fetch   fetch <- mkfetch(startPC, imem);
  Ifc_decoder dec   <- mkdecoder(fetch);
  Ifc_execute exe   <- mkexecute(fetch, dec, dmem);
  return exe;
endmodule

endpackage
