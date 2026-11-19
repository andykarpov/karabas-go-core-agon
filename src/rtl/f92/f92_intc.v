// karabas: eZ80F92 interrupt priority (as the Agon oracle kg_do_interrupts / the emulator):
// PRT0..5 (vectors 0Ah + 2n), UART0 (18h), UART1 (1Ah), I2C (1Ch), then GPIO B, C, D pins
// (30h / 40h / 50h + 2n, the lowest pin first). irq = any; vec = the highest priority one, for
// the data bus of the interrupt acknowledge cycle.
module f92_intc (
	input      [5:0] prt,
	input            uart0,
	input            uart1,
	input            i2c,
	input      [7:0] gpb,
	input      [7:0] gpc,
	input      [7:0] gpd,
	output           irq,
	output reg [7:0] vec
);
	assign irq = |{prt, uart0, uart1, i2c, gpb, gpc, gpd};

	function [3:0] low;              // the index of the lowest set bit (8 = none)
		input [7:0] v;
		integer i;
		begin
			low = 4'd8;
			for (i = 7; i >= 0; i = i - 1) if (v[i]) low = i[3:0];
		end
	endfunction

	wire [3:0] lp = low({2'b00, prt});
	wire [3:0] lb = low(gpb), lc = low(gpc), ld = low(gpd);
	always @* begin
		if (lp != 4'd8)      vec = 8'h0a + {3'd0, lp, 1'b0};
		else if (uart0)      vec = 8'h18;
		else if (uart1)      vec = 8'h1a;
		else if (i2c)        vec = 8'h1c;
		else if (lb != 4'd8) vec = 8'h30 + {3'd0, lb, 1'b0};
		else if (lc != 4'd8) vec = 8'h40 + {3'd0, lc, 1'b0};
		else if (ld != 4'd8) vec = 8'h50 + {3'd0, ld, 1'b0};
		else                 vec = 8'h00;
	end
endmodule
