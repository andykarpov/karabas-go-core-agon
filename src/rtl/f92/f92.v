// karabas: the eZ80F92 on-chip periphery of the Agon around the eZ80 core: the memory map, PRT0..5,
// GPIO B / C / D, SPI, UART0 (the VDP link), UART1, an I2C stub (as the emulator: CTL read / write,
// SR reads 00), the interrupt priority. Other ports read 00 (as the emulator).
// The I/O bus: port (the low byte selects, as the F92 internal registers), a one-clock rd strobe at
// the end of the read (dout must be valid with it) and a one-clock wr strobe.
module f92 (
	input             clk,
	input             reset,
	input             sys_ce,      // 18.432 MHz system clock enable (PRT, SPI)
	// memory decode
	input      [23:0] maddr,
	output            sel_ram,
	output            sel_flash,
	output     [16:0] flash_ofs,
	output            sel_ext,
	// I/O
	input       [7:0] port,
	input             io_rd,
	input             io_wr,
	input       [7:0] din,
	output reg  [7:0] dout,
	// interrupts
	output            irq,
	output      [7:0] vec,
	// UART0 = the VDP link
	output      [7:0] u0_tx_data,
	output            u0_tx_valid,
	input             u0_tx_ready,
	input       [7:0] u0_rx_data,
	input             u0_rx_valid,
	output            u0_rx_full,
	input             u0_cts,
	// SPI and the SD chip select (PB4)
	output            sd_sck,
	output            sd_mosi,
	input             sd_miso,
	output            sd_cs_n,
	// GPIO pins
	input       [7:0] pb_in,       // PB1 = vsync from the VDP
	input       [7:0] pc_in,
	input       [7:0] pd_in,
	output      [7:0] pb_out, pc_out, pd_out,
	output      [7:0] pb_oe, pc_oe, pd_oe
);
	wire s_prt  = port >= 8'h80 && port <= 8'h91;
	wire s_gb   = port >= 8'h9a && port <= 8'h9d;
	wire s_gc   = port >= 8'h9e && port <= 8'ha1;
	wire s_gd   = port >= 8'ha2 && port <= 8'ha5;
	wire s_spi  = port >= 8'hb8 && port <= 8'hbc;
	wire s_u0   = port >= 8'hc0 && port <= 8'hc7;
	wire s_i2c  = port >= 8'hc8 && port <= 8'hcd;
	wire s_u1   = port >= 8'hd0 && port <= 8'hd7;

	wire [7:0] d_prt, d_gb, d_gc, d_gd, d_spi, d_u0, d_u1, d_mem;
	wire [5:0] i_prt;
	wire [7:0] i_gb, i_gc, i_gd;
	wire i_u0, i_u1, m_mem;
	wire [7:0] gb_out;

	f92_mem u_mem (.clk(clk), .reset(reset), .a(maddr), .sel_ram(sel_ram), .sel_flash(sel_flash),
		.fofs(flash_ofs), .sel_ext(sel_ext), .psel(1'b1), .paddr(port), .wr(io_wr), .din(din),
		.dout(d_mem), .pmine(m_mem));
	// PRT0 / PRT2 count (MOS: delays, the system timer); PRT1 / 3 / 4 / 5 registers only, no count or
	// interrupt (user 2026-11-18: ~300 LUT for the Mini G fit)
	f92_prt #(.FULL_MASK(6'b000101)) u_prt (.clk(clk), .reset(reset), .sys_ce(sys_ce), .sel(s_prt), .addr(port[4:0] - 5'h00),
		.rd(io_rd), .wr(io_wr), .din(din), .dout(d_prt), .irq(i_prt));
	f92_gpio u_gb (.clk(clk), .reset(reset), .sel(s_gb), .addr(port[1:0] - 2'd2), .wr(io_wr), .din(din),
		.dout(d_gb), .pin_in(pb_in), .pin_out(gb_out), .pin_oe(pb_oe), .irq(i_gb));
	f92_gpio u_gc (.clk(clk), .reset(reset), .sel(s_gc), .addr(port[1:0] - 2'd2), .wr(io_wr), .din(din),
		.dout(d_gc), .pin_in(pc_in), .pin_out(pc_out), .pin_oe(pc_oe), .irq(i_gc));
	f92_gpio u_gd (.clk(clk), .reset(reset), .sel(s_gd), .addr(port[1:0] - 2'd2), .wr(io_wr), .din(din),
		.dout(d_gd), .pin_in(pd_in), .pin_out(pd_out), .pin_oe(pd_oe), .irq(i_gd));
	f92_spi u_spi (.clk(clk), .reset(reset), .sys_ce(sys_ce), .sel(s_spi), .addr(port[2:0]),
		.rd(io_rd), .wr(io_wr), .din(din), .dout(d_spi), .sck(sd_sck), .mosi(sd_mosi), .miso(sd_miso), .busy());
	f92_uart u_u0 (.clk(clk), .reset(reset), .sel(s_u0), .addr(port[2:0]), .rd(io_rd), .wr(io_wr),
		.din(din), .dout(d_u0), .irq(i_u0), .tx_data(u0_tx_data), .tx_valid(u0_tx_valid),
		.tx_ready(u0_tx_ready), .rx_data(u0_rx_data), .rx_valid(u0_rx_valid), .rx_full(u0_rx_full), .cts(u0_cts));
	f92_uart u_u1 (.clk(clk), .reset(reset), .sel(s_u1), .addr(port[2:0]), .rd(io_rd), .wr(io_wr),
		.din(din), .dout(d_u1), .irq(i_u1), .tx_data(), .tx_valid(), .tx_ready(1'b1),
		.rx_data(8'h00), .rx_valid(1'b0), .rx_full(), .cts(1'b1));

	// I2C: CTL (CBh) only
	reg [7:0] i2c_ctl;
	always @(posedge clk)
		if (reset) i2c_ctl <= 8'h00;
		else if (io_wr && port == 8'hcb) i2c_ctl <= din;
	wire i_i2c = i2c_ctl[7] & i2c_ctl[2];

	assign pb_out  = gb_out;
	assign sd_cs_n = (pb_oe[4] ? gb_out[4] : 1'b1);

	f92_intc u_intc (.prt(i_prt), .uart0(i_u0), .uart1(i_u1), .i2c(i_i2c), .gpb(i_gb), .gpc(i_gc),
		.gpd(i_gd), .irq(irq), .vec(vec));

	always @* begin
		if (s_prt)               dout = d_prt;
		else if (s_gb)           dout = d_gb;
		else if (s_gc)           dout = d_gc;
		else if (s_gd)           dout = d_gd;
		else if (s_spi)          dout = d_spi;
		else if (s_u0)           dout = d_u0;
		else if (s_u1)           dout = d_u1;
		else if (port == 8'hcb)  dout = i2c_ctl;
		else if (m_mem)          dout = d_mem;
		else                     dout = 8'h00;
	end
endmodule
