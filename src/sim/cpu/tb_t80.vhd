-- Ф1.1 testbench top for the CPU (simulation only): the T80 core of src/rtl/ez80 with the bus of
-- T80s (MREQ / IORQ / RD / WR, DI latched at T2 with WAIT high), InsnStart and REG brought out.
-- Built by ghdl --synth into Verilog for Verilator (src/sim/cpu/run.sh, tb_cpu.cpp drives it).
-- REG (LSB first): A, F, A', F', I, R, SP, PC, BC, DE, HL, IX, BC', DE', HL', IY, IM(2), IFF1, IFF2.
library IEEE;
use IEEE.std_logic_1164.all;
use work.T80_Pack.all;

entity tb_t80 is
	port(
		clk     : in  std_logic;
		reset_n : in  std_logic;
		int_n   : in  std_logic;
		nmi_n   : in  std_logic;
		di      : in  std_logic_vector(7 downto 0);
		a       : out std_logic_vector(15 downto 0);
		dout    : out std_logic_vector(7 downto 0);
		m1_n    : out std_logic;
		mreq_n  : out std_logic;
		iorq_n  : out std_logic;
		rd_n    : out std_logic;
		wr_n    : out std_logic;
		halt_n  : out std_logic;
		insn    : out std_logic;
		regs    : out std_logic_vector(211 downto 0)
	);
end tb_t80;

architecture rtl of tb_t80 is
	signal IntCycle_n : std_logic;
	signal NoRead     : std_logic;
	signal Write      : std_logic;
	signal IORQ       : std_logic;
	signal DI_Reg     : std_logic_vector(7 downto 0);
	signal MCycle     : std_logic_vector(2 downto 0);
	signal TState     : std_logic_vector(2 downto 0);
begin
	u0 : T80
		generic map(Mode => 0, IOWait => 1)
		port map(
			CEN => '1', M1_n => m1_n, IORQ => IORQ, NoRead => NoRead, Write => Write, RFSH_n => open,
			HALT_n => halt_n, WAIT_n => '1', INT_n => int_n, NMI_n => nmi_n, RESET_n => reset_n,
			BUSRQ_n => '1', BUSAK_n => open, CLK_n => clk, A => a, DInst => di, DI => DI_Reg, DO => dout,
			MC => MCycle, TS => TState, IntCycle_n => IntCycle_n, IntE => open, Stop => open,
			InsnStart => insn, REG => regs);

	-- the bus process of T80s (T2Write = 0)
	process (reset_n, clk)
	begin
		if reset_n = '0' then
			rd_n <= '1'; wr_n <= '1'; iorq_n <= '1'; mreq_n <= '1';
			DI_Reg <= "00000000";
		elsif rising_edge(clk) then
			rd_n <= '1'; wr_n <= '1'; iorq_n <= '1'; mreq_n <= '1';
			if MCycle = "001" then
				if TState = "001" then
					rd_n <= not IntCycle_n;
					mreq_n <= not IntCycle_n;
					iorq_n <= IntCycle_n;
				end if;
				if TState = "011" then
					mreq_n <= '0';
				end if;
			else
				if TState = "001" and NoRead = '0' and Write = '0' then
					rd_n <= '0';
					iorq_n <= not IORQ;
					mreq_n <= IORQ;
				end if;
				if TState = "010" and Write = '1' then
					wr_n <= '0';
					iorq_n <= not IORQ;
					mreq_n <= IORQ;
				end if;
			end if;
			if TState = "010" then
				DI_Reg <= di;
			end if;
		end if;
	end process;
end;
