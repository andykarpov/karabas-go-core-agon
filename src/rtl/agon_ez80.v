// karabas: the Agon CPU: the eZ80 core (src/rtl/ez80, T80 widened, EZ80 = 1) with the bus of T80s
// (T2Write = 0) and the F92 periphery (src/rtl/f92). Synthesizable; the system testbench
// (src/sim/sys) instances it.
//   memory: maddr with mrd (a read cycle, mem_di taken at its T2 clocks) / mwr (a one-clock write
//   strobe, mdo); the selects of the F92 map (sel_ram / sel_flash + flash_ofs / sel_ext)
//   I/O: one-clock rd / wr strobes at the start of the I/O cycle (rd_n / wr_n are longer: the I/O
//   wait), the data bus held between strobes (T80 takes DI at every T2 clock)
module agon_ez80 (
	input             clk,
	input             reset_n,
	input             sys_ce,      // 18.432 MHz F92 system clock enable
	// memory
	output     [23:0] maddr,
	output            mrd,
	output            mwr,
	output      [7:0] mdo,
	input       [7:0] mem_di,
	output            sel_ram,
	output            sel_flash,
	output     [16:0] flash_ofs,
	output            sel_ext,
	// UART0 = the VDP link
	output      [7:0] u0_tx_data,
	output            u0_tx_valid,
	input             u0_tx_ready,
	input       [7:0] u0_rx_data,
	input             u0_rx_valid,
	output            u0_rx_full,
	input             u0_cts,
	// SD (SPI, chip select = PB4)
	output            sd_sck,
	output            sd_mosi,
	input             sd_miso,
	output            sd_cs_n,
	input             vsync,       // PB1
	// joysticks as the Console8 (fab-agon-emulator joypad.rs), active 0, idle 1:
	// PC1/3/5/7 = up / down / left / right of joystick 1, PC0/2/4/6 of joystick 2,
	// PD5/7 = fire 1 / 2 of joystick 1, PD4/6 of joystick 2
	input       [7:0] joy_pc,
	input       [3:0] joy_pd,      // PD7..PD4
	// UART1 = the ESP8266
	input             u1_rxd,
	output            u1_txd,
	output            u1_cts_n,
	// debug
	output            insn,
	output    [127:0] regx,
	output    [211:0] regs,
	output            halt_n,
	output            dbg_io_rd,
	output            dbg_io_wr,
	output      [7:0] dbg_io_d
);
	wire [15:0] a;
	wire [7:0]  au, dout;
	wire [3:0]  mcycle;
	wire [2:0]  tstate;
	wire m1_n, iorq, noread, write, intcycle_n;
	reg  mreq_n, iorq_n, rd_n, wr_n;
	reg  [7:0] di_reg;
	wire irq;
	wire [7:0] vec, f_dout;

	// the bus process of T80s (T2Write = 0)
	always @(posedge clk or negedge reset_n) begin
		if (!reset_n) begin
			rd_n <= 1'b1; wr_n <= 1'b1; iorq_n <= 1'b1; mreq_n <= 1'b1; di_reg <= 8'h00;
		end else begin
			rd_n <= 1'b1; wr_n <= 1'b1; iorq_n <= 1'b1; mreq_n <= 1'b1;
			if (mcycle == 4'b0001) begin
				if (tstate == 3'b001) begin
					rd_n <= !intcycle_n; mreq_n <= !intcycle_n; iorq_n <= intcycle_n;
				end
				if (tstate == 3'b011) mreq_n <= 1'b0;
			end else begin
				if (tstate == 3'b001 && !noread && !write) begin
					rd_n <= 1'b0; iorq_n <= !iorq; mreq_n <= iorq;
				end
				if (tstate == 3'b010 && write) begin
					wr_n <= 1'b0; iorq_n <= !iorq; mreq_n <= iorq;
				end
			end
			if (tstate == 3'b010) di_reg <= di;
		end
	end

	wire inta    = !m1_n && !iorq_n;
	wire io_rd_l = !iorq_n && !rd_n && m1_n;
	wire io_wr_l = !iorq_n && !wr_n;
	reg  io_rd_q, io_wr_q;
	always @(posedge clk) begin io_rd_q <= io_rd_l; io_wr_q <= io_wr_l; end
	wire io_rd = io_rd_l && !io_rd_q;
	wire io_wr = io_wr_l && !io_wr_q;

	assign maddr = {au, a};
	assign mrd   = !mreq_n && !rd_n;
	assign mwr   = !mreq_n && !wr_n;
	assign mdo   = dout;
	assign dbg_io_rd = io_rd;
	assign dbg_io_wr = io_wr;
	assign dbg_io_d  = io_rd ? f_dout : dout;

	reg  [7:0] di_q;
	wire [7:0] di = inta ? vec : io_rd ? f_dout : mrd ? mem_di : di_q;
	always @(posedge clk) di_q <= di;

	// (GHDL_T80: the simulation netlist of T80 from ghdl has the generics built in)
`ifdef GHDL_T80
	T80 u_cpu (
`else
	T80 #(.Mode(0), .IOWait(1), .EZ80(1)) u_cpu (
`endif
		.CEN(1'b1), .M1_n(m1_n), .IORQ(iorq), .NoRead(noread), .Write(write), .RFSH_n(),
		.HALT_n(halt_n), .WAIT_n(1'b1), .INT_n(!irq), .NMI_n(1'b1), .RESET_n(reset_n),
		.BUSRQ_n(1'b1), .BUSAK_n(), .CLK_n(clk), .A(a), .AU(au), .DInst(di), .DI(di_reg), .DO(dout),
		.MC(mcycle), .TS(tstate), .IntCycle_n(intcycle_n), .IntE(), .Stop(),
		.InsnStart(insn), .REG(regs), .REGX(regx));

	wire [7:0] pb_out, pc_out, pd_out, pb_oe, pc_oe, pd_oe;
	f92 u_f92 (.clk(clk), .reset(!reset_n), .sys_ce(sys_ce),
		.maddr(maddr), .sel_ram(sel_ram), .sel_flash(sel_flash), .flash_ofs(flash_ofs), .sel_ext(sel_ext),
		.port(a[7:0]), .io_rd(io_rd), .io_wr(io_wr), .din(dout), .dout(f_dout), .irq(irq), .vec(vec),
		.u0_tx_data(u0_tx_data), .u0_tx_valid(u0_tx_valid), .u0_tx_ready(u0_tx_ready),
		.u0_rx_data(u0_rx_data), .u0_rx_valid(u0_rx_valid), .u0_rx_full(u0_rx_full), .u0_cts(u0_cts),
		.sd_sck(sd_sck), .sd_mosi(sd_mosi), .sd_miso(sd_miso), .sd_cs_n(sd_cs_n),
		.pb_in({6'b111111, vsync, 1'b1}), .pc_in(joy_pc), .pd_in({joy_pd, 4'hf}),
		.u1_rxd(u1_rxd), .u1_txd(u1_txd), .u1_cts_n(u1_cts_n),
		.pb_out(pb_out), .pc_out(pc_out), .pd_out(pd_out), .pb_oe(pb_oe), .pc_oe(pc_oe), .pd_oe(pd_oe));
endmodule
