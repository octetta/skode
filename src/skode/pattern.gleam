//// Sequencer pattern settings and step programming for Pulp's pattern engine.
////
//// Mirrors `parts/seq.h` and the pattern opcode family (y, %, z, zq, zmu, x).

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/string
import skode/param

pub type Step {
  Step(index: Int, code: String)
}

pub type PatternState {
  PatternStopped
  PatternRunning
  PatternPaused
}

pub type Pattern {
  Pattern(
    id: Int,
    // 0 .. 127
    speed: Int,
    // %: clock divider modulo (1 = every tick)
    length: Int,
    // number of active steps (1 .. 256)
    mute: Bool,
    // ym: pattern mute (0 = unmuted, 1 = muted)
    control_events: Bool,
    // yc: emit control events (0 = disabled, 1 = enabled)
    state: PatternState,
    // z: playback state
    steps: Dict(Int, String),
    // step index -> Skode command body
  )
}

/// Create an empty default pattern at the given pattern ID (16 steps, speed 1).
pub fn default(pattern_id: Int) -> Pattern {
  Pattern(
    id: param.clamp_pattern_id(pattern_id),
    speed: 1,
    length: 16,
    mute: False,
    control_events: False,
    state: PatternStopped,
    steps: dict.new(),
  )
}

/// Set the explicit pattern length in steps (yl).
pub fn set_length(pattern: Pattern, length: Int) -> Pattern {
  let len = case length < 1 {
    True -> 1
    False -> length
  }
  Pattern(..pattern, length: len)
}

/// Set a specific step's Skode command body (e.g. `[v0 n60 l1] x0`).
pub fn set_step(pattern: Pattern, step_index: Int, code: String) -> Pattern {
  let s = param.clamp_step_id(step_index)
  Pattern(..pattern, steps: dict.insert(pattern.steps, s, code))
}

/// Remove a step's program.
pub fn clear_step(pattern: Pattern, step_index: Int) -> Pattern {
  let s = param.clamp_step_id(step_index)
  Pattern(..pattern, steps: dict.delete(pattern.steps, s))
}

/// Serialize a pattern's settings and all defined steps into Skode script.
pub fn to_skode(pattern: Pattern) -> String {
  let p = int.to_string(pattern.id)
  let header = [
    "y" <> p,
    "%" <> int.to_string(pattern.speed),
    int.to_string(pattern.length) <> " yl",
    case pattern.mute {
      True -> "ym 1"
      False -> "ym 0"
    },
    case pattern.control_events {
      True -> "yc 1"
      False -> "yc 0"
    },
    case pattern.state {
      PatternRunning -> "z1"
      PatternPaused -> "z2"
      PatternStopped -> "z0"
    },
  ]
  let header_line = string.join(header, " ")

  // Serialize each populated step in ascending order: [<code>] x<index>
  let step_lines =
    dict.to_list(pattern.steps)
    |> list.sort(fn(a, b) { int.compare(a.0, b.0) })
    |> list.map(fn(pair) {
      let #(idx, code) = pair
      "[" <> code <> "] x" <> int.to_string(idx)
    })

  string.join(list.flatten([[header_line], step_lines]), "\n")
}

/// Compute delta Skode commands when a pattern's parameters change.
pub fn diff_skode(old: Pattern, new: Pattern) -> List(String) {
  let p = int.to_string(new.id)
  let diffs = []

  let diffs = case old.speed != new.speed {
    True -> ["%" <> int.to_string(new.speed), ..diffs]
    False -> diffs
  }
  let diffs = case old.mute != new.mute {
    True -> [
      case new.mute {
        True -> "ym 1"
        False -> "ym 0"
      },
      ..diffs
    ]
    False -> diffs
  }
  let diffs = case old.control_events != new.control_events {
    True -> [
      case new.control_events {
        True -> "yc 1"
        False -> "yc 0"
      },
      ..diffs
    ]
    False -> diffs
  }
  let diffs = case old.state != new.state {
    True -> [
      case new.state {
        PatternRunning -> "z1"
        PatternPaused -> "z2"
        PatternStopped -> "z0"
      },
      ..diffs
    ]
    False -> diffs
  }

  let param_diffs = case diffs {
    [] -> []
    cmds -> ["y" <> p <> " " <> string.join(list.reverse(cmds), " ")]
  }

  // Find added or updated steps
  let step_updates =
    dict.to_list(new.steps)
    |> list.filter_map(fn(pair) {
      let #(idx, code) = pair
      case dict.get(old.steps, idx) {
        Ok(old_code) if old_code == code -> Error(Nil)
        _ -> Ok("[" <> code <> "] x" <> int.to_string(idx))
      }
    })

  // Find deleted steps
  let step_deletions =
    dict.to_list(old.steps)
    |> list.filter_map(fn(pair) {
      let #(idx, _) = pair
      case dict.has_key(new.steps, idx) {
        True -> Error(Nil)
        False -> Ok("[] x" <> int.to_string(idx))
      }
    })

  let all_step_changes =
    list.append(step_updates, step_deletions)
    |> list.sort(fn(a, b) { string.compare(a, b) })

  let step_diffs = case all_step_changes {
    [] -> []
    changes -> list.map(changes, fn(c) { "y" <> p <> " " <> c })
  }

  list.flatten([param_diffs, step_diffs])
}
