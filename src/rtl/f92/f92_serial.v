// karabas: the serial line of an eZ80F92 UART (UART1 -> the ESP8266 of the board, docs/PLAN.md Ф2).
//
// 8N1 only (MOS open_UART1 / the Agon programs use 8N1; LCTL data / stop / parity bits are ignored).
// Bit rate as the F92: sys_ce (18.432 MHz) / (16 * BRG), BRG = 0 taken as 1 (115200 = BRG 10, exact),
// BRG above 4095 not supported (below 282 baud).
// The receive side keeps its own 2048-byte buffer in a block RAM in front of the 16-byte UART FIFO:
// the module sends bursts and a few bytes more after CTS goes up. cts_n to the module = 1 while more
// 1792 bytes or more wait (as term_uart of core-term). Bytes go to the UART one by one while its FIFO
// is not full (rx_valid one clock, then two clocks for the FIFO count).
// The transmit side takes tx_data when tx_valid and idle (tx_ready one clock = the UART pops it);
// tx_busy = a byte is on the line (LSR TEMT).
module f92_serial (
	input             clk,
	input             reset,
	input             sys_ce,
	input      [15:0] brg,
	// the line
	input             rxd,
	output reg        txd,
	output            cts_n,
	// the UART side
	input       [7:0] tx_data,
	input             tx_valid,
	output            tx_ready,
	output            tx_busy,
	output      [7:0] rx_data,
	output            rx_avail,
	input             rx_pop,
	input             rx_clr
);
	// x16 tick: BRG low 12 bits (down to 282 baud; MOS 300 baud = 3840), counted 1..BRG (>=: a new BRG below the count takes at once)
	reg [11:0] div;
	reg tick;
	always @(posedge clk) begin
		tick <= 1'b0;
		if (reset) div <= 12'd1;
		else if (sys_ce) begin
			if (div >= brg[11:0]) begin div <= 12'd1; tick <= 1'b1; end
			else div <= div + 12'd1;
		end
	end

	// ---------------------------------------------------------------- receive
	reg [2:0] rx_s;
	always @(posedge clk) rx_s <= {rx_s[1:0], rxd};
	wire rx = rx_s[2];

	reg [1:0] r_st;          // 0 idle, 1 start, 2 data, 3 stop
	reg [3:0] r_cnt;
	reg [2:0] r_bit;
	reg [7:0] r_sh;
	reg r_done;
	always @(posedge clk) begin
		r_done <= 1'b0;
		if (reset) r_st <= 2'd0;
		else if (tick) case (r_st)
		2'd0: if (!rx) begin r_st <= 2'd1; r_cnt <= 4'd6; end      // the middle of the start bit
		2'd1: if (r_cnt == 4'd0) begin
				if (!rx) begin r_st <= 2'd2; r_cnt <= 4'd15; r_bit <= 3'd0; end
				else r_st <= 2'd0;                                    // a glitch
			end else r_cnt <= r_cnt - 4'd1;
		2'd2: if (r_cnt == 4'd0) begin
				r_sh <= {rx, r_sh[7:1]};
				r_cnt <= 4'd15;
				if (r_bit == 3'd7) r_st <= 2'd3;
				r_bit <= r_bit + 3'd1;
			end else r_cnt <= r_cnt - 4'd1;
		2'd3: if (r_cnt == 4'd0) begin
				r_st <= 2'd0;
				r_done <= rx;                                         // stop bit 0: dropped
			end else r_cnt <= r_cnt - 4'd1;
		endcase
	end

	reg [7:0] mem [0:2047];
	reg [10:0] wp, rp;
	wire [10:0] n = wp - rp;
	assign cts_n = &n[10:8];             // 1792 or more
	reg [7:0] q;
	reg [1:0] hold;          // clocks until q is the new head
	assign rx_avail = n != 11'd0 && hold == 2'd0;
	assign rx_data  = q;
	always @(posedge clk) begin
		q <= mem[rp];
		if (r_done && ~&n) mem[wp] <= r_sh;
		if (reset || rx_clr) begin
			wp <= 11'd0; rp <= 11'd0; hold <= 2'd0;
		end else begin
			if (r_done && ~&n) wp <= wp + 11'd1;
			// q follows mem[rp] two clocks after a pop, or after the write into an empty buffer
			if ((rx_pop && rx_avail) || (r_done && n == 11'd0)) hold <= 2'd2;
			else if (hold != 2'd0) hold <= hold - 2'd1;
			if (rx_pop && rx_avail) rp <= rp + 11'd1;
		end
	end

	// ---------------------------------------------------------------- transmit
	reg [3:0] t_cnt;
	reg [3:0] t_bit;
	reg [8:0] t_sh;
	reg t_on;
	assign tx_busy  = t_on;
	assign tx_ready = !t_on && tx_valid && !reset;
	always @(posedge clk) begin
		if (reset) begin
			t_on <= 1'b0; txd <= 1'b1;
		end else if (!t_on) begin
			txd <= 1'b1;
			if (tx_valid) begin
				t_on <= 1'b1; t_sh <= {tx_data, 1'b0}; t_bit <= 4'd0; t_cnt <= 4'd0;
			end
		end else if (tick) begin
			if (t_cnt == 4'd0) begin
				if (t_bit == 4'd10) t_on <= 1'b0;                     // after the stop bit
				else begin
					txd <= (t_bit == 4'd9) ? 1'b1 : t_sh[0];
					t_sh <= {1'b1, t_sh[8:1]};
					t_bit <= t_bit + 4'd1;
					t_cnt <= 4'd15;
				end
			end else t_cnt <= t_cnt - 4'd1;
		end
	end
endmodule
