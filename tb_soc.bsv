package tb_soc;

import StmtFSM :: *;
import soc :: *;
import uart :: *;

// SoC testbench: a second UART acts as the host. It loads prog.bin through the
// bootloader protocol (see sw/boot/boot.c) and echoes program output to stdout.
// The program is run twice, which checks that the core comes back to the
// bootloader cleanly after an exit. The SoC's own UART writes the program
// output to uart.log.
typedef 8 SimBaudDivisor;   // cycles per bit; small to keep simulation fast
typedef 2 Runs;

module mktb_soc(Empty);
  Ifc_soc  soc  <- mksoc(fromInteger(valueOf(SimBaudDivisor)));
  Ifc_uart host <- mkuart(fromInteger(valueOf(SimBaudDivisor)), False);

  (* fire_when_enabled, no_implicit_conditions *)
  rule connect;
    soc.uart_rx(host.txd);
    host.rxd(soc.uart_tx);
  endrule

  Reg#(Bit#(64)) cycle <- mkReg(0);
  rule tick;
    cycle <= cycle + 1;
  endrule

  rule timeout (cycle == 200000000);
    $display("\n[tb] FAIL (timeout)");
    $finish(0);
  endrule

  // ---------------- receive side ----------------
  // 0: before load ack, 1: loading, 2: checksum, 3: running, 4: exit code
  Reg#(Bit#(3))  phase   <- mkReg(0);
  Reg#(Bit#(2))  csumIdx <- mkReg(0);
  Reg#(Bit#(32)) csum    <- mkReg(0);
  Reg#(Bit#(32)) sum     <- mkReg(0);   // of the bytes sent
  Reg#(Bit#(64)) startCycle <- mkReg(0);
  Reg#(UInt#(4)) runs       <- mkReg(0);

  function Action echo(Bit#(8) b) = action
    if ((b >= 8'h20 && b < 8'h7f) || b == 8'h0a) $write("%c", b);
  endaction;

  rule host_rx (host.rxValid);
    let b = host.rxData;
    host.rxDeq;
    case (phase)
      0: if (b == 8'h06) phase <= 1; else echo(b);
      1: if (b == 8'h06) phase <= 2;
         else if (b == 8'h15) begin $display("[tb] FAIL (image rejected)"); $finish(0); end
         else echo(b);
      2: begin
           Bit#(32) c = csum | (zeroExtend(b) << {csumIdx, 3'b0});
           csum <= c;
           csumIdx <= csumIdx + 1;
           if (csumIdx == 3) begin
             if (c != sum) begin
               $display("[tb] FAIL (checksum %h, expected %h)", c, sum);
               $finish(0);
             end
             phase <= 3;
             startCycle <= cycle;
           end
         end
      3: if (b == 8'h04) phase <= 4; else echo(b);
      4: begin
           $display("[tb] run %0d: exit reported %0d cycles after load", runs + 1, cycle - startCycle);
           if (b != 0) begin
             $display("[tb] FAIL (exit code %0d)", b);
             $finish(0);
           end
           else if (runs + 1 == fromInteger(valueOf(Runs))) begin
             $display("[tb] PASS");
             $finish(0);
           end
           runs    <= runs + 1;
           phase   <= 0;
           csum    <= 0;
           csumIdx <= 0;
         end
    endcase
  endrule

  // ---------------- send side ----------------
  Reg#(File)     fin <- mkReg(InvalidFile);
  Reg#(Bool)     eof <- mkReg(False);
  Reg#(Bit#(32)) len <- mkReg(0);
  Reg#(Bit#(3))  i   <- mkReg(0);

  function Action openProg = action
    let f <- $fopen("prog.bin", "rb");
    if (f == InvalidFile) begin
      $display("[tb] cannot open prog.bin");
      $finish(1);
    end
    fin <= f;
    eof <= False;
  endaction;

  Stmt load = seq
    action len <= 0; sum <= 0; endaction
    openProg;
    while (!eof) action
      let c <- $fgetc(fin);
      if (c == -1) eof <= True; else len <= len + 1;
    endaction
    $fclose(fin);
    openProg;

    host.txPut(8'h4c);   // 'L'
    await(phase == 1);
    for (i <= 0; i < 4; i <= i + 1)
      host.txPut(truncate(len >> {i, 3'b0}));
    while (!eof) action
      let c <- $fgetc(fin);
      if (c == -1) eof <= True;
      else begin
        host.txPut(truncate(pack(c)));
        sum <= sum + zeroExtend(pack(c)[7:0]);
      end
    endaction
    $fclose(fin);
  endseq;

  FSM loader <- mkFSM(load);
  Reg#(UInt#(4)) loads <- mkReg(0);

  // Start the next load once the previous run has reported its exit.
  rule start (loader.done && loads == runs);
    loader.start;
    loads <= loads + 1;
  endrule
endmodule

endpackage
