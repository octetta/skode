//// Parameter metadata, bounds checking, and physical unit conversions
//// for the Pulp / Skred audio synthesizer engine.
////
//// All values correspond directly to the constraints in the C engine
//// (parts/synth-state.h, synth-types.h, and synth-delay.c).

import gleam/float
import gleam/int
import gleam/string

// ---- Formatting Helper ----

/// Format a float cleanly: whole numbers without decimal point, otherwise standard float string
/// without scientific notation (e.g. expanding 1.0e-5 into 0.00001).
pub fn format_float(f: Float) -> String {
  let t = float.truncate(f)
  case int.to_float(t) == f {
    True -> int.to_string(t)
    False -> {
      let raw = float.to_string(f)
      expand_scientific(raw)
    }
  }
}

fn expand_scientific(raw: String) -> String {
  let lower = string.lowercase(raw)
  case string.split(lower, "e") {
    [mantissa, exp_str] -> {
      let is_neg = string.starts_with(mantissa, "-")
      let pos_mantissa = case is_neg {
        True -> string.drop_start(mantissa, 1)
        False -> mantissa
      }
      let clean_exp = case string.starts_with(exp_str, "+") {
        True -> string.drop_start(exp_str, 1)
        False -> exp_str
      }
      case int.parse(clean_exp) {
        Ok(exp) -> {
          let #(whole, frac) = case string.split(pos_mantissa, ".") {
            [w, fr] -> #(w, fr)
            [w] -> #(w, "")
            _ -> #(pos_mantissa, "")
          }
          let formatted = case exp < 0 {
            True -> {
              let shift = -exp
              let whole_len = string.length(whole)
              case whole_len <= shift {
                True -> {
                  let zeros = string.repeat("0", shift - whole_len)
                  "0." <> zeros <> whole <> frac
                }
                False -> {
                  let split_pt = whole_len - shift
                  let w_part = string.slice(whole, 0, split_pt)
                  let f_part = string.slice(whole, split_pt, whole_len)
                  w_part <> "." <> f_part <> frac
                }
              }
            }
            False -> {
              let frac_len = string.length(frac)
              case frac_len <= exp {
                True -> {
                  let zeros = string.repeat("0", exp - frac_len)
                  whole <> frac <> zeros
                }
                False -> {
                  let w_part = string.slice(frac, 0, exp)
                  let f_part = string.slice(frac, exp, frac_len)
                  whole <> w_part <> "." <> f_part
                }
              }
            }
          }
          let res = case is_neg {
            True -> "-" <> formatted
            False -> formatted
          }
          trim_trailing_zeros(res)
        }
        Error(_) -> raw
      }
    }
    _ -> raw
  }
}

fn trim_trailing_zeros(s: String) -> String {
  case string.contains(s, ".") {
    False -> s
    True -> {
      let trimmed = do_trim_trailing_zeros(s)
      case string.ends_with(trimmed, ".") {
        True -> string.drop_end(trimmed, 1)
        False -> trimmed
      }
    }
  }
}

fn do_trim_trailing_zeros(s: String) -> String {
  case string.ends_with(s, "0") {
    True -> do_trim_trailing_zeros(string.drop_end(s, 1))
    False -> s
  }
}

// ---- Frequency & Pitch ----

pub const min_frequency_hz = 20.0

pub const max_frequency_hz = 20_000.0

pub const default_frequency_hz = 440.0

pub const min_midi_note = 0.0

pub const max_midi_note = 127.0

pub const default_midi_note = 60.0

pub const min_cents = -100.0

pub const max_cents = 100.0

pub type Pitch {
  Freq(hz: Float)
  Note(midi: Float, cents: Float)
}

/// Clamp frequency to the engine's audible range (20 Hz - 20,000 Hz).
pub fn clamp_frequency(hz: Float) -> Float {
  float.clamp(hz, min_frequency_hz, max_frequency_hz)
}

/// Clamp MIDI note to standard 0.0 .. 127.0 range.
pub fn clamp_midi_note(note: Float) -> Float {
  float.clamp(note, min_midi_note, max_midi_note)
}

/// Clamp cents detune to -100.0 .. +100.0.
pub fn clamp_cents(c: Float) -> Float {
  float.clamp(c, min_cents, max_cents)
}

/// Convert a MIDI note number (with cents offset) to Frequency in Hz (A4 = 440Hz = MIDI 69).
pub fn midi_to_hz(note: Float, cents: Float) -> Float {
  let effective_note = note +. { cents /. 100.0 }
  // 440.0 * 2^((note - 69) / 12)
  let exponent = { effective_note -. 69.0 } /. 12.0
  let factor = float.power(2.0, exponent)
  case factor {
    Ok(f) -> clamp_frequency(440.0 *. f)
    Error(_) -> default_frequency_hz
  }
}

// ---- Volume, Amplitude & Decibels ----

pub const min_db = -60.0

pub const max_db = 12.0

pub const silent_db = -60.0

pub const default_voice_db = 0.0

pub const default_master_volume_db = -6.0

/// Clamp decibels to engine operating range (-60 dB .. +12 dB).
pub fn clamp_db(db: Float) -> Float {
  float.clamp(db, min_db, max_db)
}

/// Convert decibels (dB) to linear amplitude multiplier (0.0 .. ~4.0).
/// Formula: 10^(db / 20)
pub fn db_to_linear(db: Float) -> Float {
  case db <=. silent_db {
    True -> 0.0
    False -> {
      case float.power(10.0, db /. 20.0) {
        Ok(lin) -> lin
        Error(_) -> 0.0
      }
    }
  }
}

/// Convert linear amplitude multiplier (> 0.0) to decibels (dB).
/// Formula: 20 * log10(lin)
pub fn linear_to_db(linear: Float) -> Float {
  case linear <=. 0.001 {
    True -> silent_db
    False -> {
      case float.logarithm(linear) {
        Ok(ln_val) -> {
          // log10(x) = ln(x) / ln(10)
          let ln10 = 2.302585092994046
          clamp_db(20.0 *. { ln_val /. ln10 })
        }
        Error(_) -> silent_db
      }
    }
  }
}

// ---- Stereo Pan ----

pub const min_pan = -1.0

pub const max_pan = 1.0

pub const center_pan = 0.0

/// Clamp stereo pan to -1.0 (hard left) .. +1.0 (hard right).
pub fn clamp_pan(p: Float) -> Float {
  float.clamp(p, min_pan, max_pan)
}

// ---- Filter Parameters ----

pub type FilterMode {
  FilterOff
  LowPass
  BandPass
  HighPass
  Notch
  AllPass
}

pub fn filter_mode_to_int(m: FilterMode) -> Int {
  case m {
    FilterOff -> 0
    LowPass -> 1
    BandPass -> 2
    HighPass -> 3
    Notch -> 4
    AllPass -> 5
  }
}

pub fn filter_mode_from_int(i: Int) -> FilterMode {
  case i {
    1 -> LowPass
    2 -> BandPass
    3 -> HighPass
    4 -> Notch
    5 -> AllPass
    _ -> FilterOff
  }
}

pub const min_resonance_q = 0.1

pub const max_resonance_q = 20.0

pub const default_resonance_q = 0.707

/// Clamp filter resonance Q factor (0.1 .. 20.0).
pub fn clamp_resonance(q: Float) -> Float {
  float.clamp(q, min_resonance_q, max_resonance_q)
}

// ---- ADSR Envelope ----

pub type Adsr {
  Adsr(
    attack: Float,
    // seconds >= 0.0
    decay: Float,
    // seconds >= 0.0
    sustain: Float,
    // level 0.0 .. 1.0
    release: Float,
    // seconds >= 0.0
  )
}

pub fn default_adsr() -> Adsr {
  Adsr(attack: 0.005, decay: 0.1, sustain: 0.7, release: 0.2)
}

pub fn clamp_adsr(adsr: Adsr) -> Adsr {
  Adsr(
    attack: float.max(0.0, adsr.attack),
    decay: float.max(0.0, adsr.decay),
    sustain: float.clamp(adsr.sustain, 0.0, 1.0),
    release: float.max(0.0, adsr.release),
  )
}

// ---- Wavetable & Oscillators ----

pub const min_wave_index = 0

pub const max_wave_index = 999

pub type WaveDirection {
  Forward
  Backward
  PingPong
}

pub fn wave_direction_to_int(d: WaveDirection) -> Int {
  case d {
    Forward -> 0
    Backward -> 1
    PingPong -> 2
  }
}

pub fn wave_direction_from_int(i: Int) -> WaveDirection {
  case i {
    1 -> Backward
    2 -> PingPong
    _ -> Forward
  }
}

// ---- Index Limits ----

pub const max_voices = 256

pub const delay_bus_count = 4

pub const max_patterns = 128

pub const max_steps = 256

pub fn clamp_voice_id(id: Int) -> Int {
  int.clamp(id, 0, max_voices - 1)
}

pub fn clamp_delay_bus_id(id: Int) -> Int {
  int.clamp(id, 1, delay_bus_count)
}

pub fn clamp_pattern_id(id: Int) -> Int {
  int.clamp(id, 0, max_patterns - 1)
}

pub fn clamp_step_id(id: Int) -> Int {
  int.clamp(id, 0, max_steps - 1)
}

// ---- Tempo / Clock ----

pub const min_bpm = 1.0

pub const max_bpm = 960.0

pub const default_bpm = 120.0

pub const default_subdivision = 16.0

pub fn clamp_bpm(bpm: Float) -> Float {
  float.clamp(bpm, min_bpm, max_bpm)
}
