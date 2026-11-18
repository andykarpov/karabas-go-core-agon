// karabas: Ф1.3 system testbench top: the eZ80 core (tb_t80 of src/sim/cpu, from ghdl, EZ80 = 1)
// with the F92 periphery in RTL (src/rtl/f92). The memories, the SD card and the VDP are C++
// (sys_tb.cpp): the memory selects come from f92_mem (the map in RTL).
module sys_top (
	input             clk,
	input             reset_n,
	input             sys_ce,
	// memory (C++)
	output     [23:0] maddr,
	output            mrd,         // a memory read cycle (mem_di is taken)
	output            mwr,         // one-clock write strobe
	output      [7:0] mdo,
	input       [7:0] mem_di,
	output            sel_ram,
	output            sel_flash,
	output     [16:0] flash_ofs,
	output            sel_ext,
	// UART0 = the VDP (C++)
	output      [7:0] u0_tx_data,
	output            u0_tx_valid,
	input             u0_tx_ready,
	input       [7:0] u0_rx_data,
	input             u0_rx_valid,
	output            u0_rx_full,
	input             u0_cts,
	// SD
	output            sd_sck,
	output            sd_mosi,
	input             sd_miso,
	output            sd_cs_n,
	input             vsync,       // PB1
	// debug
	output            insn,
	output     [127:0] regx,
	output     [211:0] regs,
	output            halt_n,
	output            dbg_io_rd,
	output            dbg_io_wr,
	output      [7:0] dbg_io_d
);
	wire [15:0] a;
	wire [7:0]  au, dout;
	wire m1_n, mreq_n, iorq_n, rd_n, wr_n;
	wire irq;
	wire [7:0] vec, f_dout;

	wire inta  = !m1_n && !iorq_n;
	// rd_n / wr_n of an I/O cycle are low for more than one clock (the I/O wait): one-clock strobes
	// at the start, for the side effects (FIFO pops, flags cleared by a read)
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

	// the data bus holds its last value between the strobes (as the CPU testbench): T80 takes DI at
	// every T2 clock, also in the wait state after the one-clock rd / iorq strobe
	reg  [7:0] di_q;
	wire [7:0] di = inta ? vec : io_rd ? f_dout : mrd ? mem_di : di_q;
	always @(posedge clk) di_q <= di;

	tb_t80 u_cpu (.clk(clk), .reset_n(reset_n), .int_n(!irq), .nmi_n(1'b1), .di(di), .a(a), .au(au),
		.dout(dout), .m1_n(m1_n), .mreq_n(mreq_n), .iorq_n(iorq_n), .rd_n(rd_n), .wr_n(wr_n),
		.halt_n(halt_n), .insn(insn), .regs(regs), .regx(regx), .mcyc(), .tst());

	wire [7:0] pb_out, pc_out, pd_out, pb_oe, pc_oe, pd_oe;
	f92 u_f92 (.clk(clk), .reset(!reset_n), .sys_ce(sys_ce),
		.maddr(maddr), .sel_ram(sel_ram), .sel_flash(sel_flash), .flash_ofs(flash_ofs), .sel_ext(sel_ext),
		.port(a[7:0]), .io_rd(io_rd), .io_wr(io_wr), .din(dout), .dout(f_dout), .irq(irq), .vec(vec),
		.u0_tx_data(u0_tx_data), .u0_tx_valid(u0_tx_valid), .u0_tx_ready(u0_tx_ready),
		.u0_rx_data(u0_rx_data), .u0_rx_valid(u0_rx_valid), .u0_rx_full(u0_rx_full), .u0_cts(u0_cts),
		.sd_sck(sd_sck), .sd_mosi(sd_mosi), .sd_miso(sd_miso), .sd_cs_n(sd_cs_n),
		.pb_in({6'b111111, vsync, 1'b1}), .pc_in(8'hff), .pd_in(8'hff),
		.pb_out(pb_out), .pc_out(pc_out), .pd_out(pd_out), .pb_oe(pb_oe), .pc_oe(pc_oe), .pd_oe(pd_oe));
endmodule
