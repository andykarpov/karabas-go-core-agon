`timescale 1ns / 1ps
`default_nettype none
/*
 agon_link.v (karabas, Ф1.4)

 The eZ80 UART0 <-> VDP byte link between the two clock domains (agon_ez80 on clk_ez, vdp_soc on
 clk_vdp): a byte each way with a toggle handshake (the sender holds the byte and toggles req, the
 receiver takes it when the synchronised req differs from its ack and toggles ack back), ~6 clocks
 a byte: plenty for the UART rates of MOS. Levels through two flip-flops: CTS (VDP -> eZ80), vblank
 (VDP -> eZ80 PB1).
   eZ80 -> VDP: taken from the eZ80 UART (ez_tx_*) and given to the VDP (vdp_rx_*: it takes it at once)
   VDP -> eZ80: taken from the VDP (vdp_tx_*) and given to the eZ80 UART while its RX FIFO has room
*/
module agon_link (
	input wire clk_ez,
	input wire clk_vdp,
	// eZ80 side (clk_ez)
	input wire [7:0] ez_tx_data,
	input wire ez_tx_valid,
	output wire ez_tx_ready,
	output reg [7:0] ez_rx_data = 8'd0,
	output reg ez_rx_valid = 1'b0,
	input wire ez_rx_full,
	output wire ez_cts,
	output wire ez_vblank,
	// VDP side (clk_vdp)
	output reg [7:0] vdp_rx_data = 8'd0,
	output reg vdp_rx_valid = 1'b0,
	input wire vdp_cts,
	input wire [7:0] vdp_tx_data,
	input wire vdp_tx_valid,
	output wire vdp_tx_ready,
	input wire vdp_vblank
);

// ---------------------------------------------------------------- eZ80 -> VDP
reg [7:0] a_data = 8'd0;
reg a_req = 1'b0;                      // clk_ez
reg a_ack = 1'b0;                      // clk_vdp
reg [1:0] a_req_s = 2'd0;              // clk_vdp
reg [1:0] a_ack_s = 2'd0;              // clk_ez
wire a_busy = a_req != a_ack_s[1];
assign ez_tx_ready = ez_tx_valid && !a_busy;
always @(posedge clk_ez) begin
	a_ack_s <= { a_ack_s[0], a_ack };
	if (ez_tx_valid && !a_busy) begin a_data <= ez_tx_data; a_req <= ~a_req; end
end
always @(posedge clk_vdp) begin
	a_req_s <= { a_req_s[0], a_req };
	vdp_rx_valid <= 1'b0;
	if (a_req_s[1] != a_ack) begin
		vdp_rx_data <= a_data;           // (stable: a_data changed two clk_vdp before the req)
		vdp_rx_valid <= 1'b1;
		a_ack <= ~a_ack;
	end
end

// ---------------------------------------------------------------- VDP -> eZ80
reg [7:0] b_data = 8'd0;
reg b_req = 1'b0;                      // clk_vdp
reg b_ack = 1'b0;                      // clk_ez
reg [1:0] b_req_s = 2'd0;              // clk_ez
reg [1:0] b_ack_s = 2'd0;              // clk_vdp
wire b_busy = b_req != b_ack_s[1];
assign vdp_tx_ready = vdp_tx_valid && !b_busy;
always @(posedge clk_vdp) begin
	b_ack_s <= { b_ack_s[0], b_ack };
	if (vdp_tx_valid && !b_busy) begin b_data <= vdp_tx_data; b_req <= ~b_req; end
end
always @(posedge clk_ez) begin
	b_req_s <= { b_req_s[0], b_req };
	ez_rx_valid <= 1'b0;
	if (b_req_s[1] != b_ack && !ez_rx_full && !ez_rx_valid) begin
		ez_rx_data <= b_data;
		ez_rx_valid <= 1'b1;
		b_ack <= ~b_ack;
	end
end

// ---------------------------------------------------------------- levels
reg [1:0] cts_s = 2'd0, vb_s = 2'd0;
always @(posedge clk_ez) begin cts_s <= { cts_s[0], vdp_cts }; vb_s <= { vb_s[0], vdp_vblank }; end
assign ez_cts = cts_s[1];
assign ez_vblank = vb_s[1];

endmodule
