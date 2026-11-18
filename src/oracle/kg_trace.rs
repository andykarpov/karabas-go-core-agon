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
        if cpu.is_halted() {
            self.cycle_counter.set(self.cycle_counter.get().wrapping_add(4));
        } else {
            cpu.fast_execute_instruction(&mut KgBus { m: self, ev });
        }
        if self.cycle_counter.get() >= self.interrupt_precision {
            self.apply_elapsed_cycles();
            self.kg_do_interrupts(cpu, ev);
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
        self.peek(address)
    }
}
