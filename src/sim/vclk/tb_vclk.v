`timescale 1ns / 1ps
// karabas: agon_vclk (Ф2) on the behavioural clock models of the modules (sim/hdmi/xilinx_models.v):
// mode requests 0 -> 3 -> 2 -> 0 -> 1 -> 3 -> 3 (no change) -> 0; after each: pmode, the BUFGMUX
// select, M / D programmed (the model keeps M - 1 / D - 1) into DCM_CLKGEN, no bad programming sequence; a request while the DCM never
// locks falls back to 25 MHz / pmode 0.   src/sim/vclk/run.sh
module tb_vclk;
reg clk = 1'b0, clk25 = 1'b0;
always #6.667 clk = ~clk;
always #20 clk25 = ~clk25;
reg reset = 1'b1;
reg [1:0] omode = 2'd0;
wire [1:0] pmode;
wire clk_pix, clk_hdmi, clk_hdmi_n, locked;
agon_vclk #(.HDMI(1)) dut (.clk_sys(clk), .reset(reset), .clk_25(clk25), .omode(omode), .pmode(pmode),
	.clk_pix(clk_pix), .clk_hdmi(clk_hdmi), .clk_hdmi_n(clk_hdmi_n), .locked(locked));
integer errors = 0;
task automatic ask(input [1:0] m, input [1:0] want_p, input want_sel, input integer want_m);
	begin
		omode = m;
		repeat (4000) @(posedge clk);
		if (pmode !== want_p || dut.sel !== want_sel) begin
			errors = errors + 1; $display("FAIL ask %0d: pmode %0d sel %0d (want %0d %0d)", m, pmode, dut.sel, want_p, want_sel);
		end
		if (want_m != 0 && (dut.gen.m_val != want_m - 1 || dut.gen.d_val != 14)) begin
			errors = errors + 1; $display("FAIL ask %0d: M/D %0d/%0d", m, dut.gen.m_val, dut.gen.d_val);
		end
	end
endtask
initial begin
	repeat (10) @(posedge clk); reset = 1'b0;
	ask(2'd0, 2'd0, 1'b0, 0);
	ask(2'd3, 2'd3, 1'b1, 13);
	ask(2'd2, 2'd2, 1'b1, 8);
	ask(2'd0, 2'd0, 1'b0, 0);
	ask(2'd1, 2'd1, 1'b0, 0);
	ask(2'd3, 2'd3, 1'b1, 13);
	ask(2'd3, 2'd3, 1'b1, 13);
	ask(2'd0, 2'd0, 1'b0, 0);
	if (dut.gen.bad_seq != 0) begin errors = errors + 1; $display("FAIL bad programming sequences %0d", dut.gen.bad_seq); end
	if (dut.gen.programs != 3) begin errors = errors + 1; $display("FAIL programs %0d (want 3)", dut.gen.programs); end
	// no lock: force LOCKED low, ask 2: stays at 25 MHz after the timeout
	force dut.gen.LOCKED = 1'b0;
	omode = 2'd2;
	repeat (1100000) @(posedge clk);
	if (pmode !== 2'd0 || dut.sel !== 1'b0) begin errors = errors + 1; $display("FAIL no lock: pmode %0d sel %0d", pmode, dut.sel); end
	release dut.gen.LOCKED;
	$display("tb_vclk: %0d errors", errors);
	$finish;
end
endmodule
