package uart;

import FIFOF :: *;

// 8N1 UART with 16-byte TX and RX FIFOs. `divisor` is clock cycles per bit
// (e.g. 50 MHz / 115200 = 434).
//
// When compiled with -D SIMULATE and `simLog` is set, every byte handed to the
// transmitter is also appended to uart.log (printable characters, tabs and
// newlines only), so program output can be inspected without decoding the
// serial line.
interface Ifc_uart;
  (* always_ready *)                  method Bit#(1) txd;
  (* always_ready, always_enabled *)  method Action  rxd(Bit#(1) b);

  method Action  txPut(Bit#(8) b);   // blocks while the TX FIFO is full
  method Bool    txFull;
  method Bool    rxValid;
  method Bit#(8) rxData;             // valid when rxValid
  method Action  rxDeq;
endinterface

module mkuart#(Bit#(16) divisor, Bool simLog)(Ifc_uart);

  // ---------------- transmitter ----------------
  FIFOF#(Bit#(8)) txQ     <- mkSizedFIFOF(16);
  Reg#(Bit#(9))   txShift <- mkReg('1);   // data bits then stop bit, LSB first
  Reg#(Bit#(4))   txBits  <- mkReg(0);    // bit periods left in this frame
  Reg#(Bit#(16))  txCnt   <- mkReg(0);
  Reg#(Bit#(1))   txLine  <- mkReg(1);

`ifdef SIMULATE
  Reg#(Bool) logOpen <- mkReg(False);
  Reg#(File) logFile <- mkReg(InvalidFile);

  if (simLog)
    rule open_log (!logOpen);
      File f <- $fopen("uart.log", "w");
      logFile <= f;
      logOpen <= True;
    endrule
`endif

  rule tx_start (txBits == 0);
    let b = txQ.first;
    txQ.deq;
    txLine  <= 0;   // start bit
    txShift <= {1'b1, b};
    txBits  <= 10;
    txCnt   <= divisor - 1;
`ifdef SIMULATE
    if (simLog && logOpen && ((b >= 8'h20 && b < 8'h7f) || b == 8'h0a || b == 8'h09)) begin
      $fwrite(logFile, "%c", b);
      $fflush(logFile);
    end
`endif
  endrule

  rule tx_tick (txBits != 0);
    if (txCnt != 0)
      txCnt <= txCnt - 1;
    else begin
      txBits <= txBits - 1;
      if (txBits > 1) begin
        txLine  <= txShift[0];
        txShift <= txShift >> 1;
        txCnt   <= divisor - 1;
      end
    end
  endrule

  // ---------------- receiver ----------------
  FIFOF#(Bit#(8)) rxQ     <- mkGSizedFIFOF(False, True, 16);  // first/deq unguarded
  Reg#(Bit#(1))   rxSync1 <- mkReg(1);
  Reg#(Bit#(1))   rxSync2 <- mkReg(1);
  Reg#(Bit#(4))   rxState <- mkReg(0);    // 0 idle, 1 start, 2-9 data, 10 stop
  Reg#(Bit#(16))  rxCnt   <- mkReg(0);
  Reg#(Bit#(8))   rxShift <- mkReg(0);

  (* fire_when_enabled, no_implicit_conditions *)
  rule rx_sync;
    rxSync2 <= rxSync1;
  endrule

  // Samples each bit in the middle of its period.
  (* fire_when_enabled *)
  rule rx_sample;
    if (rxState == 0) begin
      if (rxSync2 == 0) begin
        rxState <= 1;
        rxCnt   <= divisor >> 1;
      end
    end
    else if (rxCnt != 0)
      rxCnt <= rxCnt - 1;
    else if (rxState == 1) begin
      rxState <= (rxSync2 == 0) ? 2 : 0;   // false start: glitch
      rxCnt   <= divisor - 1;
    end
    else if (rxState < 10) begin
      rxShift <= {rxSync2, rxShift[7:1]};
      rxState <= rxState + 1;
      rxCnt   <= divisor - 1;
    end
    else begin
      // Stop bit. Frames with a bad stop bit, or arriving with the FIFO full,
      // are dropped.
      if (rxSync2 == 1 && rxQ.notFull) rxQ.enq(rxShift);
      rxState <= 0;
    end
  endrule

  method Bit#(1) txd = txLine;
  method Action rxd(Bit#(1) b);
    rxSync1 <= b;
  endmethod

  method Action txPut(Bit#(8) b) = txQ.enq(b);
  method Bool txFull = !txQ.notFull;
  method Bool rxValid = rxQ.notEmpty;
  method Bit#(8) rxData = rxQ.first;
  method Action rxDeq = rxQ.deq;

endmodule

endpackage
