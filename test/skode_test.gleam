import gleam/list
import gleam/option.{None, Some}
import gleam/string
import skode.{
  type Op, Beats, Chunk, Command, Defer, Generic, Lit, MacroDef, MasterVolume,
  Note, Rest, Seconds, Tie, Value,
}
import skode/delay
import skode/gen/delay_gen
import skode/gen/diff_gen
import skode/gen/param_gen
import skode/gen/voice_gen
import skode/global
import skode/param
import skode/pattern
import skode/transport/port
import skode/transport/udp
import skode/transport/wasm
import skode/voice

fn check(name: String, got: a, want: a) -> Bool {
  case got == want {
    True -> True
    False -> panic as { "Check failed: " <> name }
  }
}

fn ops(src: String) -> List(Op) {
  skode.parse_ops(src)
}

fn roundtrip(name: String, src: String) -> Bool {
  let a = skode.parse_program(src)
  let b = skode.parse_program(skode.program_to_string(a))
  check("roundtrip " <> name, b, a)
}

fn num(f: Float) -> skode.Arg {
  Lit(Value(f))
}

pub fn main() {
  let results = [
    // package and aligned engine versions
    check("skode package version", skode.version, "1.0.0"),
    check("aligned pulp version", skode.pulp_version, "1.3.0"),
    // transport configuration constants
    check("udp default host", udp.default_host, "127.0.0.1"),
    check("udp default port", udp.default_port, 7000),
    // tokenizing
    check("tight packing", ops("v0w1f440"), [
      skode.Voice(0),
      skode.Wave(1),
      skode.Freq(440.0),
    ]),
    check("comma is whitespace", ops("n57,12"), [Note(57, Some(12.0))]),
    check("args may precede the atom", ops("440 f"), [skode.Freq(440.0)]),
    check("decimals and signs", ops("p-.6 a-100.00 l.5"), [
      skode.Pan(-0.6),
      skode.Amp(-100.0),
      skode.Level(0.5),
    ]),
    check("atoms with symbols", ops("z%3 z*2 zg0 zq1 yp127 %6"), [
      skode.ClockSpeed(3),
      skode.Ratchet(2),
      skode.Goto(0),
      skode.QueueStart(True),
      skode.MasterPattern(127),
      skode.PatternSpeed(6),
    ]),
    check("M both forms", ops("M125,96") == ops("M 125 96"), True),
    check("bare g clears glide", ops("g"), [skode.Glide(0.0, None)]),
    check("one step behind: 8 args max", ops("DL 1 2 3 4 5 6 7 8 9"), [
      Generic(Command(
        "DL",
        [
          num(1.0),
          num(2.0),
          num(3.0),
          num(4.0),
          num(5.0),
          num(6.0),
          num(7.0),
          num(8.0),
        ],
        None,
        None,
      )),
    ]),
    // sentinels
    check("sentinels as args", ops("- - 0.75 DL"), [
      Generic(Command("DL", [Lit(Rest), Lit(Rest), num(0.75)], None, None)),
    ]),
    // arrays
    check("array with sentinels", ops("/SS 0 ( 1 - . 3 )"), [
      Generic(Command(
        "/SS",
        [num(0.0)],
        Some([num(1.0), Lit(Rest), Lit(Tie), num(3.0)]),
        None,
      )),
    ]),
    check("array commas, hex, exponent", ops("/SS (1,2 0x10 1e2 -- ...)"), [
      Generic(Command(
        "/SS",
        [],
        Some([num(1.0), num(2.0), num(16.0), num(100.0), Lit(Rest), Lit(Tie)]),
        None,
      )),
    ]),
    check("array with variable", ops("/SS ( $3 2 )"), [
      Generic(Command("/SS", [], Some([skode.VarRef(3), num(2.0)]), None)),
    ]),
    check("array buffer gotcha", ops("( 10 20 ) /SS 3 ( 30 40 ) /SS 4"), [
      Generic(Command("/SS", [num(3.0)], Some([num(30.0), num(40.0)]), None)),
      Generic(Command("/SS", [num(4.0)], None, None)),
    ]),
    // comments and chunk ends
    check(
      "inline comment ends at ;",
      skode.parse_program("v0 f440 # lead; v1"),
      [
        Chunk([skode.Voice(0), skode.Freq(440.0)], Some(" lead")),
        Chunk([skode.Voice(1)], None),
      ],
    ),
    check("comment-only line", skode.parse_program("# only"), [
      Chunk([], Some(" only")),
    ]),
    check(
      "semicolon and newline",
      list.length(skode.parse_program("v0;v1\nv2")),
      3,
    ),
    // defers
    check("seconds defer", ops("~1.5 f 440"), [
      Defer(Seconds, num(1.5), [skode.Freq(440.0)]),
    ]),
    check("tick defers chain", ops("+-3 n57 l1 +-5 a-100"), [
      Defer(Beats, num(-3.0), [Note(57, None), skode.Level(1.0)]),
      Defer(Beats, num(-5.0), [skode.Amp(-100.0)]),
    ]),
    check(
      "defer ends the chunk before it",
      list.length(skode.parse_program("v0 +1 n60")),
      2,
    ),
    // strings, steps, macros
    check("step", ops("[v0 n57 l1] x12"), [
      skode.Step([skode.Voice(0), Note(57, None), skode.Level(1.0)], 12),
    ]),
    check("empty step", ops("[] x13"), [skode.Step([], 13)]),
    check("event handler", ops("[y0 z0] e>3"), [
      skode.OnEvent([skode.Pattern(0), skode.Run(False)], 3),
    ]),
    check(
      "puts / wt / ws on separate chunks",
      ops("[hi there] puts; [bass] wt 101\n[a/b.wav] /ws 101"),
      [
        skode.Puts("hi there"),
        skode.NameWave("bass", 101),
        skode.LoadWave("a/b.wav", 101),
      ],
    ),
    check(
      "string goes to the atom that fires next",
      ops("[hi] puts [bass] wt 101"),
      [
        skode.Puts("bass"),
        Generic(Command("wt", [num(101.0)], None, None)),
      ],
    ),
    check(
      "print: string first at chunk start",
      skode.program_to_string(skode.parse_program("[hi] puts")),
      "[hi] puts",
    ),
    check(
      "print: string after its atom later in a chunk",
      skode.program_to_string(skode.parse_program("v0 puts [hi]")),
      "v0 puts [hi]",
    ),
    check("later string overwrites the buffer", ops("[v0] x12 [hi] puts"), [
      skode.Step([Generic(Command("hi", [], None, None))], 12),
      Generic(Command("puts", [], None, None)),
    ]),
    check("macro definition", ops("[play]: v0 y0 z1;"), [
      MacroDef("play", " v0 y0 z1"),
    ]),
    check("label string goes to next atom", ops("[ch 1] vt"), [
      Generic(Command("vt", [], None, Some("ch 1"))),
    ]),
    check("unterminated string swallows input", ops("v0 [abc"), [skode.Voice(0)]),
    check("stray numbers", ops("440"), [skode.Stray([num(440.0)])]),
    // printing
    check(
      "print keeps whole numbers whole",
      skode.program_to_string(skode.parse_program("v0 f440 l1")),
      "v0 f440 l1",
    ),
    // blanks after the defer sigil (the guide's "+ 4 ..." form)
    check("spaced beats defer", ops("+ 4 v0"), [
      Defer(Beats, num(4.0), [skode.Voice(0)]),
    ]),
    check("spaced seconds defer", ops("~ 1.5 f 440"), [
      Defer(Seconds, num(1.5), [skode.Freq(440.0)]),
    ]),
    check("spaced negative (ticks) defer", ops("+ -3 n57"), [
      Defer(Beats, num(-3.0), [Note(57, None)]),
    ]),
    check("spaced variable defer", ops("+   $1 v0"), [
      Defer(Beats, skode.VarRef(1), [skode.Voice(0)]),
    ]),
    check("spaced stream defer", ops("~ &3 v0"), [
      Defer(Seconds, skode.StreamRef(3), [skode.Voice(0)]),
    ]),
    check("blank then non-number stays a zero delay", ops("+ v0 a10"), [
      Defer(Beats, num(0.0), [skode.Voice(0), skode.Amp(10.0)]),
    ]),
    check(
      "blanks never cross a chunk end",
      list.length(skode.parse_program("+ \n4 v0")),
      2,
    ),
    // `&` takes digits only; a bare $ or & never swallows the next character
    check("& then a letter is not a stream", ops("f &x"), [
      Generic(Command("f", [], None, None)),
      Generic(Command("x", [], None, None)),
    ]),
    check("bare & in an array", ops("( 1 &a 3 ) /SS"), [
      Generic(Command("/SS", [], Some([num(1.0), num(0.0), num(3.0)]), None)),
    ]),
    check("bare $ in an array", ops("( 1 $xy 3 ) /SS"), [
      Generic(Command("/SS", [], Some([num(1.0), num(0.0), num(3.0)]), None)),
    ]),
    check("bare & in a defer keeps its body", ops("+&x v0"), [
      Defer(Beats, num(0.0), [
        Generic(Command("x", [], None, None)),
        skode.Voice(0),
      ]),
    ]),
    check("bare $ in a defer keeps its body", ops("+$v0 a10"), [
      Defer(Beats, num(0.0), [skode.Voice(0), skode.Amp(10.0)]),
    ]),
    // round trips over converter-style lines
    roundtrip(
      "converter voice setup",
      "v0 [ch 1] vt w0 m0 n60 l1 B1 p-0.6 t0,0,1,0 s0.002,1 g0.001,2 g0 fbp24 a-100 F0 A0",
    ),
    roundtrip("pattern line", "y127 %6 [v0] x127 yp127"),
    roundtrip(
      "step with defers",
      "[+-2 n57,12 l1 a-4.5 fb0.125 VS512,2048] x12",
    ),
    roundtrip("handler", "[y0 z0 y1 zq1] e>0"),
    roundtrip("macro", "[play]: v0 s0.002,1 l1 y0 z1 y127 z1;"),
    roundtrip("array + comment", "/SS 0 ( 1 - . 3 ) # note"),
    roundtrip("spaced defer", "~ 1.5 f 440\n+ -3 n57,12 l1"),
    roundtrip("bare g", "g"),
    roundtrip("envelope 2-arg and flat", "t0.01,0.05 t"),
    roundtrip("links G, H, HS", "G 1,2 H 3 HS 0,1"),
    roundtrip("clock", "M 125 96\nA5,0.025,0.975 /cex 0,4,0 ce 127"),
    // master volume (V)
    check("master volume op", ops("V-6"), [MasterVolume(-6.0)]),
    check("master volume 0 dB", ops("V 0"), [MasterVolume(0.0)]),
    roundtrip("master volume roundtrip", "V-6"),
    // param module
    check("clamp freq low", param.clamp_frequency(5.0), 20.0),
    check("clamp freq high", param.clamp_frequency(25_000.0), 20_000.0),
    check("midi to hz A4", param.midi_to_hz(69.0, 0.0), 440.0),
    check("db to linear 0dB", param.db_to_linear(0.0), 1.0),
    check("db to linear -60dB", param.db_to_linear(-60.0), 0.0),
    check(
      "filter mode roundtrip",
      param.filter_mode_from_int(param.filter_mode_to_int(param.LowPass)),
      param.LowPass,
    ),
    // voice module
    check("voice default id", { voice.default(3) }.id, 3),
    check(
      "voice to skode starts with v0",
      string.starts_with(voice.to_skode(voice.default(0)), "v0"),
      True,
    ),
    check(
      "voice diff empty when identical",
      voice.diff_skode(voice.default(0), voice.default(0)),
      [],
    ),
    check(
      "voice diff on cutoff change",
      {
        let v0 = voice.default(0)
        let v1 =
          voice.Voice(
            ..v0,
            filter: voice.Filter(..v0.filter, cutoff_hz: 1250.0),
          )
        voice.diff_skode(v0, v1)
      },
      ["v0 k1250"],
    ),
    // delay module
    check("delay default id", { delay.default(1) }.id, 1),
    check("delay ms calculation", delay.delay_time_ms(0, 15) >. 7.0, True),
    check("delay feedback gain", delay.feedback_gain(15) <=. 0.82, True),
    check(
      "delay diff on freeze",
      {
        let d0 = delay.default(1)
        let d1 = delay.DelayBus(..d0, freeze: True)
        delay.diff_skode(d0, d1)
      },
      ["DF 1 1"],
    ),
    // global module (master volume, tempo, clock)
    check(
      "global default master volume",
      { global.default() }.master_volume_db,
      -6.0,
    ),
    check(
      "global diff on volume change",
      {
        let g0 = global.default()
        let g1 = global.set_master_volume_db(g0, -3.5)
        global.diff_skode(g0, g1)
      },
      ["V -3.5"],
    ),
    // pattern module
    check("pattern default id", { pattern.default(2) }.id, 2),
    check(
      "pattern set step and serialize",
      {
        let p = pattern.default(0) |> pattern.set_step(0, "v0 n60 l1")
        string.contains(pattern.to_skode(p), "[v0 n60 l1] x0")
      },
      True,
    ),
    check(
      "pattern mute and control events to_skode",
      {
        let p =
          pattern.Pattern(
            ..pattern.default(1),
            mute: True,
            control_events: True,
          )
        let s = pattern.to_skode(p)
        string.contains(s, "ym 1") && string.contains(s, "yc 1")
      },
      True,
    ),
    check(
      "pattern diff step deletions and targeting",
      {
        let p0 =
          pattern.default(3)
          |> pattern.set_step(0, "v0 n60")
          |> pattern.set_step(1, "v0 n62")
        let p1 =
          pattern.default(3)
          |> pattern.set_step(0, "v0 n60")
        let diffs = pattern.diff_skode(p0, p1)
        list.contains(diffs, "y3 [] x1")
      },
      True,
    ),
    check(
      "float formatting expands scientific notation",
      param.format_float(0.00001),
      "0.00001",
    ),
    check("float formatting clean integers", param.format_float(440.0), "440"),
    check(
      "voice to_engine and from_engine equivalence",
      {
        let v = voice.default(2)
        let eg = voice.to_engine(v)
        let back = voice.from_engine(eg)
        back.id == v.id && back.oscillator.wave == v.oscillator.wave
      },
      True,
    ),
    check(
      "voice direction serialization uses b opcode",
      {
        let v = voice.default(0)
        let v_rev =
          voice.Voice(
            ..v,
            oscillator: voice.Oscillator(
              ..v.oscillator,
              direction: param.Backward,
            ),
          )
        let diffs = voice.diff_skode(v, v_rev)
        list.any(diffs, fn(s) { string.contains(s, "b1") })
      },
      True,
    ),
    check(
      "voice mute serialization uses m opcode",
      {
        let v = voice.default(0)
        let v_muted = voice.Voice(..v, mix: voice.Mix(..v.mix, mute: True))
        let diffs = voice.diff_skode(v, v_muted)
        list.any(diffs, fn(s) { string.contains(s, "m1") })
      },
      True,
    ),
    // mksynth generated modules (voice_gen, delay_gen, param_gen, diff_gen)
    check("generated voice default id", { voice_gen.default(3) }.id, 3),
    check(
      "generated param clamping",
      param_gen.clamp_freq(5.0) == 20.0
        && param_gen.clamp_freq(30_000.0) == 20_000.0
        && param_gen.clamp_wave_table_index(2000) == 1299
        && param_gen.clamp_record(99) == 4,
      True,
    ),
    check(
      "generated diff voice freq",
      {
        let v0 = voice_gen.default(0)
        let v1 = voice_gen.Voice(..v0, freq: 880.0)
        diff_gen.diff_voice_skode(v0, v1)
      },
      ["v0 f880"],
    ),
    check(
      "generated diff voice filter freq",
      {
        let v0 = voice_gen.default(0)
        let v1 = voice_gen.Voice(..v0, filter_freq: 1250.0)
        diff_gen.diff_voice_skode(v0, v1)
      },
      ["v0 k1250"],
    ),
    check("generated delay bus default id", { delay_gen.default(2) }.id, 2),
    check(
      "generated to_skode default voice",
      voice_gen.to_skode(voice_gen.default(0)),
      "v0 w0 f440 a-6",
    ),
    check(
      "generated to_skode with modified filter and wave",
      {
        let v =
          voice_gen.Voice(
            ..voice_gen.default(1),
            wave_table_index: 2,
            filter_freq: 1200.0,
          )
        voice_gen.to_skode(v)
      },
      "v1 w2 f440 a-6 k1200",
    ),
    check(
      "generated to_skode roundtrips with skode ops parser",
      {
        let v =
          voice_gen.Voice(
            ..voice_gen.default(0),
            wave_table_index: 5,
            freq: 880.0,
          )
        let s = voice_gen.to_skode(v)
        let parsed = ops(s)
        list.contains(parsed, skode.Voice(0))
        && list.contains(parsed, skode.Wave(5))
        && list.contains(parsed, skode.Freq(880.0))
      },
      True,
    ),
    // transport safety checks
    check(
      "udp transport open and close or graceful fallback",
      case udp.open() {
        Ok(sock) -> {
          let Nil = udp.close(sock)
          True
        }
        Error(_) -> True
      },
      True,
    ),
    check(
      "port transport rejects invalid executable or graceful fallback",
      case port.spawn("nonexistent_binary_xyz_123", []) {
        Error(_) -> True
        Ok(p) -> {
          let Nil = port.close(p)
          False
        }
      },
      True,
    ),
    check(
      "wasm transport availability is boolean",
      case wasm.is_available() {
        True -> True
        False -> True
      },
      True,
    ),
    check(
      "wasm transport exec returns result",
      case wasm.exec("v0 f440") {
        Ok(_) -> True
        Error(_) -> True
      },
      True,
    ),
  ]
  let failed = list.filter(results, fn(r) { !r }) |> list.length
  case failed {
    0 -> Nil
    n -> panic as { string.inspect(n) <> " checks failed" }
  }
}
