// eZ80 oracle (Ф0.2) for the Agon core: the Agon emulator of fab-agon-emulator (agon-ez80-emulator,
// GPL-3) run deterministically with MOS from flash and the SD card on SPI (no hostfs), and a fake
// VDP in the same thread (answers the polls MOS needs, vsync on PB1 every 1/60 s of eZ80 clocks).
// Outputs: the text MOS prints (stdout), the MOS -> VDP byte stream (--vdp-out, an input for the
// VDP ISS), an instruction trace (--trace) for the lockstep check of the eZ80 RTL.
//
// usage: agon-oracle --mos mos.bin [--sd sd.img] [--ms N (emulated time, default 3000)]
//          [--keys "text" (typed after --keys-at ms, default 2000; \r = Enter)]
//          [--vdp-out file] [--trace file [--trace-from N] [--trace-n N]] [--ops file] [--hostfs]
// trace line (after the instruction at PC): n cycles PC ADL MADL MB AF BC DE HL IX IY SPS SPL I IFF1 IFF2,
// then its bus events: w:ADDR=VV (memory write), r:PORT=VV / o:PORT=VV (port read / write),
// int:VV (interrupt taken after it; the entry's writes follow). Without --hostfs only.
use agon_ez80_emulator::{gpio, kg_ld_a_r_fix, kg_r_fix, AgonMachine, AgonMachineConfig, KgEv, RamInit, SerialLink};
use ez80::{Reg16, Reg8};
use std::cell::RefCell;
use std::collections::VecDeque;
use std::io::Write;
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, AtomicI32};
use std::sync::Arc;

const CLOCK_HZ: u64 = 18_432_000;

// The fake VDP: a VDU parser just deep enough to stay in step with MOS (parameter counts of the
// BBC VDU codes, VDU 23,0 system packets answered), the text to stdout.
#[derive(Default)]
struct Vdp {
    to_ez80: VecDeque<u8>,
    log: Option<std::fs::File>,
    pending: Vec<u8>, // the bytes of the VDU command being collected
}

impl Vdp {
    fn reply(&mut self, b: &[u8]) {
        self.to_ez80.extend(b.iter());
    }

    fn put(&mut self, c: u8) {
        if let Some(f) = self.log.as_mut() {
            f.write_all(&[c]).unwrap();
        }
        if self.pending.is_empty() {
            match c {
                0x20..=0x7e | 0x0a | 0x08 => {
                    print!("{}", c as char);
                    std::io::stdout().flush().unwrap();
                    return;
                }
                // codes with parameters: collect
                1 | 17 | 18 | 19 | 22 | 23 | 24 | 25 | 28 | 29 | 31 => {
                    self.pending.push(c);
                    return;
                }
                _ => return, // single-byte controls
            }
        }
        self.pending.push(c);
        let p = &self.pending;
        let need = match p[0] {
            1 | 17 | 22 => 2,
            18 | 31 => 3,
            19 => 6,
            24 => 9,
            25 => 6,
            28 | 29 => 5,
            23 => {
                if p.len() < 3 {
                    3
                } else if p[1] == 0 {
                    // VDU 23,0,cmd,...: system packets
                    match p[2] {
                        0x80 => 4, // general poll, 1 byte
                        0x86 => 3, // mode information
                        0x87 => {
                            // RTC: 0 = read, 1 = set (6 bytes)
                            if p.len() >= 4 && p[3] == 1 { 10 } else { 4 }
                        }
                        0x81 => 4, // keyboard locale
                        0x82 => 3, // cursor position
                        0x83 | 0x84 => 7,
                        0x88 => 9, // keyboard control
                        0xff => 3, // terminal mode
                        _ => 10,
                    }
                } else {
                    10 // VDU 23,n + 8 bytes
                }
            }
            _ => 1,
        };
        if p.len() < need {
            return;
        }
        let cmd = std::mem::take(&mut self.pending);
        if cmd[0] == 23 && cmd[1] == 0 {
            match cmd[2] {
                0x80 => self.reply(&[0x80, 1, cmd[3]]),
                0x86 => self.reply(&[0x86, 7, 0x80, 2, 0xe0, 1, 80, 60, 16]), // 640x480, 80x60, 16 colours
                0x87 if cmd[3] == 0 => self.reply(&[0x87, 6, 46, 10, 18, 12, 0, 0]), // RTC: fixed date
                v => eprintln!("[fake vdp: VDU 23,0,&{:02x} not answered]", v),
            }
        }
    }
}

struct Link(Rc<RefCell<Vdp>>);
impl SerialLink for Link {
    fn send(&mut self, b: u8) {
        self.0.borrow_mut().put(b);
    }
    fn recv(&mut self) -> Option<u8> {
        self.0.borrow_mut().to_ez80.pop_front()
    }
    fn read_clear_to_send(&mut self) -> bool {
        true
    }
}

struct Null;
impl SerialLink for Null {
    fn send(&mut self, _b: u8) {}
    fn recv(&mut self) -> Option<u8> {
        None
    }
    fn read_clear_to_send(&mut self) -> bool {
        true
    }
}

fn arg<T: std::str::FromStr>(a: &[String], name: &str) -> Option<T> {
    a.iter().position(|x| x == name).and_then(|i| a.get(i + 1)).and_then(|v| v.parse().ok())
}

// --z80 prog.bin: a bare Z80 (the crate's Z80 mode) with 64 KB RAM (the program at 0, the rest
// from --fill seed), ports read as (port low ^ high ^ 0x5a), no interrupts. For the testbench of
// the unmodified T80 (Ф1.1). Trace: the same columns (ADL / MADL / MB = 0, SPL = 0), the shadow
// registers and R are not in it.
struct Z80Bus {
    mem: Vec<u8>,
    ev: Vec<KgEv>,
}
impl ez80::Machine for Z80Bus {
    fn peek(&self, a: u32) -> u8 {
        self.mem[(a & 0xffff) as usize]
    }
    fn poke(&mut self, a: u32, v: u8) {
        self.ev.push(KgEv::MemW(a & 0xffff, v));
        self.mem[(a & 0xffff) as usize] = v;
    }
    fn use_cycles(&self, _c: i32) {}
    fn port_in(&mut self, p: u16) -> u8 {
        let v = (p as u8) ^ ((p >> 8) as u8) ^ 0x5a;
        self.ev.push(KgEv::IoR(p, v));
        v
    }
    fn port_out(&mut self, p: u16, v: u8) {
        self.ev.push(KgEv::IoW(p, v));
    }
}

fn ev_text(ev: &[KgEv]) -> String {
    let mut s = String::new();
    for e in ev {
        s += &match e {
            KgEv::MemW(a, v) => format!(" w:{:06x}={:02x}", a, v),
            KgEv::IoR(p, v) => format!(" r:{:04x}={:02x}", p, v),
            KgEv::IoW(p, v) => format!(" o:{:04x}={:02x}", p, v),
            KgEv::Int(v) => format!(" int:{:02x}", v),
        };
    }
    s
}

fn run_z80(a: &[String], prog: &str) {
    let n_max: u64 = arg(a, "--n").unwrap_or(100000);
    let mut seed: u64 = arg(a, "--fill").unwrap_or(1);
    let mut mem = vec![0u8; 65536];
    for b in mem.iter_mut() {
        // xorshift fill; no HALT (0x76): nothing would wake it
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        let v = (seed >> 24) as u8;
        *b = if v == 0x76 { 0 } else { v };
    }
    let p = std::fs::read(prog).expect("--z80 program");
    mem[..p.len()].copy_from_slice(&p);
    if let Some(path) = arg::<String>(a, "--mem-out") {
        std::fs::write(path, &mem).unwrap();
    }
    let mut bus = Z80Bus { mem, ev: Vec::new() };
    let mut cpu = ez80::Cpu::new_z80();
    // SP after reset is undefined on the Z80: T80 sets FFFF, the crate 0
    cpu.state.reg.set16(Reg16::SP, 0xffff);
    // AF' too (T80 FFFF, the crate 0; the shadows are private in the crate): EX AF,AF' once with
    // AF = FFFF at a scratch copy of address 0, then AF = FFFF again and PC 0
    {
        let keep = bus.mem[0];
        bus.mem[0] = 0x08;
        cpu.execute_instruction(&mut bus);
        bus.mem[0] = keep;
        bus.ev.clear();
        cpu.state.reg.set16(Reg16::AF, 0xffff);
        cpu.state.reg.set8(Reg8::R, 0);
        cpu.state.set_pc(0);
    }
    let mut out = std::io::BufWriter::new(std::fs::File::create(arg::<String>(a, "--trace").expect("--trace")).unwrap());
    for n in 1..=n_max {
        let pc = cpu.state.pc();
        bus.ev.clear();
        let r_before = cpu.state.reg.get8(Reg8::R);
        let ib = [bus.mem[(pc & 0xffff) as usize], bus.mem[((pc + 1) & 0xffff) as usize],
                  bus.mem[((pc + 2) & 0xffff) as usize], bus.mem[((pc + 3) & 0xffff) as usize]];
        cpu.execute_instruction(&mut bus);
        // R as the Z80 counts it (no suffixes on the Z80: the 40 / 49 / 52 / 5B codes are LD r,r)
        let ibz = if matches!(ib[0], 0x40 | 0x49 | 0x52 | 0x5b) { [0, 0, 0, 0] } else { ib };
        let rn = kg_r_fix(r_before, cpu.state.reg.get8(Reg8::R), ibz, false);
        cpu.state.reg.set8(Reg8::R, rn);
        kg_ld_a_r_fix(&mut cpu.state.reg, ibz, rn);
        let r = &cpu.state.reg;
        writeln!(
            out,
            "{} 0 {:06x} 0 0 00 {:04x} {:06x} {:06x} {:06x} {:06x} {:06x} {:04x} 000000 {:02x} {} {}{}",
            n, pc, r.get16(Reg16::AF), r.get16(Reg16::BC), r.get16(Reg16::DE), r.get16(Reg16::HL),
            r.get16(Reg16::IX), r.get16(Reg16::IY), r.get16(Reg16::SP), r.get8(Reg8::I),
            r.iff1 as u8, r.iff2 as u8, ev_text(&bus.ev)
        )
        .unwrap();
        if cpu.is_halted() {
            break;
        }
    }
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    if let Some(prog) = arg::<String>(&a, "--z80") {
        run_z80(&a, &prog);
        return;
    }
    let mos: String = arg(&a, "--mos").expect("--mos mos.bin");
    let ms: u64 = arg(&a, "--ms").unwrap_or(3000);
    let keys: String = arg::<String>(&a, "--keys").unwrap_or_default().replace("\\r", "\r");
    let keys_at: u64 = arg(&a, "--keys-at").unwrap_or(2000);
    let trace_from: u64 = arg(&a, "--trace-from").unwrap_or(0);
    let trace_n: u64 = arg(&a, "--trace-n").unwrap_or(u64::MAX);
    let hostfs = a.iter().any(|x| x == "--hostfs");

    let vdp = Rc::new(RefCell::new(Vdp::default()));
    if let Some(p) = arg::<String>(&a, "--vdp-out") {
        vdp.borrow_mut().log = Some(std::fs::File::create(p).unwrap());
    }
    let mut trace = arg::<String>(&a, "--trace").map(|p| std::io::BufWriter::new(std::fs::File::create(p).unwrap()));

    let gpios = Arc::new(gpio::GpioSet::new());
    let (tx_frame, _rx_frame) = std::sync::mpsc::channel();
    let mut m = AgonMachine::new(AgonMachineConfig {
        uart0_link: Box::new(Link(vdp.clone())),
        uart1_link: Box::new(Null),
        soft_reset: Arc::new(AtomicBool::new(false)),
        emulator_shutdown: Arc::new(AtomicBool::new(false)),
        exit_status: Arc::new(AtomicI32::new(0)),
        paused: Arc::new(AtomicBool::new(false)),
        clockspeed_hz: CLOCK_HZ,
        ram_init: RamInit::Zero,
        mos_bin: std::path::PathBuf::from(&mos),
        gpios: gpios.clone(),
        tx_gpio_vga_frame: tx_frame,
        interrupt_precision: 16,
        external_ram_size: 512 * 1024,
    });
    if let Some(p) = arg::<String>(&a, "--sd") {
        let f = std::fs::File::options().read(true).write(true).open(&p).expect("sd image");
        m.set_sdcard_image(Some(f));
    }
    let mut cpu = m.kg_boot(hostfs);

    let end = ms * CLOCK_HZ / 1000;
    let frame = CLOCK_HZ / 60;
    let mut next_vsync = frame;
    let key_gap = CLOCK_HZ / 50; // 20 ms per key press / release
    let mut next_key = keys_at * CLOCK_HZ / 1000;
    let mut key_events: VecDeque<(u8, u8)> = keys.bytes().flat_map(|k| [(k, 1u8), (k, 0u8)]).collect();
    // --ops file: opcode histogram (size prefix, DD/FD, CB/ED, opcode; ADL or Z80 mode)
    let ops_path = arg::<String>(&a, "--ops");
    let mut ops: std::collections::HashMap<String, u64> = std::collections::HashMap::new();
    let mut n: u64 = 0;
    let mut ev: Vec<KgEv> = Vec::new();
    while m.kg_cycles() < end {
        let pc = cpu.state.pc();
        if ops_path.is_some() && !cpu.is_halted() {
            let b = |i: u32| m.kg_peek(pc.wrapping_add(i));
            let mut k = String::from(if cpu.state.reg.adl { "ADL " } else { "Z80 " });
            let mut i = 0;
            match b(0) {
                0x40 => { k += ".SIS "; i = 1; }
                0x49 => { k += ".LIS "; i = 1; }
                0x52 => { k += ".SIL "; i = 1; }
                0x5b => { k += ".LIL "; i = 1; }
                _ => {}
            }
            let op = b(i);
            k += &match op {
                0xdd | 0xfd => {
                    if b(i + 1) == 0xcb { format!("{:02X} CB d {:02X}", op, b(i + 3)) } else { format!("{:02X} {:02X}", op, b(i + 1)) }
                }
                0xcb | 0xed => format!("{:02X} {:02X}", op, b(i + 1)),
                _ => format!("{:02X}", op),
            };
            *ops.entry(k).or_insert(0) += 1;
        }
        if hostfs {
            m.kg_step(&mut cpu);
        } else {
            m.kg_step_logged(&mut cpu, &mut ev);
        }
        n += 1;
        if let Some(t) = trace.as_mut() {
            if n > trace_from && n - trace_from <= trace_n {
                let r = &cpu.state.reg;
                let mut line = format!(
                    "{} {} {:06x} {} {} {:02x} {:04x} {:06x} {:06x} {:06x} {:06x} {:06x} {:02x}{:02x} {:02x}{:02x}{:02x} {:02x} {} {}",
                    n, m.kg_cycles(), pc, r.adl as u8, r.madl as u8, r.mbase, r.get16(Reg16::AF),
                    r.get24(Reg16::BC), r.get24(Reg16::DE), r.get24(Reg16::HL), r.get24(Reg16::IX),
                    r.get24(Reg16::IY), r.get8(Reg8::SPSH), r.get8(Reg8::SPSL), r.get8(Reg8::SPLU),
                    r.get8(Reg8::SPLH), r.get8(Reg8::SPLL), r.get8(Reg8::I), r.iff1 as u8, r.iff2 as u8
                );
                for e in &ev {
                    line += &match e {
                        KgEv::MemW(a, v) => format!(" w:{:06x}={:02x}", a, v),
                        KgEv::IoR(p, v) => format!(" r:{:04x}={:02x}", p, v),
                        KgEv::IoW(p, v) => format!(" o:{:04x}={:02x}", p, v),
                        KgEv::Int(v) => format!(" int:{:02x}", v),
                    };
                }
                writeln!(t, "{}", line)
                .unwrap();
            }
        }
        let c = m.kg_cycles();
        if c >= next_vsync {
            gpios.b.set_input_pin(1, true);
            gpios.b.set_input_pin(1, false);
            next_vsync += frame;
        }
        if c >= next_key {
            if let Some((k, down)) = key_events.pop_front() {
                // keyboard packet: 0x81, 4, ascii, modifiers, vkey, down
                vdp.borrow_mut().reply(&[0x81, 4, k, 0, 0, down]);
            }
            next_key += key_gap;
        }
    }
    if let Some(p) = ops_path {
        let mut v: Vec<_> = ops.into_iter().collect();
        v.sort_by(|x, y| y.1.cmp(&x.1).then(x.0.cmp(&y.0)));
        let mut f = std::fs::File::create(p).unwrap();
        for (k, c) in v {
            writeln!(f, "{:10} {}", c, k).unwrap();
        }
    }
    println!();
    eprintln!("oracle: {} instructions, {} cycles, pc {:06x}", n, m.kg_cycles(), cpu.state.pc());
}
