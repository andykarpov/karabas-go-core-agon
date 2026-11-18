// karabas: eZ80F92 SPI, master only (ports B8h..BCh), for the SD card of MOS (sd.asm / spi.asm;
// the chip select is GPIO PB4).
//   B8 BRG_L, B9 BRG_H: SCK = system clock / (2 * BRG) (MOS: BRG 3 -> 3.072 MHz)
//   BA CTL: 5 SPI_EN, 4 MASTER_EN, 3 CPOL, 2 CPHA (modes 0..3)
//   BB SR read: 7 SPIF (the transfer is done; cleared by the SR read, as the Agon emulator)
//   BC write TSR: starts an 8-bit transfer (MSB first) when SPI_EN; read RBR: the received byte
// The bit clock steps on sys_ce (the 18.432 MHz system clock enable).
module f92_spi (
	input             clk,
	input             reset,
	input             sys_ce,
	input             sel,         // the port is in B8h..BCh (rd / wr below)
	input       [2:0] addr,        // port - B8h
	input             rd,          // one-clock read strobe (taken with the data)
	input             wr,          // one-clock write strobe
	input       [7:0] din,
	output reg  [7:0] dout,        // read data for addr (combinational)
	output            sck,
	output            mosi,
	input             miso,
	output            busy
);
	reg  [7:0] brg_l, brg_h, ctl, sr, tsr, rbr;
	reg [15:0] hc;           // half-period counter
	reg  [4:0] edges;        // edges left: 16 per byte
	reg        sck_r, mosi_r;

	wire cpol = ctl[3];
	wire cpha = ctl[2];
	wire [15:0] brg = {brg_h, brg_l} == 16'd0 ? 16'd1 : {brg_h, brg_l};
	assign busy = edges != 5'd0;
	assign sck  = sck_r ^ cpol;
	assign mosi = mosi_r;

	always @* begin
		case (addr)
		3'd0: dout = brg_l;
		3'd1: dout = brg_h;
		3'd2: dout = ctl;
		3'd3: dout = sr;
		3'd4: dout = rbr;
		default: dout = 8'hff;
		endcase
	end

	always @(posedge clk) begin
		if (reset) begin
			brg_l <= 8'h02; brg_h <= 8'h00; ctl <= 8'h04; sr <= 8'h00; tsr <= 8'hff; rbr <= 8'hff;
			hc <= 16'd0; edges <= 5'd0; sck_r <= 1'b0; mosi_r <= 1'b1;
		end else begin
			// the shifter: an edge every BRG system clocks; with CPHA 0 the first bit is out before
			// the first edge, data is sampled on the leading (odd) edges and shifted on the trailing
			if (busy && sys_ce) begin
				if (hc == brg - 16'd1) begin
					hc <= 16'd0;
					edges <= edges - 5'd1;
					sck_r <= ~sck_r;
					if (edges[0] == 1'b0) begin                 // a leading edge (16, 14, ...)
						if (!cpha) rbr <= {rbr[6:0], miso};
						else begin mosi_r <= tsr[7]; tsr <= {tsr[6:0], 1'b1}; end
					end else begin                               // a trailing edge
						if (!cpha) begin
							if (edges != 5'd1) mosi_r <= tsr[7];
							tsr <= {tsr[6:0], 1'b1};
						end else rbr <= {rbr[6:0], miso};
						if (edges == 5'd1) sr[7] <= 1'b1;        // the last edge: done
					end
				end else
					hc <= hc + 16'd1;
			end
			if (sel && rd && addr == 3'd3) sr[7] <= 1'b0;
			if (sel && wr) begin
				case (addr)
				3'd0: brg_l <= din;
				3'd1: brg_h <= din;
				3'd2: ctl <= din;
				3'd4: if (ctl[5] && !busy) begin
					edges <= 5'd16; hc <= 16'd0; sck_r <= 1'b0;
					if (!ctl[2]) begin mosi_r <= din[7]; tsr <= {din[6:0], 1'b1}; end
					else tsr <= din;
				end
				default: ;
				endcase
			end
		end
	end
endmodule
