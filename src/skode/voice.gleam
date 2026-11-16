//// Synth voice domain model, default patch initialization, and Skode serialization.
////
//// Represents a single voice (0..255) in Pulp's voice allocation table (`sv`).
//// Designed for use in the Lustre Voice Editor and across BEAM languages.

import gleam/int
import gleam/list
import gleam/option.{type Option, None}
import gleam/string
import skode/param.{
  type Adsr, type FilterMode, type Pitch, type WaveDirection, Backward,
  FilterOff, Forward, Freq, LowPass, Note, PingPong,
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
    case voice.oscillator.detune_cents == 0.0 {
      True -> ""
      False -> "c" <> param.format_float(voice.oscillator.detune_cents)
    },
    case voice.oscillator.loop_enabled {
      True -> "B1"
      False -> "B0"
    },
    case voice.oscillator.direction {
      Forward -> "w0"
      Backward -> "w1"
      PingPong -> "w2"
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
      True -> "mu1"
      False -> "mu0"
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
  let diffs = case old.oscillator.detune_cents != new.oscillator.detune_cents {
    True -> ["c" <> param.format_float(new.oscillator.detune_cents), ..diffs]
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
        True -> "mu1"
        False -> "mu0"
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
