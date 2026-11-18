// eZ80 oracle (Ф0.2) for the Agon core: the Agon emulator of fab-agon-emulator (agon-ez80-emulator,
// GPL-3) run deterministically with MOS from flash and the SD card on SPI (no hostfs), and a fake
// VDP in the same thread (answers the polls MOS needs, vsync on PB1 every 1/60 s of eZ80 clocks).
// Outputs: the text MOS prints (stdout), the MOS -> VDP byte stream (--vdp-out, an input for the
// VDP ISS), an instruction trace (--trace) for the lockstep check of the eZ80 RTL.
//
// usage: agon-oracle --mos mos.bin [--sd sd.img] [--ms N (emulated time, default 3000)]
//          [--keys "text" (typed after --keys-at ms, default 2000; \r = Enter)]
//          [--vdp-out file] [--trace file [--trace-from N] [--trace-n N]] [--ops file] [--hostfs]
// trace line (after the instruction at PC): n cycles PC ADL MADL MB AF BC DE HL IX IY SP I IFF1
use agon_ez80_emulator::{gpio, AgonMachine, AgonMachineConfig, RamInit, SerialLink};
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

fn main() {
    let a: Vec<String> = std::env::args().collect();
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
        m.kg_step(&mut cpu);
        n += 1;
        if let Some(t) = trace.as_mut() {
            if n > trace_from && n - trace_from <= trace_n {
                let r = &cpu.state.reg;
                writeln!(
                    t,
                    "{} {} {:06x} {} {} {:02x} {:04x} {:06x} {:06x} {:06x} {:06x} {:06x} {:06x} {:02x} {}",
                    n, m.kg_cycles(), pc, r.adl as u8, r.madl as u8, r.mbase, r.get16(Reg16::AF),
                    r.get24(Reg16::BC), r.get24(Reg16::DE), r.get24(Reg16::HL), r.get24(Reg16::IX),
                    r.get24(Reg16::IY), cpu.state.sp(), r.get8(Reg8::I), r.iff1 as u8
                )
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
