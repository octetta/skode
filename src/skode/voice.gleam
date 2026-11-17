//// Synth voice domain model, default patch initialization, and Skode serialization.
////
//// Represents a single voice (0..255) in Pulp's voice allocation table (`sv`).
//// Designed for use in the Lustre Voice Editor and across BEAM languages.

import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import skode/gen/voice_gen
import skode/param.{
  type Adsr, type FilterMode, type Pitch, type WaveDirection, AllPass, Backward,
  BandPass, FilterOff, Forward, Freq, HighPass, LowPass, Notch, Note, PingPong,
}

pub type PhaseDist {
  PhaseDist(mode: Int, distortion: Float)
}

pub type Glissando {
  Glissando(time: Float, mode: Int)
}

pub type FmConfig {
  FmConfig(mod_voice: Int, depth: Float, adder: Float, mode: Int)
}

pub type SampleHold {
  SampleHold(ratio: Float, mode: Int)
}

pub type FilterEnvelope {
  FilterEnvelope(adsr: Adsr, depth: Float)
}

pub type Oscillator {
  Oscillator(
    wave: Int,
    pitch: Pitch,
    detune_cents: Float,
    interpolate: Bool,
    one_shot: Bool,
    direction: WaveDirection,
    loop_enabled: Bool,
    loop_count: Int,
    phase_dist: Option(PhaseDist),
    sample_window: Option(#(Int, Int)),
    wave_loop: Option(#(Int, Int)),
  )
}

pub type Envelope {
  Envelope(adsr: Adsr, mode: Int, velocity: Float)
}

pub type Filter {
  Filter(
    mode: FilterMode,
    character: Int,
    cutoff_hz: Float,
    resonance_q: Float,
    envelope: Option(FilterEnvelope),
  )
}

pub type Mix {
  Mix(
    amp_db: Float,
    pan: Float,
    mute: Bool,
    record_track: Int,
    delay_send: Float,
  )
}

pub type Modulation {
  Modulation(
    glissando: Option(Glissando),
    smoother: Option(Float),
    ring_mod: Option(#(Int, Float)),
    freq_mod: Option(FmConfig),
    freq_feedback: Float,
    sample_hold: Option(SampleHold),
  )
}

pub type VoiceLinks {
  VoiceLinks(gate: List(Int), sync: List(Int), velocity: List(Int))
}

pub type Voice {
  Voice(
    id: Int,
    oscillator: Oscillator,
    envelope: Envelope,
    filter: Filter,
    mix: Mix,
    modulation: Modulation,
    links: VoiceLinks,
  )
}

/// Create a clean default voice patch at the given voice ID.
pub fn default(voice_id: Int) -> Voice {
  let v = param.clamp_voice_id(voice_id)
  Voice(
    id: v,
    oscillator: Oscillator(
      wave: 0,
      // Sine wave
      pitch: Note(midi: 60.0, cents: 0.0),
      // Middle C (C4)
      detune_cents: 0.0,
      interpolate: True,
      one_shot: False,
      direction: Forward,
      loop_enabled: True,
      loop_count: 0,
      phase_dist: None,
      sample_window: None,
      wave_loop: None,
    ),
    envelope: Envelope(adsr: param.default_adsr(), mode: 0, velocity: 1.0),
    filter: Filter(
      mode: LowPass,
      character: 0,
      cutoff_hz: 5000.0,
      resonance_q: param.default_resonance_q,
      envelope: None,
    ),
    mix: Mix(
      amp_db: param.default_voice_db,
      pan: param.center_pan,
      mute: False,
      record_track: 0,
      delay_send: 0.0,
    ),
    modulation: Modulation(
      glissando: None,
      smoother: None,
      ring_mod: None,
      freq_mod: None,
      freq_feedback: 0.0,
      sample_hold: None,
    ),
    links: VoiceLinks(gate: [], sync: [], velocity: []),
  )
}

/// Serialize a complete voice patch into canonical Skode commands.
pub fn to_skode(voice: Voice) -> String {
  let prefix = "v" <> int.to_string(voice.id)
  let osc = [
    "w" <> int.to_string(voice.oscillator.wave),
    case voice.oscillator.pitch {
      Freq(hz) -> "f" <> param.format_float(hz)
      Note(m, c) ->
        case c == 0.0 {
          True -> "n" <> param.format_float(m)
          False -> "n" <> param.format_float(m) <> "," <> param.format_float(c)
        }
    },
    case voice.oscillator.loop_enabled {
      True -> "B1"
      False -> "B0"
    },
    case voice.oscillator.direction {
      Forward -> "b0"
      Backward -> "b1"
      PingPong -> "b2"
    },
    case voice.oscillator.phase_dist {
      Some(PhaseDist(m, d)) ->
        "c" <> int.to_string(m) <> "," <> param.format_float(d)
      None -> ""
    },
  ]

  let env = [
    "t"
    <> param.format_float(voice.envelope.adsr.attack)
    <> ","
    <> param.format_float(voice.envelope.adsr.decay)
    <> ","
    <> param.format_float(voice.envelope.adsr.sustain)
    <> ","
    <> param.format_float(voice.envelope.adsr.release),
  ]

  let flt = case voice.filter.mode {
    FilterOff -> ["j0"]
    _ -> [
      "j"
        <> int.to_string(param.filter_mode_to_int(voice.filter.mode))
        <> case voice.filter.character > 0 {
        True -> " " <> int.to_string(voice.filter.character)
        False -> ""
      },
      "k" <> param.format_float(voice.filter.cutoff_hz),
      "q" <> param.format_float(voice.filter.resonance_q),
    ]
  }

  let mx = [
    "a" <> param.format_float(voice.mix.amp_db),
    "p" <> param.format_float(voice.mix.pan),
    case voice.mix.mute {
      True -> "m1"
      False -> "m0"
    },
    case voice.mix.delay_send >. 0.0 {
      True -> "ds" <> param.format_float(voice.mix.delay_send)
      False -> ""
    },
  ]

  let commands =
    list.flatten([[prefix], osc, env, flt, mx])
    |> list.filter(fn(s) { s != "" })

  string.join(commands, " ")
}

/// Compute minimal delta Skode commands when a voice's parameters change.
/// This is the reactive driver for the Lustre Voice Editor.
pub fn diff_skode(old: Voice, new: Voice) -> List(String) {
  let v_prefix = "v" <> int.to_string(new.id)
  let diffs = []

  // Oscillator diffs
  let diffs = case old.oscillator.wave != new.oscillator.wave {
    True -> ["w" <> int.to_string(new.oscillator.wave), ..diffs]
    False -> diffs
  }
  let diffs = case old.oscillator.pitch != new.oscillator.pitch {
    True ->
      case new.oscillator.pitch {
        Freq(hz) -> ["f" <> param.format_float(hz), ..diffs]
        Note(m, c) ->
          case c == 0.0 {
            True -> ["n" <> param.format_float(m), ..diffs]
            False -> [
              "n" <> param.format_float(m) <> "," <> param.format_float(c),
              ..diffs
            ]
          }
      }
    False -> diffs
  }
  let diffs = case old.oscillator.loop_enabled != new.oscillator.loop_enabled {
    True -> [
      case new.oscillator.loop_enabled {
        True -> "B1"
        False -> "B0"
      },
      ..diffs
    ]
    False -> diffs
  }
  let diffs = case old.oscillator.direction != new.oscillator.direction {
    True -> [
      case new.oscillator.direction {
        Forward -> "b0"
        Backward -> "b1"
        PingPong -> "b2"
      },
      ..diffs
    ]
    False -> diffs
  }
  let diffs = case old.oscillator.phase_dist != new.oscillator.phase_dist {
    True -> [
      case new.oscillator.phase_dist {
        Some(PhaseDist(m, d)) ->
          "c" <> int.to_string(m) <> "," <> param.format_float(d)
        None -> "c0,0"
      },
      ..diffs
    ]
    False -> diffs
  }

  // Envelope diffs
  let diffs = case old.envelope.adsr != new.envelope.adsr {
    True -> [
      "t"
        <> param.format_float(new.envelope.adsr.attack)
        <> ","
        <> param.format_float(new.envelope.adsr.decay)
        <> ","
        <> param.format_float(new.envelope.adsr.sustain)
        <> ","
        <> param.format_float(new.envelope.adsr.release),
      ..diffs
    ]
    False -> diffs
  }

  // Filter diffs
  let diffs = case
    old.filter.mode != new.filter.mode
    || old.filter.character != new.filter.character
  {
    True -> [
      "j"
        <> int.to_string(param.filter_mode_to_int(new.filter.mode))
        <> case new.filter.character > 0 {
        True -> " " <> int.to_string(new.filter.character)
        False -> ""
      },
      ..diffs
    ]
    False -> diffs
  }
  let diffs = case old.filter.cutoff_hz != new.filter.cutoff_hz {
    True -> ["k" <> param.format_float(new.filter.cutoff_hz), ..diffs]
    False -> diffs
  }
  let diffs = case old.filter.resonance_q != new.filter.resonance_q {
    True -> ["q" <> param.format_float(new.filter.resonance_q), ..diffs]
    False -> diffs
  }

  // Mix diffs
  let diffs = case old.mix.amp_db != new.mix.amp_db {
    True -> ["a" <> param.format_float(new.mix.amp_db), ..diffs]
    False -> diffs
  }
  let diffs = case old.mix.pan != new.mix.pan {
    True -> ["p" <> param.format_float(new.mix.pan), ..diffs]
    False -> diffs
  }
  let diffs = case old.mix.mute != new.mix.mute {
    True -> [
      case new.mix.mute {
        True -> "m1"
        False -> "m0"
      },
      ..diffs
    ]
    False -> diffs
  }
  let diffs = case old.mix.delay_send != new.mix.delay_send {
    True -> ["ds" <> param.format_float(new.mix.delay_send), ..diffs]
    False -> diffs
  }

  case diffs {
    [] -> []
    commands -> [v_prefix <> " " <> string.join(list.reverse(commands), " ")]
  }
}

/// Convert high-level domain Voice to raw engine-state voice_gen.Voice.
pub fn to_engine(voice: Voice) -> voice_gen.Voice {
  let base = voice_gen.default(voice.id)
  let #(f, mn, mc, pm) = case voice.oscillator.pitch {
    Freq(hz) -> #(hz, 60.0, voice.oscillator.detune_cents, 0)
    Note(m, c) -> #(param.midi_to_hz(m, c), m, c, 1)
  }
  let #(cz_m, cz_d) = case voice.oscillator.phase_dist {
    Some(PhaseDist(m, d)) -> #(m, d)
    None -> #(0, 0.0)
  }
  let #(gl_en, gl_mode, gl_time) = case voice.modulation.glissando {
    Some(Glissando(t, m)) -> #(1, m, t)
    None -> #(0, 0, 0.0)
  }
  let #(sm_en, sm_val) = case voice.modulation.smoother {
    Some(s) -> #(1, s)
    None -> #(0, 0.0)
  }
  let #(ring_o, ring_a) = case voice.modulation.ring_mod {
    Some(#(o, a)) -> #(o, a)
    None -> #(-1, 0.0)
  }
  let #(fm_o, fm_d, fm_add, fm_m) = case voice.modulation.freq_mod {
    Some(FmConfig(vo, d, a, m)) -> #(vo, d, a, m)
    None -> #(-1, 0.0, 0.0, 0)
  }
  let #(sh_r, sh_m) = case voice.modulation.sample_hold {
    Some(SampleHold(r, m)) -> #(r, m)
    None -> #(0.0, 0)
  }
  let #(f_env_use, f_env_d) = case voice.filter.envelope {
    Some(fe) -> #(1, fe.depth)
    None -> #(0, 0.0)
  }
  let dir = case voice.oscillator.direction {
    Forward -> 0
    Backward -> 1
    PingPong -> 2
  }

  voice_gen.Voice(
    ..base,
    wave_table_index: voice.oscillator.wave,
    freq: f,
    midi_note: mn,
    midi_cents: mc,
    pitch_mode: pm,
    interpolate: case voice.oscillator.interpolate {
      True -> 1
      False -> 0
    },
    one_shot: case voice.oscillator.one_shot {
      True -> 1
      False -> 0
    },
    direction: dir,
    loop_enabled: case voice.oscillator.loop_enabled {
      True -> 1
      False -> 0
    },
    loop_count: voice.oscillator.loop_count,
    filter_mode: param.filter_mode_to_int(voice.filter.mode)
      + { voice.filter.character * 10 },
    filter_freq: voice.filter.cutoff_hz,
    filter_res: voice.filter.resonance_q,
    use_filter_envelope: f_env_use,
    filter_env_depth: f_env_d,
    amp_envelope_mode: voice.envelope.mode,
    amp: voice.mix.amp_db,
    user_amp: voice.mix.amp_db,
    pan: voice.mix.pan,
    disconnect: case voice.mix.mute {
      True -> 1
      False -> 0
    },
    record: voice.mix.record_track,
    delay_send: voice.mix.delay_send,
    cz_mode: cz_m,
    cz_distortion: cz_d,
    glissando_enable: gl_en,
    glissando_mode: gl_mode,
    glissando_time: gl_time,
    smoother_enable: sm_en,
    smoother_smoothing: sm_val,
    ring_osc: ring_o,
    ring_amount: ring_a,
    freq_mod_osc: fm_o,
    freq_mod_depth: fm_d,
    freq_mod_adder: fm_add,
    freq_mod_mode: fm_m,
    freq_mod_feedback: voice.modulation.freq_feedback,
    sample_hold_ratio: sh_r,
    sample_hold_mode: sh_m,
    link_sync: list.map(voice.links.sync, int.to_float),
    link_midi: list.map(voice.links.gate, int.to_float),
    link_velo: list.map(voice.links.velocity, int.to_float),
  )
}

/// Convert raw engine-state voice_gen.Voice to high-level domain Voice.
pub fn from_engine(v: voice_gen.Voice) -> Voice {
  let pitch = case v.pitch_mode == 0 {
    True -> Freq(v.freq)
    False -> Note(v.midi_note, v.midi_cents)
  }
  let direction = case v.direction {
    1 -> Backward
    2 -> PingPong
    _ -> Forward
  }
  let phase_dist = case v.cz_mode > 0 || v.cz_distortion >. 0.0 {
    True -> Some(PhaseDist(v.cz_mode, v.cz_distortion))
    False -> None
  }
  let filter_mode = case v.filter_mode % 10 {
    0 -> FilterOff
    1 -> LowPass
    2 -> BandPass
    3 -> HighPass
    4 -> Notch
    5 -> AllPass
    _ -> LowPass
  }
  let filter_env = case v.use_filter_envelope != 0 {
    True ->
      Some(FilterEnvelope(adsr: param.default_adsr(), depth: v.filter_env_depth))
    False -> None
  }
  let glissando = case v.glissando_enable != 0 || v.glissando_time >. 0.0 {
    True -> Some(Glissando(v.glissando_time, v.glissando_mode))
    False -> None
  }
  let smoother = case v.smoother_enable != 0 || v.smoother_smoothing >. 0.0 {
    True -> Some(v.smoother_smoothing)
    False -> None
  }
  let ring_mod = case v.ring_osc >= 0 {
    True -> Some(#(v.ring_osc, v.ring_amount))
    False -> None
  }
  let freq_mod = case v.freq_mod_osc >= 0 {
    True ->
      Some(FmConfig(
        v.freq_mod_osc,
        v.freq_mod_depth,
        v.freq_mod_adder,
        v.freq_mod_mode,
      ))
    False -> None
  }
  let sample_hold = case v.sample_hold_ratio >. 0.0 || v.sample_hold_mode != 0 {
    True -> Some(SampleHold(v.sample_hold_ratio, v.sample_hold_mode))
    False -> None
  }

  Voice(
    id: v.id,
    oscillator: Oscillator(
      wave: v.wave_table_index,
      pitch: pitch,
      detune_cents: v.midi_cents,
      interpolate: v.interpolate != 0,
      one_shot: v.one_shot != 0,
      direction: direction,
      loop_enabled: v.loop_enabled != 0,
      loop_count: v.loop_count,
      phase_dist: phase_dist,
      sample_window: None,
      wave_loop: None,
    ),
    envelope: Envelope(
      adsr: param.default_adsr(),
      mode: v.amp_envelope_mode,
      velocity: 1.0,
    ),
    filter: Filter(
      mode: filter_mode,
      character: v.filter_mode / 10,
      cutoff_hz: v.filter_freq,
      resonance_q: v.filter_res,
      envelope: filter_env,
    ),
    mix: Mix(
      amp_db: v.user_amp,
      pan: v.pan,
      mute: v.disconnect != 0,
      record_track: v.record,
      delay_send: v.delay_send,
    ),
    modulation: Modulation(
      glissando: glissando,
      smoother: smoother,
      ring_mod: ring_mod,
      freq_mod: freq_mod,
      freq_feedback: v.freq_mod_feedback,
      sample_hold: sample_hold,
    ),
    links: VoiceLinks(
      gate: list.map(v.link_midi, float.truncate),
      sync: list.map(v.link_sync, float.truncate),
      velocity: list.map(v.link_velo, float.truncate),
    ),
  )
}
