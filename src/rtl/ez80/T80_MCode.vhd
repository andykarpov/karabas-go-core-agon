--------------------------------------------------------------------------------
-- ****
-- T80(c) core. Attempt to finish all undocumented features and provide
--              accurate timings.
-- Version 350.
-- Copyright (c) 2018 Sorgelig
--  Test passed: ZEXDOC, ZEXALL, Z80Full(*), Z80memptr
--  (*) Currently only SCF and CCF instructions aren't passed X/Y flags check as
--      correct implementation is still unclear.
--
-- ****
-- T80(b) core. In an effort to merge and maintain bug fixes ....
--
-- Ver 303 add undocumented DDCB and FDCB opcodes by TobiFlex 20.04.2010
-- Ver 300 started tidyup
-- MikeJ March 2005
-- Latest version from www.fpgaarcade.com (original www.opencores.org)
--
-- ****
-- Z80 compatible microprocessor core
--
-- Version : 0250
-- Copyright (c) 2001-2002 Daniel Wallner (jesus@opencores.org)
-- All rights reserved
--
-- Redistribution and use in source and synthezised forms, with or without
-- modification, are permitted provided that the following conditions are met:
--
-- Redistributions of source code must retain the above copyright notice,
-- this list of conditions and the following disclaimer.
--
-- Redistributions in synthesized form must reproduce the above copyright
-- notice, this list of conditions and the following disclaimer in the
-- documentation and/or other materials provided with the distribution.
--
-- Neither the name of the author nor the names of other contributors may
-- be used to endorse or promote products derived from this software without
-- specific prior written permission.
--
-- THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
-- AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
-- THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
-- PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE
-- LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
-- CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
-- SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
-- INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
-- CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
-- ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
-- POSSIBILITY OF SUCH DAMAGE.
--
-- Please report bugs to the author, but before you do so, please
-- make sure that this is not a derivative work and that
-- you have the latest version of this file.
--
-- The latest version of this file can be found at:
--      http://www.opencores.org/cvsweb.shtml/t80/
--
-- Limitations :
--
-- File history :
--
--      0208 : First complete release
--      0211 : Fixed IM 1
--      0214 : Fixed mostly flags, only the block instructions now fail the zex regression test
--      0235 : Added IM 2 fix by Mike Johnson
--      0238 : Added NoRead signal
--      0238b: Fixed instruction timing for POP and DJNZ
--      0240 : Added (IX/IY+d) states, removed op-codes from mode 2 and added all remaining mode 3 op-codes
--      0240mj1 fix for HL inc/dec for INI, IND, INIR, INDR, OUTI, OUTD, OTIR, OTDR
--      0242 : Fixed I/O instruction timing, cleanup
--      0250 : Added R800 Multiplier by TobiFlex 2017.10.15
--

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.T80_Pack.all;

entity T80_MCode is
	generic(
		Mode   : integer := 0;
		Flag_C : integer := 0;
		Flag_N : integer := 1;
		Flag_P : integer := 2;
		Flag_X : integer := 3;
		Flag_H : integer := 4;
		Flag_Y : integer := 5;
		Flag_Z : integer := 6;
		Flag_S : integer := 7;
		EZ80   : integer := 0  -- karabas
	);
	port(
      IR          : in std_logic_vector(7 downto 0);
      -- karabas: eZ80 inputs / outputs
      Lm          : in std_logic := '0';   -- data long of the instruction
      ILm         : in std_logic := '0';   -- immediate long of the instruction
      ADLm        : in std_logic := '0';
      Suffix      : out std_logic;         -- IR is a .SIS / .LIS / .SIL / .LIL suffix
      EzOp        : out std_logic_vector(3 downto 0); -- eZ80 register operations (see below)
      IOA0        : out std_logic;         -- with aIOA: port high byte 00 (IN0 / OUT0)
      UOp         : out std_logic_vector(1 downto 0); -- with Read_To_Reg: 01 the byte goes to the
                                           -- upper byte of the pair / SPL, 10 also clear the upper byte
      BusBU       : out std_logic;         -- BusB = the upper byte of the Set_BusB_To pair / SP / PC
      LDU         : out std_logic;         -- WZ(23:16) <= DI at T3 (the third byte of a 24-bit nn)
      -- register selections forced by eZ80 instructions: bit 3 = force, bits 1..0 = pair BC / DE /
      -- HL (with EXX), "11" = IX (bit 2 = 0) or IY (bit 2 = 1)
      EzRA        : out std_logic_vector(3 downto 0);  -- write / BusA pair
      EzRB        : out std_logic_vector(3 downto 0);  -- BusB pair
      EzRC        : out std_logic_vector(3 downto 0);  -- address / base pair
      AddrWZ      : out std_logic;         -- with aXY / aBC / aDE: the address also to WZ (24 bits)
      WZAdd       : out std_logic;         -- at T3: WZ <= base (EzRC) + d (DI), 24 bits
      WZToReg     : out std_logic;         -- at T3: the EzRA pair <= WZ (24 bits with L)
      EzBusB      : out std_logic_vector(1 downto 0);  -- BusB = WZ byte: 01 low, 10 high, 11 upper
      MADLm       : in  std_logic := '0';
      BusBMode    : out std_logic;         -- BusB = the mode byte (MADL << 1 | ADL) of an interrupt
      IntVec      : out std_logic;         -- at T_Res: A / PC <= 00:I:WZ(7:0) (the vector table)
      JumpV       : out std_logic;         -- at T_Res: jump to 00:DI:WZ(7:0), ADL <= ADL or MADL
      Sfxm        : in  std_logic := '0';  -- the instruction had a suffix
      ModeBm      : in  std_logic := '0';  -- bit 0 of the popped mode byte
      StkSelA     : out std_logic_vector(1 downto 0);  -- aSP stack: 00 by L, 01 SPL, 10 by ADL
      StkSelI     : out std_logic_vector(1 downto 0);  -- SP inc / dec stack: the same codes
      LDMode      : out std_logic;         -- at T3: ModeB <= DI(0)
      JumpM       : out std_logic;         -- at T_Res: the mixed-mode return jump (see T80.vhd)
      ISet        : in std_logic_vector(1 downto 0);
      MCycle      : in std_logic_vector(3 downto 0);
      F           : in std_logic_vector(7 downto 0);
      NMICycle    : in std_logic;
      IntCycle    : in std_logic;
      XY_State    : in std_logic_vector(1 downto 0);
      MCycles     : out std_logic_vector(3 downto 0);
      TStates     : out std_logic_vector(2 downto 0);
      Prefix      : out std_logic_vector(1 downto 0); -- None,CB,ED,DD/FD
      Inc_PC      : out std_logic;
      Inc_WZ      : out std_logic;
      IncDec_16   : out std_logic_vector(3 downto 0); -- BC,DE,HL,SP   0 is inc
      Read_To_Reg : out std_logic;
      Read_To_Acc : out std_logic;
      Set_BusA_To : out std_logic_vector(3 downto 0); -- B,C,D,E,H,L,DI/DB,A,SP(L),SP(M),0,F
      Set_BusB_To : out std_logic_vector(3 downto 0); -- B,C,D,E,H,L,DI,A,SP(L),SP(M),1,F,PC(L),PC(M),0
      ALU_Op      : out std_logic_vector(3 downto 0);
         -- ADD, ADC, SUB, SBC, AND, XOR, OR, CP, ROT, BIT, SET, RES, DAA, RLD, RRD, None
      Save_ALU    : out std_logic;
      Rot_Akku    : out std_logic;
      PreserveC   : out std_logic;
      Arith16     : out std_logic;
      Set_Addr_To : out std_logic_vector(2 downto 0); -- aNone,aXY,aIOA,aSP,aBC,aDE,aZI
      IORQ        : out std_logic;
      Jump        : out std_logic;
      JumpE       : out std_logic;
      JumpXY      : out std_logic;
      Call        : out std_logic;
      RstP        : out std_logic;
      LDZ         : out std_logic;
      LDW         : out std_logic;
      LDSPHL      : out std_logic;
      LDHLSP      : out std_logic;
      ADDSPdd     : out std_logic;
      Special_LD  : out std_logic_vector(2 downto 0); -- A,I;A,R;I,A;R,A;None
      ExchangeDH  : out std_logic;
      ExchangeRp  : out std_logic;
      ExchangeAF  : out std_logic;
      ExchangeRS  : out std_logic;
      ExchangeWH  : out std_logic;
      I_DJNZ      : out std_logic;
      I_CPL       : out std_logic;
      I_CCF       : out std_logic;
      I_SCF       : out std_logic;
      I_RETN      : out std_logic;
      I_BT        : out std_logic;
      I_BC        : out std_logic;
      I_BTR       : out std_logic;
      I_RLD       : out std_logic;
      I_RRD       : out std_logic;
      I_INRC      : out std_logic;
      I_MULUB     : out std_logic;
      I_MULU      : out std_logic;
      SetWZ       : out std_logic_vector(1 downto 0);
      SetDI       : out std_logic;
      SetEI       : out std_logic;
      IMode       : out std_logic_vector(1 downto 0);
      Halt        : out std_logic;
      NoRead      : out std_logic;
      Write       : out std_logic;
      R800_mode   : in  std_logic;
      No_PC       : out std_logic;
      XYbit_undoc : out std_logic
   );
end T80_MCode;

architecture rtl of T80_MCode is

	function is_cc_true(
		F : std_logic_vector(7 downto 0);
		cc : bit_vector(2 downto 0)
		) return boolean is
	begin
		if Mode = 3 then
			case cc is
			when "000" => return F(Flag_Z) = '0'; -- NZ
			when "001" => return F(Flag_Z) = '1'; -- Z
			when "010" => return F(Flag_C) = '0'; -- NC
			when "011" => return F(Flag_C) = '1'; -- C
			when "100" => return false;
			when "101" => return false;
			when "110" => return false;
			when "111" => return false;
			end case;
		else
			case cc is
			when "000" => return F(Flag_Z) = '0'; -- NZ
			when "001" => return F(Flag_Z) = '1'; -- Z
			when "010" => return F(Flag_C) = '0'; -- NC
			when "011" => return F(Flag_C) = '1'; -- C
			when "100" => return F(Flag_P) = '0'; -- PO
			when "101" => return F(Flag_P) = '1'; -- PE
			when "110" => return F(Flag_S) = '0'; -- P
			when "111" => return F(Flag_S) = '1'; -- M
			end case;
		end if;
	end;

begin

	process (IR, ISet, MCycle, F, NMICycle, IntCycle, XY_State, R800_mode, Lm, ILm, ADLm, MADLm, Sfxm, ModeBm)
		variable DDD   : std_logic_vector(2 downto 0);
		variable SSS   : std_logic_vector(2 downto 0);
		variable DPair : std_logic_vector(1 downto 0);
		variable IRB   : bit_vector(7 downto 0);
		-- karabas: eZ80 helpers
		variable mc    : integer;   -- MCycle
		variable o     : integer;   -- 1 with a 24-bit immediate (IL)
		variable lw    : integer;   -- 1 with 3-byte data (L)
		variable dc    : integer;   -- the data cycle after the address: 0, 1, 2
		variable np    : integer;   -- interrupt: the bytes to push
		variable k2    : integer;
		variable adlv  : integer;   -- 1 in ADL mode
		variable done  : boolean;   -- a DD / FD eZ80 instruction took the cycle
		-- clear the per-cycle outputs the Z80 code of an opcode set, before an eZ80 sequence
		procedure ez_clear is
		begin
			Inc_PC <= '0'; LDZ <= '0'; LDW <= '0'; Inc_WZ <= '0'; Set_Addr_To <= aNone;
			Read_To_Reg <= '0'; Read_To_Acc <= '0'; Write <= '0'; Jump <= '0'; NoRead <= '0';
			Set_BusA_To <= "0000"; Set_BusB_To <= "0000"; SetWZ <= "00"; UOp <= "00"; BusBU <= '0';
			IncDec_16 <= "0000"; Call <= '0'; RstP <= '0'; LDU <= '0'; No_PC <= '0';
			-- and every operation of the Z80 aliases at eZ80 codes (NEG, RETN, IM n...)
			Save_ALU <= '0'; Rot_Akku <= '0'; PreserveC <= '0'; Arith16 <= '0'; IORQ <= '0';
			JumpE <= '0'; JumpXY <= '0'; LDSPHL <= '0'; Special_LD <= "000";
			ExchangeDH <= '0'; ExchangeRp <= '0'; ExchangeAF <= '0'; ExchangeRS <= '0'; ExchangeWH <= '0';
			I_DJNZ <= '0'; I_CPL <= '0'; I_CCF <= '0'; I_SCF <= '0'; I_RETN <= '0';
			I_BT <= '0'; I_BC <= '0'; I_BTR <= '0'; I_RLD <= '0'; I_RRD <= '0'; I_INRC <= '0';
			SetDI <= '0'; SetEI <= '0'; IMode <= "11"; Halt <= '0'; ALU_Op <= "0000";
			if MCycle = "0001" then TStates <= "100"; else TStates <= "011"; end if;
		end procedure;
		-- in the d fetch cycles (M14, M15) of a DD / FD eZ80 instruction: off with the operations
		-- of the Z80 opcode at the same code (RLCA at 07...), the fetch signals stay
		procedure ez_clear_ops is
		begin
			Save_ALU <= '0'; Rot_Akku <= '0'; ALU_Op <= "0000"; Read_To_Reg <= '0'; Read_To_Acc <= '0';
			Arith16 <= '0'; Write <= '0'; Jump <= '0'; JumpE <= '0'; JumpXY <= '0'; Call <= '0';
			RstP <= '0'; LDZ <= '0'; LDW <= '0'; IncDec_16 <= "0000"; ExchangeDH <= '0'; ExchangeWH <= '0';
			ExchangeAF <= '0'; ExchangeRS <= '0'; I_DJNZ <= '0'; I_CPL <= '0'; I_CCF <= '0'; I_SCF <= '0';
			Special_LD <= "000"; LDSPHL <= '0'; Halt <= '0'; SetDI <= '0'; SetEI <= '0';
		end procedure;
		-- the nn of (nn): 2 bytes, 3 with IL; the address is formed in the last one (cycle 3 + o)
		procedure ez_nn is
		begin
			if mc = 2 then
				Inc_PC <= '1'; LDZ <= '1';
			elsif mc = 3 then
				Inc_PC <= '1'; LDW <= '1';
				if o = 0 then Set_Addr_To <= aZI; end if;
			elsif mc = 4 and o = 1 then
				Inc_PC <= '1'; Set_Addr_To <= aZI;
			end if;
		end procedure;
		-- a word at (nn) or (rr) into the pair pr (SP if sp): low, high, upper with L (dc = 0, 1, 2)
		procedure ez_read_word(pr_in : std_logic_vector(1 downto 0); sp : boolean) is
			variable pr : std_logic_vector(1 downto 0);
		begin
			-- "11" (IX / IY, selected by EzRA) as a pair code: 011x would be A / DI
			if pr_in = "11" then pr := "10"; else pr := pr_in; end if;
			if dc >= 0 and dc <= 2 then
				Read_To_Reg <= '1';
				if sp then
					if dc = 1 then Set_BusA_To <= "1001"; else Set_BusA_To <= "1000"; end if;
				else
					Set_BusA_To(3) <= '0';
					Set_BusA_To(2 downto 1) <= pr;
					if dc = 1 then Set_BusA_To(0) <= '0'; else Set_BusA_To(0) <= '1'; end if;
				end if;
				if dc = 2 then UOp <= "01"; end if;
				if dc = 0 or (dc = 1 and lw = 1) then
					Inc_WZ <= '1'; Set_Addr_To <= aZI;
				end if;
			end if;
		end procedure;
		-- the bytes to write for a word: BusB in the cycle before each write (low in the address
		-- cycle, dc = -1), the writes in dc = 0, 1, 2
		procedure ez_write_word(pr_in : std_logic_vector(1 downto 0); sp : boolean) is
			variable pr : std_logic_vector(1 downto 0);
		begin
			if pr_in = "11" then pr := "10"; else pr := pr_in; end if;  -- IX / IY by EzRB
			if dc >= 0 and dc <= 1 + lw then
				Write <= '1';
			end if;
			if dc >= -1 and dc <= lw then
				if sp then
					if dc = 0 then Set_BusB_To <= "1001"; else Set_BusB_To <= "1000"; end if;
				else
					Set_BusB_To(3) <= '0';
					Set_BusB_To(2 downto 1) <= pr;
					if dc = 0 then Set_BusB_To(0) <= '0'; else Set_BusB_To(0) <= '1'; end if;
				end if;
				if dc = 1 then BusBU <= '1'; end if;
			end if;
			if dc = 0 or (dc = 1 and lw = 1) then
				Inc_WZ <= '1'; Set_Addr_To <= aZI;
			end if;
		end procedure;
		-- an upper-byte ALU cycle of a 24-bit ADD / ADC / SBC HL,ss (after the Z80 high-byte cycle):
		-- UOp 01 = both buses take the upper bytes, the result goes to the upper byte, H is kept
		procedure ez_alu_upper(op : std_logic_vector(3 downto 0); arith : std_logic) is
		begin
			NoRead <= '1';
			Read_To_Reg <= '1';
			Save_ALU <= '1';
			ALU_Op <= op;
			Arith16 <= arith;
			Set_BusA_To <= "0100";
			case to_integer(unsigned(IR(5 downto 4))) is
			when 0|1|2 =>
				Set_BusB_To(3) <= '0';
				Set_BusB_To(2 downto 1) <= IR(5 downto 4);
				Set_BusB_To(0) <= '0';
			when others =>
				Set_BusB_To <= "1001";
			end case;
			UOp <= "01";
		end procedure;
		-- push the return address (PC) from cycle p0: U (with L), H, L; the last write does Call / RstP
		procedure ez_push_pc(p0 : integer; rst : boolean) is
			variable nb : integer;
			variable k  : integer;
		begin
			nb := 2 + lw;
			k := mc - p0;   -- 0 = the cycle that sets up the first byte
			if k >= 0 and k < nb then
				IncDec_16 <= "1111";
				Set_Addr_To <= aSP;
				if k = nb - 1 then Set_BusB_To <= "1100"; else Set_BusB_To <= "1101"; end if;
				if lw = 1 and k = 0 then BusBU <= '1'; end if;
			end if;
			if k >= 1 and k <= nb then Write <= '1'; end if;
			if k = nb then
				if rst then RstP <= '1'; else Call <= '1'; end if;
			end if;
		end procedure;

		-- RET / RET cc / RETI / RETN after a suffix (CEmu cpu_return): the mode byte from SPL, PC low /
		-- high from the stack of ADL, the upper byte from SPL if the mode byte says ADL; ADL <= mode
		procedure ez_pop_mixed is
		begin
			MCycles <= "0101";
			if mc = 1 then StkSelA <= "01"; Set_Addr_To <= aSP; end if;
			if mc = 2 then
				StkSelI <= "01"; IncDec_16 <= "0111"; LDMode <= '1';
				StkSelA <= "10"; Set_Addr_To <= aSP;
			end if;
			if mc = 3 then
				LDZ <= '1'; StkSelI <= "10"; IncDec_16 <= "0111";
				StkSelA <= "10"; Set_Addr_To <= aSP;
			end if;
			if mc = 4 then
				LDW <= '1'; StkSelI <= "10"; IncDec_16 <= "0111";
				if ModeBm = '1' then
					StkSelA <= "01"; Set_Addr_To <= aSP;
				else
					MCycles <= "0100"; JumpM <= '1';
				end if;
			end if;
			if mc = 5 then
				StkSelI <= "01"; IncDec_16 <= "0111"; JumpM <= '1';
			end if;
		end procedure;
		-- pop the return address from cycle 1: L, H, U (with L); the jump in the last one
		procedure ez_pop_pc is
		begin
			if mc = 1 then Set_Addr_To <= aSP; end if;
			if mc >= 2 then IncDec_16 <= "0111"; end if;
			if mc = 2 then LDZ <= '1'; Set_Addr_To <= aSP; end if;
			if mc = 3 and lw = 1 then LDW <= '1'; Set_Addr_To <= aSP; end if;
			if mc = 3 + lw then Jump <= '1'; end if;
		end procedure;
	begin
		DDD := IR(5 downto 3);
		SSS := IR(2 downto 0);
		DPair := IR(5 downto 4);
		IRB := to_bitvector(IR);

		MCycles <= "0001";
		if MCycle = "0001" then
			TStates <= "100";
		else
			TStates <= "011";
		end if;
		Prefix <= "00";
		Inc_PC <= '0';
		Inc_WZ <= '0';
		IncDec_16 <= "0000";
		Read_To_Acc <= '0';
		Read_To_Reg <= '0';
		Set_BusB_To <= "0000";
		Set_BusA_To <= "0000";
		ALU_Op <= "0" & IR(5 downto 3);
		Save_ALU <= '0';
		Rot_Akku <= '0';
		PreserveC <= '0';
		Arith16 <= '0';
		IORQ <= '0';
		Set_Addr_To <= aNone;
		Jump <= '0';
		JumpE <= '0';
		JumpXY <= '0';
		Call <= '0';
		RstP <= '0';
		LDZ <= '0';
		LDW <= '0';
		LDSPHL <= '0';
		LDHLSP <= '0';
		ADDSPdd <= '0';
		Special_LD <= "000";
		ExchangeDH <= '0';
		ExchangeRp <= '0';
		ExchangeAF <= '0';
		ExchangeRS <= '0';
		ExchangeWH <= '0';
		I_DJNZ <= '0';
		I_CPL <= '0';
		I_CCF <= '0';
		I_SCF <= '0';
		I_RETN <= '0';
		I_BT <= '0';
		I_BC <= '0';
		I_BTR <= '0';
		I_RLD <= '0';
		I_RRD <= '0';
		I_INRC <= '0';
		I_MULUB <= '0';
		I_MULU <= '0';
		SetDI <= '0';
		SetEI <= '0';
		IMode <= "11";
		Halt <= '0';
		NoRead <= '0';
		Write <= '0';
		No_PC <= '0';
		XYbit_undoc <= '0';
		SetWZ <= "00";
		Suffix <= '0';      -- karabas
		EzOp <= "0000";
		IOA0 <= '0';
		UOp <= "00";
		BusBU <= '0';
		LDU <= '0';
		EzRA <= "0000"; EzRB <= "0000"; EzRC <= "0000";
		AddrWZ <= '0'; WZAdd <= '0'; WZToReg <= '0'; EzBusB <= "00";
		BusBMode <= '0'; IntVec <= '0'; JumpV <= '0';
		StkSelA <= "00"; StkSelI <= "00"; LDMode <= '0'; JumpM <= '0';

		case ISet is
		when "00" =>

------------------------------------------------------------------------------
--
--	Unprefixed instructions
--
------------------------------------------------------------------------------

		case IRB is
-- 8 BIT LOAD GROUP
		when "01000000"|"01000001"|"01000010"|"01000011"|"01000100"|"01000101"|"01000111"
			|"01001000"|"01001001"|"01001010"|"01001011"|"01001100"|"01001101"|"01001111"
			|"01010000"|"01010001"|"01010010"|"01010011"|"01010100"|"01010101"|"01010111"
			|"01011000"|"01011001"|"01011010"|"01011011"|"01011100"|"01011101"|"01011111"
			|"01100000"|"01100001"|"01100010"|"01100011"|"01100100"|"01100101"|"01100111"
			|"01101000"|"01101001"|"01101010"|"01101011"|"01101100"|"01101101"|"01101111"
			|"01111000"|"01111001"|"01111010"|"01111011"|"01111100"|"01111101"|"01111111" =>
			-- LD r,r'
			Set_BusB_To(2 downto 0) <= SSS;
			ExchangeRp <= '1';
			Set_BusA_To(2 downto 0) <= DDD;
			Read_To_Reg <= '1';
		when "00000110"|"00001110"|"00010110"|"00011110"|"00100110"|"00101110"|"00111110" =>
			-- LD r,n
			MCycles <= "0010";
			case to_integer(unsigned(MCycle)) is
			when 2 =>
				Inc_PC <= '1';
				Set_BusA_To(2 downto 0) <= DDD;
				Read_To_Reg <= '1';
			when others => null;
			end case;
		when "01000110"|"01001110"|"01010110"|"01011110"|"01100110"|"01101110"|"01111110" =>
			-- LD r,(HL)
			MCycles <= "0010";
			case to_integer(unsigned(MCycle)) is
			when 1 =>
				Set_Addr_To <= aXY;
			when 2 =>
				Set_BusA_To(2 downto 0) <= DDD;
				Read_To_Reg <= '1';
			when others => null;
			end case;
		when "01110000"|"01110001"|"01110010"|"01110011"|"01110100"|"01110101"|"01110111" =>
			-- LD (HL),r
			MCycles <= "0010";
			case to_integer(unsigned(MCycle)) is
			when 1 =>
				Set_Addr_To <= aXY;
				Set_BusB_To(2 downto 0) <= SSS;
				Set_BusB_To(3) <= '0';
			when 2 =>
				Write <= '1';
			when others => null;
			end case;
		when "00110110" =>
			-- LD (HL),n
			MCycles <= "0011";
			case to_integer(unsigned(MCycle)) is
			when 2 =>
				Inc_PC <= '1';
				Set_Addr_To <= aXY;
				Set_BusB_To(2 downto 0) <= SSS;
				Set_BusB_To(3) <= '0';
			when 3 =>
				Write <= '1';
			when others => null;
			end case;
		when "00001010" =>
			-- LD A,(BC)
			MCycles <= "0010";
			case to_integer(unsigned(MCycle)) is
			when 1 =>
				Set_Addr_To <= aBC;
			when 2 =>
				Read_To_Acc <= '1';
			when others => null;
			end case;
		when "00011010" =>
			-- LD A,(DE)
			MCycles <= "0010";
			case to_integer(unsigned(MCycle)) is
			when 1 =>
				Set_Addr_To <= aDE;
			when 2 =>
				Read_To_Acc <= '1';
			when others => null;
			end case;
		when "00111010" =>
			if Mode = 3 then
				-- LDD A,(HL)
				MCycles <= "0010";
				case to_integer(unsigned(MCycle)) is
				when 1 =>
					Set_Addr_To <= aXY;
				when 2 =>
					Read_To_Acc <= '1';
					IncDec_16 <= "1110";
				when others => null;
				end case;
			else
				-- LD A,(nn)
				MCycles <= "0100";
				case to_integer(unsigned(MCycle)) is
				when 2 =>
					Inc_PC <= '1';
					LDZ <= '1';
				when 3 =>
					Set_Addr_To <= aZI;
					Inc_PC <= '1';
				when 4 =>
					Read_To_Acc <= '1';
				when others => null;
				end case;
			end if;
		when "00000010" =>
			-- LD (BC),A
			MCycles <= "0010";
			case to_integer(unsigned(MCycle)) is
			when 1 =>
				Set_Addr_To <= aBC;
				Set_BusB_To <= "0111";
				SetWZ <= "10";
			when 2 =>
				Write <= '1';
			when others => null;
			end case;
		when "00010010" =>
			-- LD (DE),A
			MCycles <= "0010";
			case to_integer(unsigned(MCycle)) is
			when 1 =>
				Set_Addr_To <= aDE;
				Set_BusB_To <= "0111";
				SetWZ <= "10";
			when 2 =>
				Write <= '1';
			when others => null;
			end case;
		when "00110010" =>
			if Mode = 3 then
				-- LDD (HL),A
				MCycles <= "0010";
				case to_integer(unsigned(MCycle)) is
				when 1 =>
					Set_Addr_To <= aXY;
					Set_BusB_To <= "0111";
				when 2 =>
					Write <= '1';
					IncDec_16 <= "1110";
				when others => null;
				end case;
			else
				-- LD (nn),A
				MCycles <= "0100";
				case to_integer(unsigned(MCycle)) is
				when 2 =>
					Inc_PC <= '1';
					LDZ <= '1';
				when 3 =>
					Set_Addr_To <= aZI;
					SetWZ <= "10";
					Inc_PC <= '1';
					Set_BusB_To <= "0111";
				when 4 =>
					Write <= '1';
				when others => null;
				end case;
			end if;

-- 16 BIT LOAD GROUP
		when "00000001"|"00010001"|"00100001"|"00110001" =>
			-- LD dd,nn
			MCycles <= "0011";
			case to_integer(unsigned(MCycle)) is
			when 2 =>
				Inc_PC <= '1';
				Read_To_Reg <= '1';
				if DPAIR = "11" then
					Set_BusA_To(3 downto 0) <= "1000";
				else
					Set_BusA_To(2 downto 1) <= DPAIR;
					Set_BusA_To(0) <= '1';
				end if;
			when 3 =>
				Inc_PC <= '1';
				Read_To_Reg <= '1';
				if DPAIR = "11" then
					Set_BusA_To(3 downto 0) <= "1001";
				else
					Set_BusA_To(2 downto 1) <= DPAIR;
					Set_BusA_To(0) <= '0';
				end if;
			when others => null;
			end case;
		when "00101010" =>
			if Mode = 3 then
				-- LDI A,(HL)
				MCycles <= "0010";
				case to_integer(unsigned(MCycle)) is
				when 1 =>
					Set_Addr_To <= aXY;
				when 2 =>
					Read_To_Acc <= '1';
					IncDec_16 <= "0110";
				when others => null;
				end case;
			else
				-- LD HL,(nn)
				MCycles <= "0101";
				case to_integer(unsigned(MCycle)) is
				when 2 =>
					Inc_PC <= '1';
					LDZ <= '1';
				when 3 =>
					Set_Addr_To <= aZI;
					Inc_PC <= '1';
					LDW <= '1';
				when 4 =>
					Set_BusA_To(2 downto 0) <= "101"; -- L
					Read_To_Reg <= '1';
					Inc_WZ <= '1';
					Set_Addr_To <= aZI;
				when 5 =>
					Set_BusA_To(2 downto 0) <= "100"; -- H
					Read_To_Reg <= '1';
				when others => null;
				end case;
			end if;
		when "00100010" =>
			if Mode = 3 then
				-- LDI (HL),A
				MCycles <= "0010";
				case to_integer(unsigned(MCycle)) is
				when 1 =>
					Set_Addr_To <= aXY;
					Set_BusB_To <= "0111";
				when 2 =>
					Write <= '1';
					IncDec_16 <= "0110";
				when others => null;
				end case;
			else
				-- LD (nn),HL
				MCycles <= "0101";
				case to_integer(unsigned(MCycle)) is
				when 2 =>
					Inc_PC <= '1';
					LDZ <= '1';
				when 3 =>
					Set_Addr_To <= aZI;
					Inc_PC <= '1';
					LDW <= '1';
					Set_BusB_To <= "0101"; -- L
				when 4 =>
					Inc_WZ <= '1';
					Set_Addr_To <= aZI;
					Write <= '1';
					Set_BusB_To <= "0100"; -- H
				when 5 =>
					Write <= '1';
				when others => null;
				end case;
			end if;
		when "11111001" =>
			-- LD SP,HL
			if Mode = 3 then
				MCycles <= "0010";
				if MCycle = "0010" then
					LDSPHL <= '1';
				end if;
			else
				TStates <= "110";
				LDSPHL <= '1';
			end if;
		when "11000101"|"11010101"|"11100101"|"11110101" =>
			-- PUSH qq
			if Mode = 3 then
				MCycles <= "0100";
				case to_integer(unsigned(MCycle)) is
				when 2 =>
					TStates <= "101";
					IncDec_16 <= "1111";
					Set_Addr_TO <= aSP;
					if DPAIR = "11" then
						Set_BusB_To <= "0111";
					else
						Set_BusB_To(2 downto 1) <= DPAIR;
						Set_BusB_To(0) <= '0';
						Set_BusB_To(3) <= '0';
					end if;
				when 3 =>
					IncDec_16 <= "1111";
					Set_Addr_To <= aSP;
					if DPAIR = "11" then
						Set_BusB_To <= "1011";
					else
						Set_BusB_To(2 downto 1) <= DPAIR;
						Set_BusB_To(0) <= '1';
						Set_BusB_To(3) <= '0';
					end if;
					Write <= '1';
				when 4 =>
					Write <= '1';
				when others => null;
				end case;
			else
				MCycles <= "0011";
				case to_integer(unsigned(MCycle)) is
				when 1 =>
					TStates <= "101";
					IncDec_16 <= "1111";
					Set_Addr_TO <= aSP;
					if DPAIR = "11" then
						Set_BusB_To <= "0111";
					else
						Set_BusB_To(2 downto 1) <= DPAIR;
						Set_BusB_To(0) <= '0';
						Set_BusB_To(3) <= '0';
					end if;
				when 2 =>
					IncDec_16 <= "1111";
					Set_Addr_To <= aSP;
					if DPAIR = "11" then
						Set_BusB_To <= "1011";
					else
						Set_BusB_To(2 downto 1) <= DPAIR;
						Set_BusB_To(0) <= '1';
						Set_BusB_To(3) <= '0';
					end if;
					Write <= '1';
				when 3 =>
					Write <= '1';
				when others => null;
				end case;
			end if;
		when "11000001"|"11010001"|"11100001"|"11110001" =>
			-- POP qq
			MCycles <= "0011";
			case to_integer(unsigned(MCycle)) is
			when 1 =>
				Set_Addr_To <= aSP;
			when 2 =>
				IncDec_16 <= "0111";
				Set_Addr_To <= aSP;
				Read_To_Reg <= '1';
				if DPAIR = "11" then
					Set_BusA_To(3 downto 0) <= "1011";
				else
					Set_BusA_To(2 downto 1) <= DPAIR;
					Set_BusA_To(0) <= '1';
				end if;
			when 3 =>
				IncDec_16 <= "0111";
				Read_To_Reg <= '1';
				if DPAIR = "11" then
					Set_BusA_To(3 downto 0) <= "0111";
				else
					Set_BusA_To(2 downto 1) <= DPAIR;
					Set_BusA_To(0) <= '0';
				end if;
			when others => null;
			end case;

-- EXCHANGE, BLOCK TRANSFER AND SEARCH GROUP
		when "11101011" =>
			if Mode /= 3 then
				-- EX DE,HL
				ExchangeDH <= '1';
			end if;
		when "00001000" =>
			if Mode = 3 then
				-- LD (nn),SP
				MCycles <= "0101";
				case to_integer(unsigned(MCycle)) is
				when 2 =>
					Inc_PC <= '1';
					LDZ <= '1';
				when 3 =>
					Set_Addr_To <= aZI;
					Inc_PC <= '1';
					LDW <= '1';
					Set_BusB_To <= "1000";
				when 4 =>
					Inc_WZ <= '1';
					Set_Addr_To <= aZI;
					Write <= '1';
					Set_BusB_To <= "1001";
				when 5 =>
					Write <= '1';
				when others => null;
				end case;
			elsif Mode < 2 then
				-- EX AF,AF'
				ExchangeAF <= '1';
			end if;
		when "11011001" =>
			if Mode = 3 then
				-- RETI
				MCycles <= "0100";
				case to_integer(unsigned(MCycle)) is
				when 1 =>
					Set_Addr_TO <= aSP;
				when 2 =>
					IncDec_16 <= "0111";
					Set_Addr_To <= aSP;
					LDZ <= '1';
				when 3 =>
					Jump <= '1';
					IncDec_16 <= "0111";
					--I_RETN <= '1';
					SetEI <= '1';
				when others => null;
				end case;
			elsif Mode < 2 then
				-- EXX
				ExchangeRS <= '1';
			end if;
		when "11100011" =>
			if Mode /= 3 then
				-- EX (SP),HL
				MCycles <= "0101";
				case to_integer(unsigned(MCycle)) is
				when 1 =>
					Set_Addr_To <= aSP;
				when 2 =>
					Set_Addr_To <= aSP;
					LDZ <= '1';
					IncDec_16 <= "0111"; -- SP <= SP+1
				when 3 =>
					TStates <= "100";
					Set_BusB_To <= "0100";
					Set_Addr_To <= aSP;
					LDW <= '1';
				when 4 =>
					Set_BusB_To <= "0101";
					Write <= '1';
					IncDec_16 <= "1111"; -- SP <= SP-1
					Set_Addr_To <= aSP;
				when 5 =>
					ExchangeWH <= '1'; -- save WZ to HL
					TStates <= "101";
					Write <= '1';
				when others => null;
				end case;
			end if;

-- 8 BIT ARITHMETIC AND LOGICAL GROUP
		when "10000000"|"10000001"|"10000010"|"10000011"|"10000100"|"10000101"|"10000111"
			|"10001000"|"10001001"|"10001010"|"10001011"|"10001100"|"10001101"|"10001111"
			|"10010000"|"10010001"|"10010010"|"10010011"|"10010100"|"10010101"|"10010111"
			|"10011000"|"10011001"|"10011010"|"10011011"|"10011100"|"10011101"|"10011111"
			|"10100000"|"10100001"|"10100010"|"10100011"|"10100100"|"10100101"|"10100111"
			|"10101000"|"10101001"|"10101010"|"10101011"|"10101100"|"10101101"|"10101111"
			|"10110000"|"10110001"|"10110010"|"10110011"|"10110100"|"10110101"|"10110111"
			|"10111000"|"10111001"|"10111010"|"10111011"|"10111100"|"10111101"|"10111111" =>
			-- ADD A,r
			-- ADC A,r
			-- SUB A,r
			-- SBC A,r
			-- AND A,r
			-- OR A,r
			-- XOR A,r
			-- CP A,r
			Set_BusB_To(2 downto 0) <= SSS;
			Set_BusA_To(2 downto 0) <= "111";
			Read_To_Reg <= '1';
			Save_ALU <= '1';
		when "10000110"|"10001110"|"10010110"|"10011110"|"10100110"|"10101110"|"10110110"|"10111110" =>
			-- ADD A,(HL)
			-- ADC A,(HL)
			-- SUB A,(HL)
			-- SBC A,(HL)
			-- AND A,(HL)
			-- OR A,(HL)
			-- XOR A,(HL)
			-- CP A,(HL)
			MCycles <= "0010";
			case to_integer(unsigned(MCycle)) is
			when 1 =>
				Set_Addr_To <= aXY;
			when 2 =>
				Read_To_Reg <= '1';
				Save_ALU <= '1';
				Set_BusB_To(2 downto 0) <= SSS;
				Set_BusA_To(2 downto 0) <= "111";
			when others => null;
			end case;
		when "11000110"|"11001110"|"11010110"|"11011110"|"11100110"|"11101110"|"11110110"|"11111110" =>
			-- ADD A,n
			-- ADC A,n
			-- SUB A,n
			-- SBC A,n
			-- AND A,n
			-- OR A,n
			-- XOR A,n
			-- CP A,n
			MCycles <= "0010";
			if MCycle = "0010" then
				Inc_PC <= '1';
				Read_To_Reg <= '1';
				Save_ALU <= '1';
				Set_BusB_To(2 downto 0) <= SSS;
				Set_BusA_To(2 downto 0) <= "111";
			end if;
		when "00000100"|"00001100"|"00010100"|"00011100"|"00100100"|"00101100"|"00111100" =>
			-- INC r
			Set_BusB_To <= "1010";
			Set_BusA_To(2 downto 0) <= DDD;
			Read_To_Reg <= '1';
			Save_ALU <= '1';
			PreserveC <= '1';
			ALU_Op <= "0000";
		when "00110100" =>
			-- INC (HL)
			MCycles <= "0011";
			case to_integer(unsigned(MCycle)) is
			when 1 =>
				Set_Addr_To <= aXY;
			when 2 =>
				TStates <= "100";
				Set_Addr_To <= aXY;
				Read_To_Reg <= '1';
				Save_ALU <= '1';
				PreserveC <= '1';
				ALU_Op <= "0000";
				Set_BusB_To <= "1010";
				Set_BusA_To(2 downto 0) <= DDD;
			when 3 =>
				Write <= '1';
			when others => null;
			end case;
		when "00000101"|"00001101"|"00010101"|"00011101"|"00100101"|"00101101"|"00111101" =>
			-- DEC r
			Set_BusB_To <= "1010";
			Set_BusA_To(2 downto 0) <= DDD;
			Read_To_Reg <= '1';
			Save_ALU <= '1';
			PreserveC <= '1';
			ALU_Op <= "0010";
		when "00110101" =>
			-- DEC (HL)
			MCycles <= "0011";
			case to_integer(unsigned(MCycle)) is
			when 1 =>
				Set_Addr_To <= aXY;
			when 2 =>
				TStates <= "100";
				Set_Addr_To <= aXY;
				ALU_Op <= "0010";
				Read_To_Reg <= '1';
				Save_ALU <= '1';
				PreserveC <= '1';
				Set_BusB_To <= "1010";
				Set_BusA_To(2 downto 0) <= DDD;
			when 3 =>
				Write <= '1';
			when others => null;
			end case;

-- GENERAL PURPOSE ARITHMETIC AND CPU CONTROL GROUPS
		when "00100111" =>
			-- DAA
			Set_BusA_To(2 downto 0) <= "111";
			Read_To_Reg <= '1';
			ALU_Op <= "1100";
			Save_ALU <= '1';
		when "00101111" =>
			-- CPL
			I_CPL <= '1';
		when "00111111" =>
			-- CCF
			I_CCF <= '1';
		when "00110111" =>
			-- SCF
			I_SCF <= '1';
		when "00000000" =>
			if NMICycle = '1' then
				-- NMI
				MCycles <= "0011";
				case to_integer(unsigned(MCycle)) is
				when 1 =>
					TStates <= "101";
					IncDec_16 <= "1111";
					Set_Addr_To <= aSP;
					Set_BusB_To <= "1101";
				when 2 =>
					Write <= '1';
					IncDec_16 <= "1111";
					Set_Addr_To <= aSP;
					Set_BusB_To <= "1100";
				when 3 =>
					Write <= '1';
				when others => null;
				end case;
			elsif IntCycle = '1' then
				-- INT (IM 2)
				if Mode = 3 then
					MCycles <= "0100";
					case to_integer(unsigned(MCycle)) is
					when 1 =>
						TStates <= "110";
						IncDec_16 <= "1111";
						Set_Addr_To <= aSP;
						Set_BusB_To <= "1101";
					when 2 =>
						Write <= '1';
					when 3 => -- GB: interrupt is acknowledged on MCycle 3
						LDZ <= '1';
						IncDec_16 <= "1111";
						Set_Addr_To <= aSP;
						Set_BusB_To <= "1100";
					when 4 =>
						Write <= '1';
					when others => null;
					end case;
				else
					MCycles <= "0101";
					case to_integer(unsigned(MCycle)) is
					when 1 =>
						TStates <= "101";
						IncDec_16 <= "1111";
						Set_Addr_To <= aSP;
						Set_BusB_To <= "1101";
					when 2 =>
						--TStates <= "100";
						Write <= '1';
						IncDec_16 <= "1111";
						Set_Addr_To <= aSP;
						Set_BusB_To <= "1100";
					when 3 =>
						--TStates <= "100";
						Write <= '1';
					when 4 =>
						Inc_PC <= '1';
						LDZ <= '1';
					when 5 =>
						Jump <= '1';
					when others => null;
					end case;
				end if;
			else
				-- NOP
			end if;
		when "01110110" =>
			-- HALT
			Halt <= '1';
		when "11110011" =>
			-- DI
			SetDI <= '1';
		when "11111011" =>
			-- EI
			SetEI <= '1';

-- 16 BIT ARITHMETIC GROUP
		when "00001001"|"00011001"|"00101001"|"00111001" =>
			-- ADD HL,ss
			if Mode = 3 then
				MCycles <= "0010";
				case to_integer(unsigned(MCycle)) is
				when 1 =>
					NoRead <= '1';
					ALU_Op <= "0000";
					Read_To_Reg <= '1';
					Save_ALU <= '1';
					Set_BusA_To(2 downto 0) <= "101";
					case to_integer(unsigned(IR(5 downto 4))) is
					when 0|1|2 =>
						Set_BusB_To(2 downto 1) <= IR(5 downto 4);
						Set_BusB_To(0) <= '1';
					when others =>
						Set_BusB_To <= "1000";
					end case;
					TStates <= "100";
					Arith16 <= '1';
					SetWZ <= "11";
				when 2 =>
					NoRead <= '1';
					Read_To_Reg <= '1';
					Save_ALU <= '1';
					ALU_Op <= "0001";
					Set_BusA_To(2 downto 0) <= "100";
					case to_integer(unsigned(IR(5 downto 4))) is
					when 0|1|2 =>
						Set_BusB_To(2 downto 1) <= IR(5 downto 4);
					when others =>
						Set_BusB_To <= "1001";
					end case;
					Arith16 <= '1';
				when others =>
				end case;
			else
				MCycles <= "0011";
				case to_integer(unsigned(MCycle)) is
				when 1 =>
					No_PC <= '1';
				when 2 =>
					NoRead <= '1';
					ALU_Op <= "0000";
					Read_To_Reg <= '1';
					Save_ALU <= '1';
					Set_BusA_To(2 downto 0) <= "101";
					case to_integer(unsigned(IR(5 downto 4))) is
					when 0|1|2 =>
						Set_BusB_To(2 downto 1) <= IR(5 downto 4);
						Set_BusB_To(0) <= '1';
					when others =>
						Set_BusB_To <= "1000";
					end case;
					TStates <= "100";
					Arith16 <= '1';
					SetWZ <= "11";
					No_PC <= '1';
				when 3 =>
					NoRead <= '1';
					Read_To_Reg <= '1';
					Save_ALU <= '1';
					ALU_Op <= "0001";
					Set_BusA_To(2 downto 0) <= "100";
					case to_integer(unsigned(IR(5 downto 4))) is
					when 0|1|2 =>
						Set_BusB_To(2 downto 1) <= IR(5 downto 4);
					when others =>
						Set_BusB_To <= "1001";
					end case;
					Arith16 <= '1';
				when others =>
				end case;
			end if;
		when "00000011"|"00010011"|"00100011"|"00110011" =>
			-- INC ss
			if Mode = 3 then
				MCycles <= "0010";
				case to_integer(unsigned(MCycle)) is
				when 2 =>
					IncDec_16(3 downto 2) <= "01";
					IncDec_16(1 downto 0) <= DPair;
				when others =>
				end case;
			else
				TStates <= "110";
				IncDec_16(3 downto 2) <= "01";
				IncDec_16(1 downto 0) <= DPair;
			end if;
		when "00001011"|"00011011"|"00101011"|"00111011" =>
			-- DEC ss
			if Mode = 3 then
				MCycles <= "0010";
				case to_integer(unsigned(MCycle)) is
				when 2 =>
					IncDec_16(3 downto 2) <= "11";
					IncDec_16(1 downto 0) <= DPair;
				when others =>
				end case;
			else
				TStates <= "110";
				IncDec_16(3 downto 2) <= "11";
				IncDec_16(1 downto 0) <= DPair;
			end if;

-- ROTATE AND SHIFT GROUP
		when "00000111"
			-- RLCA
			|"00010111"
			-- RLA
			|"00001111"
			-- RRCA
			|"00011111" =>
			-- RRA
			Set_BusA_To(2 downto 0) <= "111";
			ALU_Op <= "1000";
			Read_To_Reg <= '1';
			Rot_Akku <= '1';
			Save_ALU <= '1';

-- JUMP GROUP
		when "11000011" =>
			-- JP nn
			if Mode = 3 then
				MCycles <= "0100";
			else
				MCycles <= "0011";
			end if;
			case to_integer(unsigned(MCycle)) is
			when 2 =>
				Inc_PC <= '1';
				LDZ <= '1';
			when 3 =>
				Inc_PC <= '1';
				Jump <= '1';
				if Mode /= 3 then
					LDW <= '1';
				end if;
			when others => null;
			end case;
		when "11000010"|"11001010"|"11010010"|"11011010"|"11100010"|"11101010"|"11110010"|"11111010" =>
			if IR(5) = '1' and Mode = 3 then
				case IRB(4 downto 3) is
				when "00" =>
					-- LD ($FF00+C),A
					MCycles <= "0010";
					case to_integer(unsigned(MCycle)) is
					when 1 =>
						Set_Addr_To <= aBC;
						Set_BusB_To	<= "0111";
						IORQ <= '1'; --TH  must be earlier to be stable when address is generated
					when 2 =>
						Write <= '1';
					when others =>
					end case;
				when "01" =>
					-- LD (nn),A
					MCycles <= "0100";
					case to_integer(unsigned(MCycle)) is
					when 2 =>
						Inc_PC <= '1';
						LDZ <= '1';
					when 3 =>
						Set_Addr_To <= aZI;
						Inc_PC <= '1';
						Set_BusB_To <= "0111";
					when 4 =>
						Write <= '1';
					when others => null;
					end case;
				when "10" =>
					-- LD A,($FF00+C)
					MCycles <= "0010";
					case to_integer(unsigned(MCycle)) is
					when 1 =>
						Set_Addr_To <= aBC;
						IORQ <= '1'; --TH  must be earlier to be stable when address is generated
					when 2 =>
						Read_To_Acc <= '1';
					when others =>
					end case;
				when "11" =>
					-- LD A,(nn)
					MCycles <= "0100";
					case to_integer(unsigned(MCycle)) is
					when 2 =>
						Inc_PC <= '1';
						LDZ <= '1';
					when 3 =>
						Set_Addr_To <= aZI;
						Inc_PC <= '1';
					when 4 =>
						Read_To_Acc <= '1';
					when others => null;
					end case;
				end case;
			else
				-- JP cc,nn
				if Mode = 3 then
					MCycles <= "0100";
				else
					MCycles <= "0011";
				end if;
				case to_integer(unsigned(MCycle)) is
				when 2 =>
					Inc_PC <= '1';
					LDZ <= '1';
				when 3 =>
					if Mode /= 3 then
						LDW <= '1';
					end if;
					Inc_PC <= '1';
					if is_cc_true(F, to_bitvector(IR(5 downto 3))) then
						Jump <= '1';
					elsif Mode = 3 then
						MCycles <= "0011";
					end if;
				when others => null;
				end case;
			end if;
		when "00011000" =>
			if Mode /= 2 then
				-- JR e
				MCycles <= "0011";
				case to_integer(unsigned(MCycle)) is
				when 2 =>
					Inc_PC <= '1';
					No_PC <= '1';
				when 3 =>
					NoRead <= '1';
					JumpE <= '1';
					TStates <= "101";
				when others => null;
				end case;
			end if;
		when "00111000" =>
			if Mode /= 2 then
				-- JR C,e
				MCycles <= "0011";
				case to_integer(unsigned(MCycle)) is
				when 2 =>
					Inc_PC <= '1';
					if F(Flag_C) = '0' then
						MCycles <= "0010";
					else
						No_PC <= '1';
					end if;
				when 3 =>
					NoRead <= '1';
					JumpE <= '1';
					TStates <= "101";
				when others => null;
				end case;
			end if;
		when "00110000" =>
			if Mode /= 2 then
				-- JR NC,e
				MCycles <= "0011";
				case to_integer(unsigned(MCycle)) is
				when 2 =>
					Inc_PC <= '1';
					if F(Flag_C) = '1' then
						MCycles <= "0010";
					else
						No_PC <= '1';
					end if;
				when 3 =>
					NoRead <= '1';
					JumpE <= '1';
					TStates <= "101";
				when others => null;
				end case;
			end if;
		when "00101000" =>
			if Mode /= 2 then
				-- JR Z,e
				MCycles <= "0011";
				case to_integer(unsigned(MCycle)) is
				when 2 =>
					Inc_PC <= '1';
					if F(Flag_Z) = '0' then
						MCycles <= "0010";
					else
						No_PC <= '1';
					end if;
				when 3 =>
					NoRead <= '1';
					JumpE <= '1';
					TStates <= "101";
				when others => null;
				end case;
			end if;
		when "00100000" =>
			if Mode /= 2 then
				-- JR NZ,e
				MCycles <= "0011";
				case to_integer(unsigned(MCycle)) is
				when 2 =>
					Inc_PC <= '1';
					if F(Flag_Z) = '1' then
						MCycles <= "0010";
					else
						No_PC <= '1';
					end if;
				when 3 =>
					NoRead <= '1';
					JumpE <= '1';
					TStates <= "101";
				when others => null;
				end case;
			end if;
		when "11101001" =>
			-- JP (HL)
			JumpXY <= '1';
		when "00010000" =>  
			if Mode = 3 then -- STOP and skip next byte
				MCycles <= "0010";
				I_DJNZ <= '1';
				case to_integer(unsigned(MCycle)) is
				when 2 =>
					Inc_PC <= '1';
				when others => null;
				end case;
			elsif Mode < 2 then
				-- DJNZ,e
				MCycles <= "0011";
				case to_integer(unsigned(MCycle)) is
				when 1 =>
					TStates <= "101";
					I_DJNZ <= '1';
					Set_BusB_To <= "1010";
					Set_BusA_To(2 downto 0) <= "000";
					Read_To_Reg <= '1';
					Save_ALU <= '1';
					ALU_Op <= "0010";
				when 2 =>
					I_DJNZ <= '1';
					Inc_PC <= '1';
					No_PC <= '1';
				when 3 =>
					NoRead <= '1';
					JumpE <= '1';
					TStates <= "101";
				when others => null;
				end case;
			end if;

-- CALL AND RETURN GROUP
		when "11001101" =>
			-- CALL nn
			if Mode = 3 then
				MCycles <= "1110";
			else
				MCycles <= "0101";
			end if;
			case to_integer(unsigned(MCycle)) is
			when 2 =>
				Inc_PC <= '1';
				LDZ <= '1';
			when 3 =>
				IncDec_16 <= "1111";
				Inc_PC <= '1';
				TStates <= "100";
				Set_Addr_To <= aSP;
				LDW <= '1';
				Set_BusB_To <= "1101";
			when 4 =>
				Write <= '1';
				IncDec_16 <= "1111";
				Set_Addr_To <= aSP;
				Set_BusB_To <= "1100";
			when 5 =>
				Write <= '1';
				Call <= '1';
			when others => null;
			end case;
		when "11000100"|"11001100"|"11010100"|"11011100"|"11100100"|"11101100"|"11110100"|"11111100" =>
			if IR(5) = '0' or Mode /= 3 then
				-- CALL cc,nn
				if Mode = 3 then
					MCycles <= "1110";
				else
					MCycles <= "0101";
				end if;
				case to_integer(unsigned(MCycle)) is
				when 2 =>
					Inc_PC <= '1';
					LDZ <= '1';
				when 3 =>
					Inc_PC <= '1';
					LDW <= '1';
					if is_cc_true(F, to_bitvector(IR(5 downto 3))) then
						IncDec_16 <= "1111";
						Set_Addr_TO <= aSP;
						TStates <= "100";
						Set_BusB_To <= "1101";
					else
						MCycles <= "0011";
					end if;
				when 4 =>
					Write <= '1';
					IncDec_16 <= "1111";
					Set_Addr_To <= aSP;
					Set_BusB_To <= "1100";
				when 5 =>
					Write <= '1';
					Call <= '1';
				when others => null;
				end case;
			end if;
		when "11001001" =>
			-- RET
			if Mode = 3 then
				MCycles <= "0100";
				case to_integer(unsigned(MCycle)) is
				when 2 =>
					Set_Addr_TO <= aSP;
				when 3 =>
					IncDec_16 <= "0111";
					Set_Addr_To <= aSP;
					LDZ <= '1';
				when 4 =>
					Jump <= '1';
					IncDec_16 <= "0111";
				when others => null;
				end case;
			else
				MCycles <= "0011";
				case to_integer(unsigned(MCycle)) is
				when 1 =>
					--TStates <= "101";
					Set_Addr_TO <= aSP;
				when 2 =>
					IncDec_16 <= "0111";
					Set_Addr_To <= aSP;
					LDZ <= '1';
				when 3 =>
					Jump <= '1';
					IncDec_16 <= "0111";
				when others => null;
				end case;
			end if;
		when "11000000"|"11001000"|"11010000"|"11011000"|"11100000"|"11101000"|"11110000"|"11111000" =>
			if IR(5) = '1' and Mode = 3 then
				case IRB(4 downto 3) is
				when "00" =>
					-- LD ($FF00+nn),A
					MCycles <= "0011";
					case to_integer(unsigned(MCycle)) is
					when 2 =>
						Inc_PC <= '1';
						Set_Addr_To <= aIOA;
						Set_BusB_To	<= "0111";
					when 3 =>
						Write <= '1';
					when others => null;
					end case;
				when "01" =>
					-- ADD SP,n
					MCycles <= "0100";
					case to_integer(unsigned(MCycle)) is
					when 3 =>
						Inc_PC <= '1';
						ADDSPdd <= '1';
					when others =>
					end case;
				when "10" =>
					-- LD A,($FF00+nn)
					MCycles <= "0011";
					case to_integer(unsigned(MCycle)) is
					when 2 =>
						Inc_PC <= '1';
						Set_Addr_To <= aIOA;
					when 3 =>
						Read_To_Acc <= '1';
					when others => null;
					end case;
				when "11" =>
					-- LD HL,SP+n
					MCycles <= "0011";
					case to_integer(unsigned(MCycle)) is
					when 1 =>
						Inc_PC <= '1';
					when 2 =>
						LDHLSP <= '1';
						Inc_PC <= '1';
					when 3 =>
						LDHLSP <= '1';
					when others => null;
					end case;
				end case;
			else
				-- RET cc
				if Mode = 3 then
					MCycles <= "0101";
					case to_integer(unsigned(MCycle)) is
					when 2 =>
						if is_cc_true(F, to_bitvector(IR(5 downto 3))) then
							Set_Addr_TO <= aSP;
						else
							MCycles <= "0010";
						end if;
						TStates <= "101";
					when 3 =>
						IncDec_16 <= "0111";
						Set_Addr_To <= aSP;
						LDZ <= '1';
					when 4 =>
						Jump <= '1';
						IncDec_16 <= "0111";
					when others => null;
					end case;
				else
					MCycles <= "0011";
					case to_integer(unsigned(MCycle)) is
					when 1 =>
						if is_cc_true(F, to_bitvector(IR(5 downto 3))) then
							Set_Addr_TO <= aSP;
						else
							MCycles <= "0001";
						end if;
						TStates <= "101";
					when 2 =>
						IncDec_16 <= "0111";
						Set_Addr_To <= aSP;
						LDZ <= '1';
					when 3 =>
						Jump <= '1';
						IncDec_16 <= "0111";
					when others => null;
					end case;
				end if;
			end if;
		when "11000111"|"11001111"|"11010111"|"11011111"|"11100111"|"11101111"|"11110111"|"11111111" =>
			-- RST p
			if Mode = 3 then
				MCycles <= "0100";
				case to_integer(unsigned(MCycle)) is
				when 2 =>
					TStates <= "101";
					IncDec_16 <= "1111";
					Set_Addr_To <= aSP;
					Set_BusB_To <= "1101";
				when 3 =>
					Write <= '1';
					IncDec_16 <= "1111";
					Set_Addr_To <= aSP;
					Set_BusB_To <= "1100";
				when 4 =>
					Write <= '1';
					RstP <= '1';
				when others => null;
				end case;
			else
				MCycles <= "0011";
				case to_integer(unsigned(MCycle)) is
				when 1 =>
					TStates <= "101";
					IncDec_16 <= "1111";
					Set_Addr_To <= aSP;
					Set_BusB_To <= "1101";
				when 2 =>
					Write <= '1';
					IncDec_16 <= "1111";
					Set_Addr_To <= aSP;
					Set_BusB_To <= "1100";
				when 3 =>
					Write <= '1';
					RstP <= '1';
				when others => null;
				end case;
			end if;

-- INPUT AND OUTPUT GROUP
		when "11011011" =>
			if Mode /= 3 then
				-- IN A,(n)
				MCycles <= "0011";
				case to_integer(unsigned(MCycle)) is
				when 2 =>
					Inc_PC <= '1';
					Set_Addr_To <= aIOA;
				when 3 =>
					Read_To_Acc <= '1';
					IORQ <= '1';
				when others => null;
				end case;
			end if;
		when "11010011" =>
			if Mode /= 3 then
				-- OUT (n),A
				MCycles <= "0011";
				case to_integer(unsigned(MCycle)) is
				when 2 =>
					Inc_PC <= '1';
					Set_Addr_To <= aIOA;
					Set_BusB_To	<= "0111";
				when 3 =>
					Write <= '1';
					IORQ <= '1';
				when others => null;
				end case;
			end if;

------------------------------------------------------------------------------
------------------------------------------------------------------------------
-- MULTIBYTE INSTRUCTIONS
------------------------------------------------------------------------------
------------------------------------------------------------------------------

		when "11001011" =>
			if Mode /= 2 then
				Prefix <= "01";
			end if;

		when "11101101" =>
			if Mode < 2 then
				Prefix <= "10";
			end if;

		when "11011101"|"11111101" =>
			if Mode < 2 then
				Prefix <= "11";
			end if;

		end case;

		when "01" =>

------------------------------------------------------------------------------
--
--	CB prefixed instructions
--
------------------------------------------------------------------------------

			Set_BusA_To(2 downto 0) <= IR(2 downto 0);
			Set_BusB_To(2 downto 0) <= IR(2 downto 0);

			case IRB is
			when "00000000"|"00000001"|"00000010"|"00000011"|"00000100"|"00000101"|"00000111"
				|"00010000"|"00010001"|"00010010"|"00010011"|"00010100"|"00010101"|"00010111"
				|"00001000"|"00001001"|"00001010"|"00001011"|"00001100"|"00001101"|"00001111"
				|"00011000"|"00011001"|"00011010"|"00011011"|"00011100"|"00011101"|"00011111"
				|"00100000"|"00100001"|"00100010"|"00100011"|"00100100"|"00100101"|"00100111"
				|"00101000"|"00101001"|"00101010"|"00101011"|"00101100"|"00101101"|"00101111"
				|"00110000"|"00110001"|"00110010"|"00110011"|"00110100"|"00110101"|"00110111"
				|"00111000"|"00111001"|"00111010"|"00111011"|"00111100"|"00111101"|"00111111" =>
				-- RLC r
				-- RL r
				-- RRC r
				-- RR r
				-- SLA r
				-- SRA r
				-- SRL r
				-- SLL r (Undocumented) / SWAP r
				if XY_State="00" then
					if MCycle = "0001" then
					  ALU_Op <= "1000";
					  Read_To_Reg <= '1';
					  Save_ALU <= '1';
					end if;
				else
				-- R/S (IX+d),Reg, undocumented
					MCycles <= "0011";
					XYbit_undoc <= '1';
					case to_integer(unsigned(MCycle)) is
					when 1 | 7=>
						Set_Addr_To <= aXY;
					when 2 =>
						ALU_Op <= "1000";
						Read_To_Reg <= '1';
						Save_ALU <= '1';
						Set_Addr_To <= aXY;
						TStates <= "100";
					when 3 =>
						Write <= '1';
					when others => null;
					end case;
				end if;

			when "00000110"|"00010110"|"00001110"|"00011110"|"00101110"|"00111110"|"00100110"|"00110110" =>
				-- RLC (HL)
				-- RL (HL)
				-- RRC (HL)
				-- RR (HL)
				-- SRA (HL)
				-- SRL (HL)
				-- SLA (HL)
				-- SLL (HL) (Undocumented) / SWAP (HL)
				MCycles <= "0011";
				case to_integer(unsigned(MCycle)) is
				when 1 | 7 =>
					Set_Addr_To <= aXY;
				when 2 =>
					ALU_Op <= "1000";
					Read_To_Reg <= '1';
					Save_ALU <= '1';
					Set_Addr_To <= aXY;
					TStates <= "100";
				when 3 =>
					Write <= '1';
				when others =>
				end case;
			when "01000000"|"01000001"|"01000010"|"01000011"|"01000100"|"01000101"|"01000111"
				|"01001000"|"01001001"|"01001010"|"01001011"|"01001100"|"01001101"|"01001111"
				|"01010000"|"01010001"|"01010010"|"01010011"|"01010100"|"01010101"|"01010111"
				|"01011000"|"01011001"|"01011010"|"01011011"|"01011100"|"01011101"|"01011111"
				|"01100000"|"01100001"|"01100010"|"01100011"|"01100100"|"01100101"|"01100111"
				|"01101000"|"01101001"|"01101010"|"01101011"|"01101100"|"01101101"|"01101111"
				|"01110000"|"01110001"|"01110010"|"01110011"|"01110100"|"01110101"|"01110111"
				|"01111000"|"01111001"|"01111010"|"01111011"|"01111100"|"01111101"|"01111111" =>
				-- BIT b,r
				if XY_State="00" then
					if MCycle = "0001" then
					  Set_BusB_To(2 downto 0) <= IR(2 downto 0);
					  ALU_Op <= "1001";
					end if;
				else
				-- BIT b,(IX+d), undocumented
					MCycles <= "0010";
					XYbit_undoc <= '1';
					case to_integer(unsigned(MCycle)) is
					when 1 | 7=>
						Set_Addr_To <= aXY;
					when 2 =>
						ALU_Op <= "1001";
						TStates <= "100";
					when others => null;
					end case;
				end if;

			when "01000110"|"01001110"|"01010110"|"01011110"|"01100110"|"01101110"|"01110110"|"01111110" =>
				-- BIT b,(HL)
				MCycles <= "0010";
				case to_integer(unsigned(MCycle)) is
				when 1 | 7 =>
					Set_Addr_To <= aXY;
				when 2 =>
					ALU_Op <= "1001";
					TStates <= "100";
				when others => null;
				end case;
			when "11000000"|"11000001"|"11000010"|"11000011"|"11000100"|"11000101"|"11000111"
				|"11001000"|"11001001"|"11001010"|"11001011"|"11001100"|"11001101"|"11001111"
				|"11010000"|"11010001"|"11010010"|"11010011"|"11010100"|"11010101"|"11010111"
				|"11011000"|"11011001"|"11011010"|"11011011"|"11011100"|"11011101"|"11011111"
				|"11100000"|"11100001"|"11100010"|"11100011"|"11100100"|"11100101"|"11100111"
				|"11101000"|"11101001"|"11101010"|"11101011"|"11101100"|"11101101"|"11101111"
				|"11110000"|"11110001"|"11110010"|"11110011"|"11110100"|"11110101"|"11110111"
				|"11111000"|"11111001"|"11111010"|"11111011"|"11111100"|"11111101"|"11111111" =>
				-- SET b,r
				if XY_State="00" then
					if MCycle = "0001" then
						ALU_Op <= "1010";
						Read_To_Reg <= '1';
						Save_ALU <= '1';
					end if;
				else
				-- SET b,(IX+d),Reg, undocumented
					MCycles <= "0011";
					XYbit_undoc <= '1';
					case to_integer(unsigned(MCycle)) is
					when 1 | 7=>
						Set_Addr_To <= aXY;
					when 2 =>
						ALU_Op <= "1010";
						Read_To_Reg <= '1';
						Save_ALU <= '1';
						Set_Addr_To <= aXY;
						TStates <= "100";
					when 3 =>
						Write <= '1';
					when others => null;
					end case;
				end if;

			when "11000110"|"11001110"|"11010110"|"11011110"|"11100110"|"11101110"|"11110110"|"11111110" =>
				-- SET b,(HL)
				MCycles <= "0011";
				case to_integer(unsigned(MCycle)) is
				when 1 | 7 =>
					Set_Addr_To <= aXY;
				when 2 =>
					ALU_Op <= "1010";
					Read_To_Reg <= '1';
					Save_ALU <= '1';
					Set_Addr_To <= aXY;
					TStates <= "100";
				when 3 =>
					Write <= '1';
				when others => null;
				end case;
			when "10000000"|"10000001"|"10000010"|"10000011"|"10000100"|"10000101"|"10000111"
				|"10001000"|"10001001"|"10001010"|"10001011"|"10001100"|"10001101"|"10001111"
				|"10010000"|"10010001"|"10010010"|"10010011"|"10010100"|"10010101"|"10010111"
				|"10011000"|"10011001"|"10011010"|"10011011"|"10011100"|"10011101"|"10011111"
				|"10100000"|"10100001"|"10100010"|"10100011"|"10100100"|"10100101"|"10100111"
				|"10101000"|"10101001"|"10101010"|"10101011"|"10101100"|"10101101"|"10101111"
				|"10110000"|"10110001"|"10110010"|"10110011"|"10110100"|"10110101"|"10110111"
				|"10111000"|"10111001"|"10111010"|"10111011"|"10111100"|"10111101"|"10111111" =>
				-- RES b,r
				if XY_State="00" then
					if MCycle = "0001" then
						ALU_Op <= "1011";
						Read_To_Reg <= '1';
						Save_ALU <= '1';
					end if;
				else
				-- RES b,(IX+d),Reg, undocumented
					MCycles <= "0011";
					XYbit_undoc <= '1';
					case to_integer(unsigned(MCycle)) is
					when 1 | 7=>
						Set_Addr_To <= aXY;
					when 2 =>
						ALU_Op <= "1011";
						Read_To_Reg <= '1';
						Save_ALU <= '1';
						Set_Addr_To <= aXY;
						TStates <= "100";
					when 3 =>
						Write <= '1';
					when others => null;
					end case;
				end if;

			when "10000110"|"10001110"|"10010110"|"10011110"|"10100110"|"10101110"|"10110110"|"10111110" =>
				-- RES b,(HL)
				MCycles <= "0011";
				case to_integer(unsigned(MCycle)) is
				when 1 | 7 =>
					Set_Addr_To <= aXY;
				when 2 =>
					ALU_Op <= "1011";
					Read_To_Reg <= '1';
					Save_ALU <= '1';
					Set_Addr_To <= aXY;
					TStates <= "100";
				when 3 =>
					Write <= '1';
				when others => null;
				end case;
			end case;

		when others =>

------------------------------------------------------------------------------
--
--	ED prefixed instructions
--
------------------------------------------------------------------------------

			case IRB is
			when "00000000"|"00000001"|"00000010"|"00000011"|"00000100"|"00000101"|"00000110"|"00000111"
				|"00001000"|"00001001"|"00001010"|"00001011"|"00001100"|"00001101"|"00001110"|"00001111"
				|"00010000"|"00010001"|"00010010"|"00010011"|"00010100"|"00010101"|"00010110"|"00010111"
				|"00011000"|"00011001"|"00011010"|"00011011"|"00011100"|"00011101"|"00011110"|"00011111"
				|"00100000"|"00100001"|"00100010"|"00100011"|"00100100"|"00100101"|"00100110"|"00100111"
				|"00101000"|"00101001"|"00101010"|"00101011"|"00101100"|"00101101"|"00101110"|"00101111"
				|"00110000"|"00110001"|"00110010"|"00110011"|"00110100"|"00110101"|"00110110"|"00110111"
				|"00111000"|"00111001"|"00111010"|"00111011"|"00111100"|"00111101"|"00111110"|"00111111"


				|"10000000"|"10000001"|"10000010"|"10000011"|"10000100"|"10000101"|"10000110"|"10000111"
				|"10001000"|"10001001"|"10001010"|"10001011"|"10001100"|"10001101"|"10001110"|"10001111"
				|"10010000"|"10010001"|"10010010"|"10010011"|"10010100"|"10010101"|"10010110"|"10010111"
				|"10011000"|"10011001"|"10011010"|"10011011"|"10011100"|"10011101"|"10011110"|"10011111"
				|                                            "10100100"|"10100101"|"10100110"|"10100111"
				|                                            "10101100"|"10101101"|"10101110"|"10101111"
				|                                            "10110100"|"10110101"|"10110110"|"10110111"
				|                                            "10111100"|"10111101"|"10111110"|"10111111"
				|"11000000"|           "11000010"           |"11000100"|"11000101"|"11000110"|"11000111"
				|"11001000"|           "11001010"|"11001011"|"11001100"|"11001101"|"11001110"|"11001111"
				|"11010000"|           "11010010"|"11010011"|"11010100"|"11010101"|"11010110"|"11010111"
				|"11011000"|           "11011010"|"11011011"|"11011100"|"11011101"|"11011110"|"11011111"
				|"11100000"|"11100001"|"11100010"|"11100011"|"11100100"|"11100101"|"11100110"|"11100111"
				|"11101000"|"11101001"|"11101010"|"11101011"|"11101100"|"11101101"|"11101110"|"11101111"
				|"11110000"|"11110001"|"11110010"           |"11110100"|"11110101"|"11110110"|"11110111"
				|"11111000"|"11111001"|"11111010"|"11111011"|"11111100"|"11111101"|"11111110"|"11111111" =>
				null; -- NOP, undocumented
			when "01110111"|"01111111" =>
				-- NOP, undocumented
				null;
-- 8 BIT LOAD GROUP
			when "01010111" =>
				-- LD A,I
				Special_LD <= "100";
				TStates <= "101";
			when "01011111" =>
				-- LD A,R
				Special_LD <= "101";
				TStates <= "101";
			when "01000111" =>
				-- LD I,A
				Special_LD <= "110";
				TStates <= "101";
			when "01001111" =>
				-- LD R,A
				Special_LD <= "111";
				TStates <= "101";
-- 16 BIT LOAD GROUP
			when "01001011"|"01011011"|"01101011"|"01111011" =>
				-- LD dd,(nn)
				MCycles <= "0101";
				case to_integer(unsigned(MCycle)) is
				when 2 =>
					Inc_PC <= '1';
					LDZ <= '1';
				when 3 =>
					Set_Addr_To <= aZI;
					Inc_PC <= '1';
					LDW <= '1';
				when 4 =>
					Read_To_Reg <= '1';
					if IR(5 downto 4) = "11" then
						Set_BusA_To <= "1000";
					else
						Set_BusA_To(2 downto 1) <= IR(5 downto 4);
						Set_BusA_To(0) <= '1';
					end if;
					Inc_WZ <= '1';
					Set_Addr_To <= aZI;
				when 5 =>
					Read_To_Reg <= '1';
					if IR(5 downto 4) = "11" then
						Set_BusA_To <= "1001";
					else
						Set_BusA_To(2 downto 1) <= IR(5 downto 4);
						Set_BusA_To(0) <= '0';
					end if;
				when others => null;
				end case;
			when "01000011"|"01010011"|"01100011"|"01110011" =>
				-- LD (nn),dd
				MCycles <= "0101";
				case to_integer(unsigned(MCycle)) is
				when 2 =>
					Inc_PC <= '1';
					LDZ <= '1';
				when 3 =>
					Set_Addr_To <= aZI;
					Inc_PC <= '1';
					LDW <= '1';
					if IR(5 downto 4) = "11" then
						Set_BusB_To <= "1000";
					else
						Set_BusB_To(2 downto 1) <= IR(5 downto 4);
						Set_BusB_To(0) <= '1';
						Set_BusB_To(3) <= '0';
					end if;
				when 4 =>
					Inc_WZ <= '1';
					Set_Addr_To <= aZI;
					Write <= '1';
					if IR(5 downto 4) = "11" then
						Set_BusB_To <= "1001";
					else
						Set_BusB_To(2 downto 1) <= IR(5 downto 4);
						Set_BusB_To(0) <= '0';
						Set_BusB_To(3) <= '0';
					end if;
				when 5 =>
					Write <= '1';
				when others => null;
				end case;
			when "10100000" | "10101000" | "10110000" | "10111000" =>
				-- LDI, LDD, LDIR, LDDR
				MCycles <= "0100";
				case to_integer(unsigned(MCycle)) is
				when 1 =>
					Set_Addr_To <= aXY;
					IncDec_16 <= "1100"; -- BC
				when 2 =>
					Set_BusB_To <= "0110";
					Set_BusA_To(2 downto 0) <= "111";
					ALU_Op <= "0000";
					Set_Addr_To <= aDE;
					if IR(3) = '0' then
						IncDec_16 <= "0110"; -- IX
					else
						IncDec_16 <= "1110";
					end if;
				when 3 =>
					I_BT <= '1';
					TStates <= "101";
					Write <= '1';
					if IR(3) = '0' then
						IncDec_16 <= "0101"; -- DE
					else
						IncDec_16 <= "1101";
					end if;
					No_PC <= '1';
				when 4 =>
					NoRead <= '1';
					TStates <= "101";
				when others => null;
				end case;
			when "10100001" | "10101001" | "10110001" | "10111001" =>
				-- CPI, CPD, CPIR, CPDR
				MCycles <= "0100";
				case to_integer(unsigned(MCycle)) is
				when 1 =>
					Set_Addr_To <= aXY;
					IncDec_16 <= "1100"; -- BC
				when 2 =>
					Set_BusB_To <= "0110";
					Set_BusA_To(2 downto 0) <= "111";
					ALU_Op <= "0111";
					Save_ALU <= '1';
					PreserveC <= '1';
					if IR(3) = '0' then
						IncDec_16 <= "0110";
					else
						IncDec_16 <= "1110";
					end if;
					No_PC <= '1';
				when 3 =>
					NoRead <= '1';
					I_BC <= '1';
					TStates <= "101";
					No_PC <= '1';
				when 4 =>
					NoRead <= '1';
					TStates <= "101";
				when others => null;
				end case;
			when "01000100"|"01001100"|"01010100"|"01011100"|"01100100"|"01101100"|"01110100"|"01111100" =>
				-- NEG
				Alu_OP <= "0010";
				Set_BusB_To <= "0111";
				Set_BusA_To <= "1010";
				Read_To_Acc <= '1';
				Save_ALU <= '1';
			when "01000110"|"01001110"|"01100110"|"01101110" =>
				-- IM 0
				IMode <= "00";
			when "01010110"|"01110110" =>
				-- IM 1
				IMode <= "01";
			when "01011110"|"01111110" =>
				-- IM 2
				IMode <= "10";
-- 16 bit arithmetic
			when "01001010"|"01011010"|"01101010"|"01111010" =>
				-- ADC HL,ss
				MCycles <= "0011";
				case to_integer(unsigned(MCycle)) is
				when 1 =>
					No_PC <= '1';
				when 2 =>
					NoRead <= '1';
					ALU_Op <= "0001";
					Read_To_Reg <= '1';
					Save_ALU <= '1';
					Set_BusA_To(2 downto 0) <= "101";
					case to_integer(unsigned(IR(5 downto 4))) is
					when 0|1|2 =>
						Set_BusB_To(2 downto 1) <= IR(5 downto 4);
						Set_BusB_To(0) <= '1';
					when others =>
						Set_BusB_To <= "1000";
					end case;
					TStates <= "100";
					SetWZ <= "11";
					No_PC <= '1';
				when 3 =>
					NoRead <= '1';
					Read_To_Reg <= '1';
					Save_ALU <= '1';
					ALU_Op <= "0001";
					Set_BusA_To(2 downto 0) <= "100";
					case to_integer(unsigned(IR(5 downto 4))) is
					when 0|1|2 =>
						Set_BusB_To(2 downto 1) <= IR(5 downto 4);
						Set_BusB_To(0) <= '0';
					when others =>
						Set_BusB_To <= "1001";
					end case;
				when others =>
				end case;
			when "01000010"|"01010010"|"01100010"|"01110010" =>
				-- SBC HL,ss
				MCycles <= "0011";
				case to_integer(unsigned(MCycle)) is
				when 1 =>
					No_PC <= '1';
				when 2 =>
					NoRead <= '1';
					ALU_Op <= "0011";
					Read_To_Reg <= '1';
					Save_ALU <= '1';
					Set_BusA_To(2 downto 0) <= "101";
					case to_integer(unsigned(IR(5 downto 4))) is
					when 0|1|2 =>
						Set_BusB_To(2 downto 1) <= IR(5 downto 4);
						Set_BusB_To(0) <= '1';
					when others =>
						Set_BusB_To <= "1000";
					end case;
					TStates <= "100";
					SetWZ <= "11";
					No_PC <= '1';
				when 3 =>
					NoRead <= '1';
					ALU_Op <= "0011";
					Read_To_Reg <= '1';
					Save_ALU <= '1';
					Set_BusA_To(2 downto 0) <= "100";
					case to_integer(unsigned(IR(5 downto 4))) is
					when 0|1|2 =>
						Set_BusB_To(2 downto 1) <= IR(5 downto 4);
					when others =>
							Set_BusB_To <= "1001";
					end case;
				when others =>
				end case;
			when "01101111" =>
				-- RLD -- Read in M2, not M3! fixed by Sorgelig
				MCycles <= "0100";
				case to_integer(unsigned(MCycle)) is
				when 1 =>
					Set_Addr_To <= aXY;
				when 2 =>
					Read_To_Reg <= '1';
					Set_BusB_To(2 downto 0) <= "110";
					Set_BusA_To(2 downto 0) <= "111";
					ALU_Op <= "1101";
					Save_ALU <= '1';
					No_PC <= '1';
				when 3 =>
					TStates <= "100";
					I_RLD <= '1';
					NoRead <= '1';
					Set_Addr_To <= aXY;
				when 4 =>
					Write <= '1';
				when others =>
				end case;
			when "01100111" =>
				-- RRD -- Read in M2, not M3! fixed by Sorgelig
				MCycles <= "0100";
				case to_integer(unsigned(MCycle)) is
				when 1 =>
					Set_Addr_To <= aXY;
				when 2 =>
					Read_To_Reg <= '1';
					Set_BusB_To(2 downto 0) <= "110";
					Set_BusA_To(2 downto 0) <= "111";
					ALU_Op <= "1110";
					Save_ALU <= '1';
					No_PC <= '1';
				when 3 =>
					TStates <= "100";
					I_RRD <= '1';
					NoRead <= '1';
					Set_Addr_To <= aXY;
				when 4 =>
					Write <= '1';
				when others =>
				end case;
			when "01000101"|"01001101"|"01010101"|"01011101"|"01100101"|"01101101"|"01110101"|"01111101" =>
				-- RETI/RETN
				MCycles <= "0011";
				case to_integer(unsigned(MCycle)) is
				when 1 =>
					Set_Addr_TO <= aSP;
				when 2 =>
					IncDec_16 <= "0111";
					Set_Addr_To <= aSP;
					LDZ <= '1';
				when 3 =>
					Jump <= '1';
					IncDec_16 <= "0111";
					LDW <= '1';
					I_RETN <= '1';
				when others => null;
				end case;
			when "01000000"|"01001000"|"01010000"|"01011000"|"01100000"|"01101000"|"01110000"|"01111000" =>
				-- IN r,(C)
				MCycles <= "0010";
				case to_integer(unsigned(MCycle)) is
				when 1 =>
					Set_Addr_To <= aBC;
					SetWZ <= "01";
				when 2 =>
					IORQ <= '1';
					if IR(5 downto 3) /= "110" then
						Read_To_Reg <= '1';
						Set_BusA_To(2 downto 0) <= IR(5 downto 3);
					end if;
					I_INRC <= '1';
				when others =>
				end case;
			when "01000001"|"01001001"|"01010001"|"01011001"|"01100001"|"01101001"|"01110001"|"01111001" =>
				-- OUT (C),r
				-- OUT (C),0
				MCycles <= "0010";
				case to_integer(unsigned(MCycle)) is
				when 1 =>
					Set_Addr_To <= aBC;
					SetWZ <= "01";
					Set_BusB_To(2 downto 0)	<= IR(5 downto 3);
					if IR(5 downto 3) = "110" then
						Set_BusB_To(3) <= '1';
					end if;
				when 2 =>
					Write <= '1';
					IORQ <= '1';
				when others =>
				end case;
			when "10100010" | "10101010" | "10110010" | "10111010" =>
				-- INI, IND, INIR, INDR
				MCycles <= "0100";
				case to_integer(unsigned(MCycle)) is
				when 1 =>
					TStates <= "101";
					Set_Addr_To <= aBC;
					Set_BusB_To <= "1010";
					Set_BusA_To <= "0000";
					Read_To_Reg <= '1';
					Save_ALU <= '1';
					ALU_Op <= "0010";
					SetWZ <= "11";
					IncDec_16(3) <= IR(3);
				when 2 =>
					IORQ <= '1';
					Set_BusB_To <= "0110";
					Set_Addr_To <= aXY;
				when 3 =>
					if IR(3) = '0' then
						IncDec_16 <= "0110";
					else
						IncDec_16 <= "1110";
					end if;
					Write <= '1';
					I_BTR <= '1';
				when 4 =>
					NoRead <= '1';
					TStates <= "101";
				when others => null;
				end case;
			when "10100011" | "10101011" | "10110011" | "10111011" =>
				-- OUTI, OUTD, OTIR, OTDR
				MCycles <= "0100";
				case to_integer(unsigned(MCycle)) is
				when 1 =>
					TStates <= "101";
					Set_Addr_To <= aXY;
					Set_BusB_To <= "1010";
					Set_BusA_To <= "0000";
					Read_To_Reg <= '1';
					Save_ALU <= '1';
					ALU_Op <= "0010";
				when 2 =>
					Set_BusB_To <= "0110";
					Set_Addr_To <= aBC;
					SetWZ <= "11";
					IncDec_16(3) <= IR(3);
				when 3 =>
					if IR(3) = '0' then
						IncDec_16 <= "0110";
					else
						IncDec_16 <= "1110";
					end if;
					IORQ <= '1';
					Write <= '1';
					I_BTR <= '1';
				when 4 =>
					NoRead <= '1';
					TStates <= "101";
				when others => null;
				end case;
			when "11000001"|"11001001"|"11010001"|"11011001" =>
				 --R800 MULUB
				if R800_mode = '1' then
					MCycles <= "0010";
					case to_integer(unsigned(MCycle)) is
					when 1 =>
						NoRead <= '1';
						I_MULUB <= '1';
						Set_BusB_To(2 downto 0) <= IR(5 downto 3);
						Set_BusB_To(3) <= '0';
					when 2 =>
						NoRead <= '1';
						I_MULU <= '1';
						Set_BusA_To(2 downto 0) <= "100";
					when others => null;
					end case;
				end if;
			when "11000011"|"11110011" =>
				--R800 MULUW
				if R800_mode = '1' then
					MCycles <= "0010";
					case to_integer(unsigned(MCycle)) is
					when 1 =>
					NoRead <= '1';
						if DPAIR = "11" then
							Set_BusB_To(3 downto 0) <= "1000";
						else
							Set_BusB_To(2 downto 1) <= DPAIR;
							Set_BusB_To(0) <= '0';
							Set_BusB_To(3) <= '0';
						end if;
						Set_BusA_To(2 downto 0) <= "100";
					when 2 =>
						TStates <= "101";
						NoRead <= '1';
						I_MULU <= '1';
						Set_BusA_To(2 downto 0) <= "100";
					when others => null;
					end case;
				end if;
			end case;

		end case;

		if Mode = 1 then
			if MCycle = "0001" then
--				TStates <= "100";
			else
				TStates <= "011";
			end if;
		end if;

		if Mode = 3 then
			if MCycle = "0001" then
--				TStates <= "100";
			else
				TStates <= "100";
			end if;
		end if;

		if Mode < 2 then
			if MCycle = "1110" then
				Inc_PC <= '1';
				if Mode = 1 then
					Set_Addr_To <= aXY;
					TStates <= "100";
					Set_BusB_To(2 downto 0) <= SSS;
					Set_BusB_To(3) <= '0';
				end if;
				if IRB = "00110110" or IRB = "11001011" then
					Set_Addr_To <= aNone;
				end if;
				if not (IRB = "00110110" or ISet = "01") then
					No_PC <= '1';
				end if;
			end if;
			if MCycle = "1111" then
				if Mode = 0 then
					TStates <= "101";
				end if;
				if ISet /= "01" then
					Set_Addr_To <= aXY;
				end if;
				Set_BusB_To(2 downto 0) <= SSS;
				Set_BusB_To(3) <= '0';
				if IRB = "00110110" or ISet = "01" then
					-- LD (HL),n
					Inc_PC <= '1';
				else
					NoRead <= '1';
				end if;
			end if;
		end if;

		-------------------------------------------------------------------------------
		-- karabas: eZ80 overrides (the last assignment in the process wins). Semantics as
		-- CEmu core/cpu.c: L = data long, IL = immediate long, from ADL or a suffix.
		-- EzOp: 0001 STMIX, 0010 RSMIX, 0011 LD MB,A, 0100 LD A,MB
		-------------------------------------------------------------------------------
		if EZ80 /= 0 then
			mc := to_integer(unsigned(MCycle));
			if ILm = '1' then o := 1; else o := 0; end if;
			if Lm = '1' then lw := 1; else lw := 0; end if;
			dc := mc - 4 - o;
			if ADLm = '1' then adlv := 1; else adlv := 0; end if;
			case ISet is
			when "00" =>
				if XY_State = "00" then
					case IRB is
					when "01000000"|"01001001"|"01010010"|"01011011" =>
						-- .SIS / .LIS / .SIL / .LIL: a one-M1 prefix, the core takes L / IL from IR
						Suffix <= '1';
						Read_To_Reg <= '0';
						Set_BusA_To <= "0000";
						Set_BusB_To <= "0000";
					when others => null;
					end case;
				end if;
				-- DD / FD: LD rr,(IX+d) and LD (IX+d),rr (the d fetch: M1 aXY -> M14, M15 -> M2)
				done := false;
				if XY_State /= "00" then
					case IRB is
					when "00000111"|"00010111"|"00100111"|"00110001"|"00110111" =>
						-- LD BC / DE / HL,(IX+d); 31: DD -> IY, FD -> IX; 37: DD -> IX, FD -> IY
						-- (M14 / M15 = the d fetch of the core: only the Z80 operations off)
						done := true;
						if mc < 14 then ez_clear; else ez_clear_ops; end if;
						MCycles <= std_logic_vector(to_unsigned(3 + lw, 4));
						if IR = "00110001" then EzRA <= "1" & not XY_State(1) & "11";
						elsif IR = "00110111" then EzRA <= "1" & XY_State(1) & "11";
						else EzRA <= "10" & IR(5 downto 4); end if;
						if mc = 1 then Set_Addr_To <= aXY; end if;
						dc := mc - 2;
						ez_read_word(IR(5 downto 4), false);
					when "00001111"|"00011111"|"00101111"|"00111110"|"00111111" =>
						-- LD (IX+d),BC / DE / HL; 3E: DD -> IY, FD -> IX; 3F: DD -> IX, FD -> IY
						done := true;
						if mc < 14 then ez_clear; else ez_clear_ops; end if;
						MCycles <= std_logic_vector(to_unsigned(3 + lw, 4));
						if IR = "00111110" then EzRB <= "1" & not XY_State(1) & "11";
						elsif IR = "00111111" then EzRB <= "1" & XY_State(1) & "11";
						else EzRB <= "10" & IR(5 downto 4); end if;
						if mc = 1 then Set_Addr_To <= aXY; end if;
						if mc = 15 then dc := -1; else dc := mc - 2; end if;
						if mc /= 14 then ez_write_word(IR(5 downto 4), false); end if;
					when others => null;
					end case;
				end if;
				if not done then
				case IRB is
				when "00000001"|"00010001"|"00100001"|"00110001" =>
					-- LD dd,nn: with IL the third byte to the upper byte; with L only, the upper byte = 0
					if ILm = '1' then
						MCycles <= "0100";
						if MCycle = "0100" then
							Inc_PC <= '1';
							Read_To_Reg <= '1';
							UOp <= "01";
							if DPAIR = "11" then
								Set_BusA_To(3 downto 0) <= "1000";
							else
								Set_BusA_To(2 downto 1) <= DPAIR;
								Set_BusA_To(0) <= '1';
								Set_BusA_To(3) <= '0';
							end if;
						end if;
					elsif Lm = '1' and MCycle = "0011" then
						UOp <= "10";
					end if;
				when "00001001"|"00011001"|"00101001"|"00111001" =>
					-- ADD HL,ss (DD / FD: ADD IX / IY,ss): with L the upper byte in M4
					if lw = 1 then
						MCycles <= "0100";
						if mc = 4 then ez_alu_upper("0001", '1'); end if;
					end if;
				when "11000101"|"11010101"|"11100101"|"11110101" =>
					-- PUSH qq with L: upper, high, low (the upper byte of AF is 00)
					if lw = 1 then
						ez_clear;
						MCycles <= "0100";
						if mc <= 3 then
							IncDec_16 <= "1111";
							Set_Addr_To <= aSP;
						end if;
						if mc >= 2 then Write <= '1'; end if;
						if mc <= 3 then
							if DPAIR = "11" then
								case mc is
								when 1 => Set_BusB_To <= "1110";   -- 00
								when 2 => Set_BusB_To <= "0111";   -- A
								when others => Set_BusB_To <= "1011";  -- F
								end case;
							else
								Set_BusB_To(3) <= '0';
								Set_BusB_To(2 downto 1) <= DPAIR;
								if mc = 3 then Set_BusB_To(0) <= '1'; else Set_BusB_To(0) <= '0'; end if;
								if mc = 1 then BusBU <= '1'; end if;
							end if;
						end if;
						if mc = 1 then TStates <= "101"; end if;
					end if;
				when "11000001"|"11010001"|"11100001"|"11110001" =>
					-- POP qq with L: low, high, upper (the upper byte of AF is dropped)
					if lw = 1 then
						ez_clear;
						MCycles <= "0100";
						if mc <= 3 then Set_Addr_To <= aSP; end if;
						if mc >= 2 then
							IncDec_16 <= "0111";
							if DPAIR = "11" then
								if mc = 2 then
									Read_To_Reg <= '1'; Set_BusA_To <= "1011";  -- F
								elsif mc = 3 then
									Read_To_Reg <= '1'; Set_BusA_To <= "0111";  -- A
								end if;
							else
								Read_To_Reg <= '1';
								Set_BusA_To(3) <= '0';
								Set_BusA_To(2 downto 1) <= DPAIR;
								if mc = 3 then Set_BusA_To(0) <= '0'; else Set_BusA_To(0) <= '1'; end if;
								if mc = 4 then UOp <= "01"; end if;
							end if;
						end if;
					end if;
				when "00101010" =>
					-- LD HL,(nn) (DD / FD: IX, IY)
					ez_clear;
					MCycles <= std_logic_vector(to_unsigned(5 + o + lw, 4));
					ez_nn;
					ez_read_word("10", false);
				when "00100010" =>
					-- LD (nn),HL (DD / FD: IX, IY)
					ez_clear;
					MCycles <= std_logic_vector(to_unsigned(5 + o + lw, 4));
					ez_nn;
					ez_write_word("10", false);
				when "00111010" =>
					-- LD A,(nn)
					ez_clear;
					MCycles <= std_logic_vector(to_unsigned(4 + o, 4));
					ez_nn;
					if dc = 0 then Read_To_Acc <= '1'; end if;
				when "00110010" =>
					-- LD (nn),A
					ez_clear;
					MCycles <= std_logic_vector(to_unsigned(4 + o, 4));
					ez_nn;
					if dc = -1 then Set_BusB_To <= "0111"; end if;
					if dc = 0 then Write <= '1'; end if;
				when "11001101" =>
					-- CALL nn: nn 3 bytes with IL, the return address 3 bytes with L (not mixed)
					if o = 1 or lw = 1 then
						ez_clear;
						MCycles <= std_logic_vector(to_unsigned(3 + o + 2 + lw, 4));
						if mc = 2 then Inc_PC <= '1'; LDZ <= '1'; end if;
						if mc = 3 then Inc_PC <= '1'; LDW <= '1'; end if;
						if mc = 4 and o = 1 then Inc_PC <= '1'; LDU <= '1'; end if;
						if mc = 3 + o then TStates <= "100"; end if;
						ez_push_pc(3 + o, false);
					end if;
				when "11000100"|"11001100"|"11010100"|"11011100"|"11100100"|"11101100"|"11110100"|"11111100" =>
					-- CALL cc,nn
					if o = 1 or lw = 1 then
						ez_clear;
						MCycles <= std_logic_vector(to_unsigned(3 + o + 2 + lw, 4));
						if mc = 2 then Inc_PC <= '1'; LDZ <= '1'; end if;
						if mc = 3 then Inc_PC <= '1'; LDW <= '1'; end if;
						if mc = 4 and o = 1 then Inc_PC <= '1'; LDU <= '1'; end if;
						if is_cc_true(F, to_bitvector(IR(5 downto 3))) then
							if mc = 3 + o then TStates <= "100"; end if;
							ez_push_pc(3 + o, false);
						else
							MCycles <= std_logic_vector(to_unsigned(3 + o, 4));
						end if;
					end if;
				when "11001001" =>
					-- RET: after a suffix mixed, with L 3 bytes
					if Sfxm = '1' then
						ez_clear;
						ez_pop_mixed;
					elsif lw = 1 then
						ez_clear;
						MCycles <= "0100";
						ez_pop_pc;
					end if;
				when "11000000"|"11001000"|"11010000"|"11011000"|"11100000"|"11101000"|"11110000"|"11111000" =>
					-- RET cc: after a suffix mixed, with L 3 bytes
					if Sfxm = '1' or lw = 1 then
						ez_clear;
						if not is_cc_true(F, to_bitvector(IR(5 downto 3))) then
							MCycles <= "0001";
						elsif Sfxm = '1' then
							ez_pop_mixed;
						else
							MCycles <= "0100";
							ez_pop_pc;
						end if;
					end if;
				when "11000111"|"11001111"|"11010111"|"11011111"|"11100111"|"11101111"|"11110111"|"11111111" =>
					-- RST p with L: 3 bytes
					if lw = 1 then
						ez_clear;
						MCycles <= "0100";
						if mc = 1 then TStates <= "101"; end if;
						ez_push_pc(1, true);
					end if;
				when "11000010"|"11001010"|"11010010"|"11011010"|"11100010"|"11101010"|"11110010"|"11111010" =>
					-- JP cc,nn with IL: 3 address bytes, the jump in M4
					if o = 1 then
						ez_clear;
						MCycles <= "0100";
						if mc = 2 then Inc_PC <= '1'; LDZ <= '1'; end if;
						if mc = 3 then Inc_PC <= '1'; LDW <= '1'; end if;
						if mc = 4 then
							Inc_PC <= '1';
							if is_cc_true(F, to_bitvector(IR(5 downto 3))) then Jump <= '1'; end if;
						end if;
					end if;
				when "11100011" =>
					-- EX (SP),HL with L (DD / FD: IX, IY): read 3 bytes into WZ, write U, H, L back
					if lw = 1 then
						ez_clear;
						MCycles <= "0111";
						case mc is
						when 1 => Set_Addr_To <= aSP;
						when 2 => Set_Addr_To <= aSP; LDZ <= '1'; IncDec_16 <= "0111";
						when 3 => Set_Addr_To <= aSP; LDW <= '1'; IncDec_16 <= "0111";
						when 4 => Set_Addr_To <= aSP; LDU <= '1'; Set_BusB_To <= "0100"; BusBU <= '1'; TStates <= "100";
						when 5 => Write <= '1'; IncDec_16 <= "1111"; Set_Addr_To <= aSP; Set_BusB_To <= "0100";
						when 6 => Write <= '1'; IncDec_16 <= "1111"; Set_Addr_To <= aSP; Set_BusB_To <= "0101";
						when 7 => Write <= '1'; ExchangeWH <= '1'; TStates <= "101";
						when others => null;
						end case;
					end if;
				when "11000011" =>
					-- JP nn: with IL a third address byte, the jump in M4 (WZ = low / high, DI = upper)
					if ILm = '1' then
						MCycles <= "0100";
						Jump <= '0';
						case to_integer(unsigned(MCycle)) is
						when 2 =>
							Inc_PC <= '1';
							LDZ <= '1';
						when 3 =>
							Inc_PC <= '1';
							LDW <= '1';
						when 4 =>
							Inc_PC <= '1';
							Jump <= '1';
						when others => null;
						end case;
					end if;
				when others => null;
				end case;
				end if;  -- not done
			when "10" =>
				case IRB is
				when "01000101"|"01001101" =>
					-- RETN / RETI: after a suffix mixed, with L 3 bytes; IFF1 <= IFF2 stays (I_RETN)
					if Sfxm = '1' then
						ez_clear;
						I_RETN <= '1';
						ez_pop_mixed;
					elsif lw = 1 then
						ez_clear;
						I_RETN <= '1';
						MCycles <= "0100";
						ez_pop_pc;
					end if;
				when "00000010"|"00010010"|"00100010"|"00110010"|"00000011"|"00010011"|"00100011"|"00110011"|"01010100"|"01010101" =>
					-- LEA rr,IX+d / LEA rr,IY+d / LEA IX,IY+d (54) / LEA IY,IX+d (55)
					ez_clear;
					MCycles <= "0011";
					if IR = "01010100" then EzRC <= "1111";          -- base IY
					elsif IR = "01010101" then EzRC <= "1011";       -- base IX
					else EzRC <= "1" & IR(0) & "11"; end if;         -- x2: IX, x3: IY
					if IR = "01010100" then EzRA <= "1011";          -- target IX
					elsif IR = "01010101" then EzRA <= "1111";       -- target IY
					elsif IR(5 downto 4) = "11" then EzRA <= "1" & IR(0) & "11";
					else EzRA <= "10" & IR(5 downto 4); end if;
					if mc = 2 then Inc_PC <= '1'; WZAdd <= '1'; end if;
					if mc = 3 then WZToReg <= '1'; end if;
				when "01100101"|"01100110" =>
					-- PEA IX+d (65) / PEA IY+d (66): push base + d
					ez_clear;
					MCycles <= std_logic_vector(to_unsigned(3 + 2 + lw, 4));
					EzRC <= "1" & IR(1) & "11";
					if mc = 2 then Inc_PC <= '1'; WZAdd <= '1'; end if;
					if mc >= 3 and mc - 3 < 2 + lw then
						IncDec_16 <= "1111";
						Set_Addr_To <= aSP;
						if mc - 3 = 1 + lw then EzBusB <= "01";
						elsif lw = 1 and mc = 3 then EzBusB <= "11";
						else EzBusB <= "10"; end if;
					end if;
					if mc >= 4 then Write <= '1'; end if;
				when "00000111"|"00010111"|"00100111"|"00110111"|"00110001" =>
					-- LD rr,(HL): 07 BC, 17 DE, 27 HL, 37 IX, 31 IY
					ez_clear;
					MCycles <= std_logic_vector(to_unsigned(3 + lw, 4));
					if IR = "00110111" then EzRA <= "1011";
					elsif IR = "00110001" then EzRA <= "1111";
					else EzRA <= "10" & IR(5 downto 4); end if;
					if mc = 1 then Set_Addr_To <= aXY; AddrWZ <= '1'; end if;
					dc := mc - 2;
					ez_read_word(IR(5 downto 4), false);
				when "00001111"|"00011111"|"00101111"|"00111111"|"00111110" =>
					-- LD (HL),rr: 0F BC, 1F DE, 2F HL, 3F IX, 3E IY
					ez_clear;
					MCycles <= std_logic_vector(to_unsigned(3 + lw, 4));
					if IR = "00111111" then EzRB <= "1011";
					elsif IR = "00111110" then EzRB <= "1111";
					else EzRB <= "10" & IR(5 downto 4); end if;
					if mc = 1 then Set_Addr_To <= aXY; AddrWZ <= '1'; end if;
					dc := mc - 2;
					ez_write_word(IR(5 downto 4), false);
				when "01001100"|"01011100"|"01101100" =>
					-- MLT rr (BC / DE / HL): rr <= low * high
					ez_clear;
					MCycles <= "0010";
					Set_BusA_To <= "0" & IR(5 downto 4) & "0";
					if mc = 2 then EzOp <= "0101"; end if;
				when "00000100"|"00001100"|"00010100"|"00011100"|"00100100"|"00101100"|"00111100" =>
					-- TST A,r: AND without the store
					ez_clear;
					MCycles <= "0001";
					Set_BusA_To <= "0111";
					Set_BusB_To(2 downto 0) <= IR(5 downto 3);
					Set_BusB_To(3) <= '0';
					ALU_Op <= "0100";
					Save_ALU <= '1';
				when "01100100" =>
					-- TST A,n
					ez_clear;
					MCycles <= "0010";
					if mc = 2 then
						Inc_PC <= '1';
						Set_BusA_To <= "0111";
						Set_BusB_To <= "0110";
						ALU_Op <= "0100";
						Save_ALU <= '1';
					end if;
				when "00110100" =>
					-- TST A,(HL)
					ez_clear;
					MCycles <= "0010";
					if mc = 1 then Set_Addr_To <= aXY; end if;
					if mc = 2 then
						Set_BusA_To <= "0111";
						Set_BusB_To <= "0110";
						ALU_Op <= "0100";
						Save_ALU <= '1';
					end if;
				when "01000010"|"01010010"|"01100010"|"01110010" =>
					-- SBC HL,ss: with L the upper byte in M4
					if lw = 1 then
						MCycles <= "0100";
						if mc = 4 then ez_alu_upper("0011", '0'); end if;
					end if;
				when "01001010"|"01011010"|"01101010"|"01111010" =>
					-- ADC HL,ss: with L the upper byte in M4
					if lw = 1 then
						MCycles <= "0100";
						if mc = 4 then ez_alu_upper("0001", '0'); end if;
					end if;
				when "01001011"|"01011011"|"01101011"|"01111011" =>
					-- LD dd,(nn)
					ez_clear;
					MCycles <= std_logic_vector(to_unsigned(5 + o + lw, 4));
					ez_nn;
					ez_read_word(IR(5 downto 4), IR(5 downto 4) = "11");
				when "01000011"|"01010011"|"01100011"|"01110011" =>
					-- LD (nn),dd
					ez_clear;
					MCycles <= std_logic_vector(to_unsigned(5 + o + lw, 4));
					ez_nn;
					ez_write_word(IR(5 downto 4), IR(5 downto 4) = "11");
				when "01111101"|"01111110"|"01101101"|"01101110" =>
					-- one M1, nothing of the Z80 aliases (RETN, IM n) at these codes
					MCycles <= "0001";
					I_RETN <= '0';
					IMode <= "11";
					Set_Addr_To <= aNone;
					IncDec_16 <= "0000";
					Read_To_Reg <= '0';
					Read_To_Acc <= '0';
					Jump <= '0';
					LDZ <= '0';
					LDW <= '0';
					Inc_PC <= '0';
					NoRead <= '0';
					Write <= '0';
					case IRB is
					when "01111101" => EzOp <= "0001";  -- STMIX
					when "01111110" => EzOp <= "0010";  -- RSMIX
					when "01101101" => EzOp <= "0011";  -- LD MB,A
					when others     => EzOp <= "0100";  -- LD A,MB
					end case;
				when "00000000"|"00001000"|"00010000"|"00011000"|"00100000"|"00101000"|"00110000"|"00111000" =>
					-- IN0 r,(n): port 00:n, flags as IN r,(C) (IN0 (n) at r = 110: flags only)
					MCycles <= "0011";
					case to_integer(unsigned(MCycle)) is
					when 2 =>
						Inc_PC <= '1';
						Set_Addr_To <= aIOA;
						IOA0 <= '1';
					when 3 =>
						IORQ <= '1';
						if IR(5 downto 3) /= "110" then
							Read_To_Reg <= '1';
							Set_BusA_To(2 downto 0) <= IR(5 downto 3);
							Set_BusA_To(3) <= '0';
						end if;
						I_INRC <= '1';
					when others => null;
					end case;
				when "00000001"|"00001001"|"00010001"|"00011001"|"00100001"|"00101001"|"00111001" =>
					-- OUT0 (n),r: port 00:n
					MCycles <= "0011";
					case to_integer(unsigned(MCycle)) is
					when 2 =>
						Inc_PC <= '1';
						Set_Addr_To <= aIOA;
						IOA0 <= '1';
						Set_BusB_To(2 downto 0) <= IR(5 downto 3);
						Set_BusB_To(3) <= '0';
					when 3 =>
						Write <= '1';
						IORQ <= '1';
					when others => null;
					end case;
				when others => null;
				end case;
			when others => null;
			end case;
		end if;

		-- karabas: eZ80 vectored interrupt (eZ80F92 as the Agon emulator): the vector came on the bus
		-- in the acknowledge M1 (WZ(7:0)); with MADL: PC (3 bytes in ADL, 2 in Z80 mode) and the mode
		-- byte (MADL << 1 | ADL) on SPL; without: PC as a CALL in the current mode. Then the 16-bit
		-- handler address from the table at 00:I:vector, ADL <= ADL or MADL.
		if EZ80 /= 0 and ISet = "00" and IRB = "00000000" and IntCycle = '1' and NMICycle = '0' then
			ez_clear;
			if MADLm = '1' then np := 3 + adlv; else np := 2 + adlv; end if;  -- the bytes to push
			MCycles <= std_logic_vector(to_unsigned(1 + np + 2, 4));
			k2 := mc - 1;   -- 0 = the cycle setting up the first byte
			if k2 >= 0 and k2 < np then
				IncDec_16 <= "1111";
				Set_Addr_To <= aSP;
				if MADLm = '1' and k2 = np - 1 then
					BusBMode <= '1';                          -- the mode byte last
				elsif adlv = 1 and k2 = 0 then
					Set_BusB_To <= "1101"; BusBU <= '1';      -- PCU
				elsif (adlv = 1 and k2 = 1) or (adlv = 0 and k2 = 0) then
					Set_BusB_To <= "1101";                    -- PCH
				else
					Set_BusB_To <= "1100";                    -- PCL
				end if;
			end if;
			if k2 >= 1 and k2 <= np then Write <= '1'; end if;
			if k2 = np then IntVec <= '1'; end if;           -- the table address at the end
			if k2 = np + 1 then Inc_PC <= '1'; LDZ <= '1'; end if;
			if k2 = np + 2 then JumpV <= '1'; end if;
			if mc = 1 then TStates <= "101"; end if;
		end if;

	end process;

end;
