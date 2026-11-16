//// Delay bus domain model and Skode serialization for Pulp's 4 delay lines.
////
//// Mirrors `delay_bus_t` in `parts/synth-internal.h` and the opcode handlers
//// in `parts/synth-delay.c`.

import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import skode/param

pub type DelayGrit {
  /// Full 32-bit floating point precision (no bit reduction)
  NativeFloat
  /// Quantized bit depth (1..16 bits, default is 12-bit)
  Quantized(bits: Int)
}

pub type DelayBus {
  DelayBus(
    id: Int,
    // 1 .. 4
    coarse: Int,
    // 0 .. 7 (base time bucket: 8ms * 2^coarse)
    fine: Int,
    // 0 .. 15 (fine multiplier factor 0.5..1.0)
    feedback: Int,
    // 0 .. 15 (feedback gain 0.0 .. 0.82)
    mod_freq: Int,
    // 0 .. 31 (LFO modulation rate 0.0 .. 10.0 Hz)
    mod_depth: Int,
    // 0 .. 31 (LFO modulation depth)
    level: Int,
    // 0 .. 15 (wet mix output level)
    damping: Int,
    // 0 .. 15 (lowpass damping)
    highpass: Int,
    // 0 .. 15 (highpass filter)
    pingpong: Bool,
    // cross-channel stereo feedback
    freeze: Bool,
    // infinite repeat toggle
    grit: DelayGrit,
    // bit depth quantizer
    sync: Option(#(Float, Float)),
    // beat sync (bpm, division)
  )
}

/// Create a default delay bus configuration.
pub fn default(bus_id: Int) -> DelayBus {
  DelayBus(
    id: param.clamp_delay_bus_id(bus_id),
    coarse: 4,
    // ~256ms base
    fine: 15,
    // full factor (1.0)
    feedback: 8,
    // ~50% feedback
    mod_freq: 0,
    mod_depth: 0,
    level: 10,
    // moderate wet level
    damping: 2,
    highpass: 0,
    pingpong: False,
    freeze: False,
    grit: Quantized(12),
    sync: None,
  )
}

/// Calculate base delay time in milliseconds from coarse and fine parameters.
/// Formula from `parts/synth-delay.c`:
/// base_ms = 8.0 * (1 << coarse) * (0.5 + (fine / 15.0) * 0.5)
pub fn delay_time_ms(coarse: Int, fine: Int) -> Float {
  let c = int.clamp(coarse, 0, 7)
  let f = int.clamp(fine, 0, 15)
  let shift_factor = case c {
    0 -> 1.0
    1 -> 2.0
    2 -> 4.0
    3 -> 8.0
    4 -> 16.0
    5 -> 32.0
    6 -> 64.0
    _ -> 128.0
  }
  let base_ms = 8.0 *. shift_factor
  let fine_factor = 0.5 +. { { int.to_float(f) /. 15.0 } *. 0.5 }
  base_ms *. fine_factor
}

/// Calculate feedback linear gain from the feedback parameter (0..15).
/// Formula: (feedback / 15.0) * 0.82
pub fn feedback_gain(feedback: Int) -> Float {
  let fb = int.clamp(feedback, 0, 15)
  { int.to_float(fb) /. 15.0 } *. 0.82
}

/// Calculate modulation LFO rate in Hz from mod_freq (0..31).
/// Formula: (mod_freq / 31.0) * 10.0 Hz
pub fn mod_lfo_hz(mod_freq: Int) -> Float {
  let mf = int.clamp(mod_freq, 0, 31)
  { int.to_float(mf) /. 31.0 } *. 10.0
}

/// Serialize a DelayBus into full canonical Skode script.
pub fn to_skode(bus: DelayBus) -> String {
  let b = int.to_string(bus.id)
  let dl =
    "DL "
    <> b
    <> " "
    <> int.to_string(bus.coarse)
    <> " "
    <> int.to_string(bus.fine)
    <> " "
    <> int.to_string(bus.feedback)
    <> " "
    <> int.to_string(bus.mod_freq)
    <> " "
    <> int.to_string(bus.mod_depth)
    <> " "
    <> int.to_string(bus.level)
  let dd =
    "DD "
    <> b
    <> " "
    <> int.to_string(bus.damping)
    <> " "
    <> int.to_string(bus.highpass)
  let df =
    "DF "
    <> b
    <> " "
    <> case bus.freeze {
      True -> "1"
      False -> "0"
    }
  let dp =
    "DP "
    <> b
    <> " "
    <> case bus.pingpong {
      True -> "1"
      False -> "0"
    }
  let dg = case bus.grit {
    NativeFloat -> "DG " <> b <> " 0 1"
    Quantized(bits) -> "DG " <> b <> " " <> int.to_string(bits) <> " 0"
  }
  let ds = case bus.sync {
    Some(#(bpm, div)) ->
      "DS " <> b <> " " <> float.to_string(bpm) <> " " <> float.to_string(div)
    None -> ""
  }
  let parts = list.filter([dl, dd, df, dp, dg, ds], fn(s) { s != "" })
  string.join(parts, "\n")
}

/// Compute minimal delta Skode commands when a DelayBus changes.
/// Ideal for real-time Lustre UI slider tweaking.
pub fn diff_skode(old: DelayBus, new: DelayBus) -> List(String) {
  let b = int.to_string(new.id)
  let params_changed =
    old.coarse != new.coarse
    || old.fine != new.fine
    || old.feedback != new.feedback
    || old.mod_freq != new.mod_freq
    || old.mod_depth != new.mod_depth
    || old.level != new.level

  let dl_diff = case params_changed {
    True -> [
      "DL "
      <> b
      <> " "
      <> int.to_string(new.coarse)
      <> " "
      <> int.to_string(new.fine)
      <> " "
      <> int.to_string(new.feedback)
      <> " "
      <> int.to_string(new.mod_freq)
      <> " "
      <> int.to_string(new.mod_depth)
      <> " "
      <> int.to_string(new.level),
    ]
    False -> []
  }

  let dd_diff = case
    old.damping != new.damping || old.highpass != new.highpass
  {
    True -> [
      "DD "
      <> b
      <> " "
      <> int.to_string(new.damping)
      <> " "
      <> int.to_string(new.highpass),
    ]
    False -> []
  }

  let df_diff = case old.freeze != new.freeze {
    True -> [
      "DF "
      <> b
      <> " "
      <> case new.freeze {
        True -> "1"
        False -> "0"
      },
    ]
    False -> []
  }

  let dp_diff = case old.pingpong != new.pingpong {
    True -> [
      "DP "
      <> b
      <> " "
      <> case new.pingpong {
        True -> "1"
        False -> "0"
      },
    ]
    False -> []
  }

  let dg_diff = case old.grit != new.grit {
    True -> [
      case new.grit {
        NativeFloat -> "DG " <> b <> " 0 1"
        Quantized(bits) -> "DG " <> b <> " " <> int.to_string(bits) <> " 0"
      },
    ]
    False -> []
  }

  let ds_diff = case old.sync != new.sync {
    True ->
      case new.sync {
        Some(#(bpm, div)) -> [
          "DS "
          <> b
          <> " "
          <> float.to_string(bpm)
          <> " "
          <> float.to_string(div),
        ]
        None -> []
      }
    False -> []
  }

  list.flatten([dl_diff, dd_diff, df_diff, dp_diff, dg_diff, ds_diff])
}
