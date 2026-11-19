// karabas: deterministic stepping of AgonMachine for the eZ80 RTL oracle (src/oracle).
// Built into a copy of agon-ez80-emulator as a child module of agon_machine (the Makefile adds
// `#[path] mod kg_trace;` there), so it reaches the private fields. The upstream start() runs in
// real time and lets the host serve MOS's FatFS calls (hostfs); here: no wall clock, and with
// hostfs off MOS runs its own FatFS on the SPI SD card image, as on the board.
//
// kg_step_logged() also records the bus events of the instruction (memory writes, port reads and
// writes) and the interrupt taken after it, for the replay testbench of the RTL.
use super::*;

/// A bus event of one instruction (or of the interrupt entry after it).
#[derive(Clone, Copy, Debug)]
pub enum KgEv {
    /// memory write: address, value
    MemW(u32, u8),
    /// port read: port, value
    IoR(u16, u8),
    /// port write: port, value
    IoW(u16, u8),
    /// interrupt taken after the instruction: the vector number (the entry's pushes follow)
    Int(u32),
}

/// The machine seen by the CPU, recording the events.
struct KgBus<'a> {
    m: &'a mut AgonMachine,
    ev: &'a mut Vec<KgEv>,
}

impl<'a> Machine for KgBus<'a> {
    fn peek(&self, address: u32) -> u8 {
        self.m.peek(address)
    }
    fn poke(&mut self, address: u32, value: u8) {
        self.ev.push(KgEv::MemW(address, value));
        self.m.poke(address, value)
    }
    fn use_cycles(&self, cycles: i32) {
        self.m.use_cycles(cycles)
    }
    fn port_in(&mut self, address: u16) -> u8 {
        let v = self.m.port_in(address);
        self.ev.push(KgEv::IoR(address, v));
        v
    }
    fn port_out(&mut self, address: u16, value: u8) {
        self.ev.push(KgEv::IoW(address, value));
        self.m.port_out(address, value)
    }
}

/// The R register as the Z80 / T80 / CEmu count it: bits 6..0 + 1 per opcode fetch (M1: each
/// suffix, DD / FD / ED / CB prefix and the opcode; not the opcode of DD / FD CB d op), bit 7 kept;
/// LD R,A (ED 4F) sets it. bytes = the first bytes of the instruction, int = an interrupt M1 after it.
/// The crate adds 1 per instruction to all 8 bits.
pub fn kg_r_fix(r_before: u8, r_after: u8, bytes: [u8; 4], int: bool) -> u8 {
    let mut i = 0;
    let mut m1 = 0u8;
    while i < 2 && matches!(bytes[i], 0x40 | 0x49 | 0x52 | 0x5b) {
        m1 += 1;
        i += 1;
    }
    let mut set_by_ld = false;
    match bytes[i] {
        0xdd | 0xfd => {
            m1 += 2; // the prefix and the next M1 (CB too: its op is fetched as data)
        }
        0xed => {
            m1 += 2;
            set_by_ld = bytes[i + 1] == 0x4f;
        }
        0xcb => m1 += 2,
        _ => m1 += 1,
    }
    if int {
        m1 += 1;
    }
    if set_by_ld {
        // LD R,A: R = A, then the M1s after it (none: the write is the last thing)
        return r_after;
    }
    (r_before & 0x80) | (r_before.wrapping_add(m1) & 0x7f)
}

/// LD A,R (ED 5F, after the suffixes) reads R after its own M1s: A and S / Z from the fixed R.
pub fn kg_ld_a_r_fix(reg: &mut Registers, bytes: [u8; 4], r: u8) {
    let mut i = 0;
    while i < 2 && matches!(bytes[i], 0x40 | 0x49 | 0x52 | 0x5b) {
        i += 1;
    }
    if bytes[i] == 0xed && bytes[i + 1] == 0x5f {
        reg.set_a(r);
        let f = (reg.get8(Reg8::F) & !0xc0) | (r & 0x80) | if r == 0 { 0x40 } else { 0 };
        reg.set8(Reg8::F, f);
    }
}

impl AgonMachine {
    /// Load MOS, clear the RAM (RamInit::Zero) and return the CPU at PC 0.
    pub fn kg_boot(&mut self, hostfs: bool) -> Cpu {
        self.enable_hostfs = hostfs;
        self.load_mos();
        let mut cpu = Cpu::new_ez80();
        cpu.state.set_pc(0);
        cpu
    }

    /// One instruction, then the peripherals and interrupts as in start().
    pub fn kg_step(&mut self, cpu: &mut Cpu) {
        self.execute_instruction(cpu);
        if self.cycle_counter.get() >= self.interrupt_precision {
            self.apply_elapsed_cycles();
            self.do_interrupts(cpu);
        }
    }

    /// kg_step with the bus events in ev (cleared first). Without hostfs only: its traps
    /// change memory behind the CPU's back.
    pub fn kg_step_logged(&mut self, cpu: &mut Cpu, ev: &mut Vec<KgEv>) {
        assert!(!self.enable_hostfs, "kg_step_logged: hostfs must be off");
        ev.clear();
        self.last_pc = cpu.state.pc();
        // eZ80 flag bits 3 and 5: unchanged by every instruction but the whole-F loads (POP AF,
        // EX AF,AF'), as CEmu (cpuflag_undef); the crate copies the Z80 rules in most places
        let pc = cpu.state.pc();
        let mut op = self.kg_peek_raw(pc);
        if matches!(op, 0x40 | 0x49 | 0x52 | 0x5b) {
            op = self.kg_peek_raw(pc.wrapping_add(1));
        }
        let f_load = op == 0xf1 || op == 0x08;
        let xy = cpu.state.reg.get8(Reg8::F) & 0x28;
        let r_before = cpu.state.reg.get8(Reg8::R);
        let ib = [self.kg_peek_raw(pc), self.kg_peek_raw(pc.wrapping_add(1)),
                  self.kg_peek_raw(pc.wrapping_add(2)), self.kg_peek_raw(pc.wrapping_add(3))];
        if cpu.is_halted() {
            self.cycle_counter.set(self.cycle_counter.get().wrapping_add(4));
        } else {
            cpu.fast_execute_instruction(&mut KgBus { m: self, ev });
        }
        if !f_load {
            let f = (cpu.state.reg.get8(Reg8::F) & !0x28) | xy;
            cpu.state.reg.set8(Reg8::F, f);
        }
        if self.cycle_counter.get() >= self.interrupt_precision {
            self.apply_elapsed_cycles();
            self.kg_do_interrupts(cpu, ev);
        }
        let int = ev.iter().any(|e| matches!(e, KgEv::Int(_)));
        let halted = ib[0] == 0x76;  // HALT repeats: one M1 per step as the crate counts it
        let r = if halted { cpu.state.reg.get8(Reg8::R) } else { kg_r_fix(r_before, cpu.state.reg.get8(Reg8::R), ib, int) };
        cpu.state.reg.set8(Reg8::R, r);
        if !halted {
            kg_ld_a_r_fix(&mut cpu.state.reg, ib, r);
        }
    }

    // do_interrupts() of agon_machine.rs (same priorities), the entry through KgBus
    fn kg_do_interrupts(&mut self, cpu: &mut Cpu, ev: &mut Vec<KgEv>) {
        if !cpu.state.reg.get_iff1() {
            return;
        }
        let mut vector = None;
        for i in 0..self.prt_timers.len() {
            if self.prt_timers[i].irq_due() {
                vector = Some(0xa + 2 * (i as u32));
                break;
            }
        }
        if vector.is_none() && self.uart0.is_interrupt_due() {
            vector = Some(0x18);
        }
        if vector.is_none() && self.uart1.is_interrupt_due() {
            vector = Some(0x1a);
        }
        if vector.is_none() && self.i2c.is_interrupt_due() {
            vector = Some(0x1c);
        }
        if vector.is_none() {
            for (base, due) in [(0x30, self.gpios.b.get_interrupt_due()), (0x40, self.gpios.c.get_interrupt_due()),
                                (0x50, self.gpios.d.get_interrupt_due())] {
                if due != 0 {
                    let pin = due.trailing_zeros();
                    vector = Some(base + 2 * pin);
                    break;
                }
            }
        }
        if let Some(v) = vector {
            ev.push(KgEv::Int(v));
            cpu.state.halted = false;
            Environment::new(&mut cpu.state, &mut KgBus { m: self, ev }).interrupt(v);
        }
    }

    /// Clock cycles so far (applied ones plus the pending ones).
    pub fn kg_cycles(&self) -> u64 {
        self.total_cycles_elapsed
            .wrapping_add(self.cycle_counter.get().max(0) as u64)
    }

    pub fn kg_peek(&self, address: u32) -> u8 {
        self.kg_peek_raw(address)
    }

    /// A memory read without the side effects of peek() (it charges a cycle).
    pub fn kg_peek_raw(&self, address: u32) -> u8 {
        if let Some(a) = self.get_internal_ram_address(address) {
            self.mem_internal[a as usize]
        } else if let Some(a) = self.get_rom_address(address) {
            self.mem_rom[a as usize]
        } else if let Some(a) = self.get_external_ram_address(address) {
            self.mem_external[a as usize]
        } else {
            0xf5
        }
    }
}
