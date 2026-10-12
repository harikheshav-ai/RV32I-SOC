// Arty A7-100T top level: 100 MHz board clock / 2 -> 50 MHz core clock,
// reset from the red RESET button (ck_rst, active low) and a startup delay.
`default_nettype none

module arty_top (
  input  wire       CLK100MHZ,
  input  wire       ck_rst,
  input  wire       uart_txd_in,    // from the FTDI chip (host TX)
  output wire       uart_rxd_out,   // to the FTDI chip (host RX)
  output wire [3:0] led
);
  localparam integer CORE_CLK_HZ = 50_000_000;
  localparam integer BAUD        = 115_200;
  localparam [15:0]  BAUD_DIV    = (CORE_CLK_HZ + BAUD / 2) / BAUD;   // 434

  // 50 MHz core clock: the 100 MHz board clock divided by two.
  reg clk_div = 1'b0;
  always @(posedge CLK100MHZ)
    clk_div <= ~clk_div;
  wire clk;
  BUFG bufg (.I(clk_div), .O(clk));

  // Hold the SoC in reset for ~21 ms after configuration as well as while the
  // board reset button is held, so a JTAG bitstream load starts the SoC from
  // reset like a button press.
  reg [20:0] startup_cnt  = 21'd0;
  wire       startup_done = startup_cnt[20];
  always @(posedge clk)
    if (!startup_done) startup_cnt <= startup_cnt + 1'b1;

  // Asynchronous assert, synchronous release.
  reg [3:0] rst_sync = 4'b0;
  wire      rst_in_n = ck_rst & startup_done;
  always @(posedge clk or negedge rst_in_n)
    if (!rst_in_n) rst_sync <= 4'b0;
    else           rst_sync <= {rst_sync[2:0], 1'b1};
  wire rst_n = rst_sync[3];

  mksoc #(.baudDivisor(BAUD_DIV)) soc (
    .CLK     (clk),
    .RST_N   (rst_n),
    .uart_rx (uart_txd_in),
    .uart_tx (uart_rxd_out),
    .leds    (led)
  );
endmodule

`default_nettype wire
