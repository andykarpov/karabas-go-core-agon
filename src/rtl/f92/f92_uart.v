// karabas: eZ80F92 UART (UART0 C0h..C7h: the link to the VDP inside the FPGA; UART1 D0h..D7h).
//
// No serialisation: bytes go to / come from a byte link (the VDP side has its own FIFO and drives
// cts from its level). Registers as the Agon emulator (uart.rs) and MOS (uart.c, serial.asm):
//   +0 read RBR (pops the RX FIFO) / write THR (pushes the TX FIFO); with LCTL.7 (DLAB) BRG_L
//   +1 IER (0 RIE, 1 TIE); with DLAB BRG_H
//   +2 read IIR: C0 with FIFOs on (FCTL.0), cause 04 RX data, 02 TX empty, 01 none; write FCTL
//      (bit 1 / 2 clear the RX / TX FIFO)
//   +3 LCTL   +4 MCTL   +7 SPR (scratch): read / write
//   +5 LSR: 0 data ready, 5 THRE and 6 TEMT = the TX FIFO is empty
//   +6 MSR: 4 CTS (from the link)
// irq = RIE and data ready, or TIE and TX empty (uart.rs is_interrupt_due).
module f92_uart (
	input             clk,
	input             reset,
	input             sel,         // the port is in this UART (rd / wr below)
	input       [2:0] addr,
	input             rd,          // one-clock read strobe (taken with the data)
	input             wr,          // one-clock write strobe
	input       [7:0] din,
	output reg  [7:0] dout,        // read data for addr (combinational)
	output            irq,
	// the link
	output      [7:0] tx_data,
	output            tx_valid,
	input             tx_ready,    // the far side takes tx_data this clock
	input       [7:0] rx_data,
	input             rx_valid,    // a byte from the far side (dropped when the RX FIFO is full)
	output            rx_full,
	input             cts
);
	reg [7:0] ier, fctl, lctl, mctl, spr, brg_l, brg_h;

	// FIFOs of 16
	reg [7:0] txf [0:15];
	reg [7:0] rxf [0:15];
	reg [4:0] tx_n, rx_n;
	reg [3:0] tx_rp, tx_wp, rx_rp, rx_wp;

	wire dlab     = lctl[7];
	wire rx_rdy   = rx_n != 5'd0;
	wire tx_empty = tx_n == 5'd0;
	assign tx_data  = txf[tx_rp];
	assign tx_valid = !tx_empty;
	assign rx_full  = rx_n == 5'd16;
	assign irq = (ier[0] & rx_rdy) | (ier[1] & tx_empty);

	wire [7:0] iir = {fctl[0] ? 2'b11 : 2'b00, 3'b000,
	                  ier[0] & rx_rdy ? 3'b100 : ier[1] & tx_empty ? 3'b010 : 3'b001};

	always @* begin
		case (addr)
		3'd0: dout = dlab ? brg_l : (rx_rdy ? rxf[rx_rp] : 8'h00);
		3'd1: dout = dlab ? brg_h : ier;
		3'd2: dout = iir;
		3'd3: dout = lctl;
		3'd4: dout = mctl;
		3'd5: dout = {1'b0, tx_empty, tx_empty, 4'b0000, rx_rdy};
		3'd6: dout = {3'b000, cts, 4'b0000};
		default: dout = spr;
		endcase
	end

	wire push_tx = sel && wr && addr == 3'd0 && !dlab && tx_n != 5'd16;
	wire pop_tx  = tx_valid && tx_ready;
	wire pop_rx  = sel && rd && addr == 3'd0 && !dlab && rx_rdy;
	wire push_rx = rx_valid && !rx_full;
	wire clr_rx  = sel && wr && addr == 3'd2 && din[1];
	wire clr_tx  = sel && wr && addr == 3'd2 && din[2];

	always @(posedge clk) begin
		if (reset) begin
			ier <= 8'h00; fctl <= 8'h00; lctl <= 8'h00; mctl <= 8'h00; spr <= 8'h00;
			brg_l <= 8'h02; brg_h <= 8'h00;
			tx_n <= 5'd0; rx_n <= 5'd0; tx_rp <= 4'd0; tx_wp <= 4'd0; rx_rp <= 4'd0; rx_wp <= 4'd0;
		end else begin
			if (push_tx) begin txf[tx_wp] <= din; tx_wp <= tx_wp + 4'd1; end
			if (pop_tx) tx_rp <= tx_rp + 4'd1;
			if (clr_tx) begin tx_n <= 5'd0; tx_rp <= 4'd0; tx_wp <= 4'd0; end
			else tx_n <= tx_n + (push_tx ? 5'd1 : 5'd0) - (pop_tx ? 5'd1 : 5'd0);

			if (push_rx) begin rxf[rx_wp] <= rx_data; rx_wp <= rx_wp + 4'd1; end
			if (pop_rx) rx_rp <= rx_rp + 4'd1;
			if (clr_rx) begin rx_n <= 5'd0; rx_rp <= 4'd0; rx_wp <= 4'd0; end
			else rx_n <= rx_n + (push_rx ? 5'd1 : 5'd0) - (pop_rx ? 5'd1 : 5'd0);

			if (sel && wr) begin
				case (addr)
				3'd0: if (dlab) brg_l <= din;
				3'd1: if (dlab) brg_h <= din; else ier <= din;
				3'd2: fctl <= din;
				3'd3: lctl <= din;
				3'd4: mctl <= din;
				3'd7: spr <= din;
				default: ;
				endcase
			end
		end
	end
endmodule
