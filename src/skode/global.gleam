//// Global synthesizer engine settings, master volume (V), clock, and FX buses.
////
//// Maps to process-wide state in `parts/synth.c`, `parts/synth-state.h`, and `parts/seq.c`.

import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import skode/delay.{type DelayBus}
import skode/param

pub type EngineSettings {
  EngineSettings(
    /// Master output volume in dB (-60.0 .. 12.0, default -6.0 dB). Sets `V <db>`.
    master_volume_db: Float,
    /// Master tempo in BPM (1.0 .. 960.0, default 120.0). Sets `M <bpm> <subdivision>`.
    tempo_bpm: Float,
    /// Clock subdivision (default 16.0). Sets second arg of `M`.
    subdivision: Float,
    /// Master downbeat reference pattern (0..127 or None). Sets `yp <id>`.
    master_pattern: Option(Int),
    /// Delay lines 1..4
    delay_buses: List(DelayBus),
  )
}

/// Default engine settings (master volume = -6.0 dB, 120 BPM, 4 default delay lines).
pub fn default() -> EngineSettings {
  EngineSettings(
    master_volume_db: param.default_master_volume_db,
    tempo_bpm: param.default_bpm,
    subdivision: param.default_subdivision,
    master_pattern: Some(0),
    delay_buses: [
      delay.default(1),
      delay.default(2),
      delay.default(3),
      delay.default(4),
    ],
  )
}

/// Master volume linear amplitude factor (0.0 to ~4.0, with 1.0 at 0 dB).
pub fn master_volume_linear(settings: EngineSettings) -> Float {
  param.db_to_linear(settings.master_volume_db)
}

/// Set master volume in dB with clamping.
pub fn set_master_volume_db(
  settings: EngineSettings,
  db: Float,
) -> EngineSettings {
  EngineSettings(..settings, master_volume_db: param.clamp_db(db))
}

/// Set master volume as a linear multiplier (0.0 .. 1.0+), converted to dB.
pub fn set_master_volume_linear(
  settings: EngineSettings,
  linear: Float,
) -> EngineSettings {
  let db = param.linear_to_db(linear)
  EngineSettings(..settings, master_volume_db: db)
}

/// Set master tempo with clamping.
pub fn set_tempo(
  settings: EngineSettings,
  bpm: Float,
  subdivision: Float,
) -> EngineSettings {
  EngineSettings(
    ..settings,
    tempo_bpm: param.clamp_bpm(bpm),
    subdivision: float.max(1.0, subdivision),
  )
}

/// Update a specific delay bus in the engine settings.
pub fn update_delay_bus(
  settings: EngineSettings,
  bus_id: Int,
  updater: fn(DelayBus) -> DelayBus,
) -> EngineSettings {
  let updated_buses =
    list.map(settings.delay_buses, fn(b) {
      case b.id == bus_id {
        True -> updater(b)
        False -> b
      }
    })
  EngineSettings(..settings, delay_buses: updated_buses)
}

/// Serialize all engine global settings into full canonical Skode script.
pub fn to_skode(settings: EngineSettings) -> String {
  let vol = "V " <> param.format_float(settings.master_volume_db)
  let tempo =
    "M "
    <> param.format_float(settings.tempo_bpm)
    <> " "
    <> param.format_float(settings.subdivision)
  let mp = case settings.master_pattern {
    Some(p) -> "yp" <> int.to_string(p)
    None -> "yp-1"
  }
  let delays = list.map(settings.delay_buses, delay.to_skode)
  let lines = list.flatten([[vol, tempo, mp], delays])
  string.join(lines, "\n")
}

/// Compute minimal delta Skode commands when global settings change.
/// Dragging the Master Volume slider produces solely `["V -3.5"]`.
pub fn diff_skode(old: EngineSettings, new: EngineSettings) -> List(String) {
  let vol_diff = case old.master_volume_db != new.master_volume_db {
    True -> ["V " <> param.format_float(new.master_volume_db)]
    False -> []
  }

  let tempo_diff = case
    old.tempo_bpm != new.tempo_bpm || old.subdivision != new.subdivision
  {
    True -> [
      "M "
      <> param.format_float(new.tempo_bpm)
      <> " "
      <> param.format_float(new.subdivision),
    ]
    False -> []
  }

  let mp_diff = case old.master_pattern != new.master_pattern {
    True ->
      case new.master_pattern {
        Some(p) -> ["yp" <> int.to_string(p)]
        None -> ["yp-1"]
      }
    False -> []
  }

  let delay_diffs =
    list.zip(old.delay_buses, new.delay_buses)
    |> list.flat_map(fn(pair) { delay.diff_skode(pair.0, pair.1) })

  list.flatten([vol_diff, tempo_diff, mp_diff, delay_diffs])
}
