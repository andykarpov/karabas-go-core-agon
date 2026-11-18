// karabas: deterministic stepping of AgonMachine for the eZ80 RTL oracle (src/oracle).
// Built into a copy of agon-ez80-emulator as a child module of agon_machine (the Makefile adds
// `#[path] mod kg_trace;` there), so it reaches the private fields. The upstream start() runs in
// real time and lets the host serve MOS's FatFS calls (hostfs); here: no wall clock, and with
// hostfs off MOS runs its own FatFS on the SPI SD card image, as on the board.
use super::*;

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

    /// Clock cycles so far (applied ones plus the pending ones).
    pub fn kg_cycles(&self) -> u64 {
        self.total_cycles_elapsed
            .wrapping_add(self.cycle_counter.get().max(0) as u64)
    }

    pub fn kg_peek(&self, address: u32) -> u8 {
        self.peek(address)
    }
}
