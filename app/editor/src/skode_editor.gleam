//// # Skode Voice Editor
////
//// A modern, reactive Lustre 5 web interface for designing, shaping, and
//// live-previewing synthesizer voices using the Pulp 0.85.0 synchronized schema.

import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre
import lustre/attribute.{max, min, placeholder, step, styles, type_, value}
import lustre/effect.{type Effect}
import lustre/element.{type Element, text}
import lustre/element/html.{
  button, div, footer, form, h1, header, input, label, nav, option, p, pre,
  select, span,
}
import lustre/event.{on_click, on_input, on_submit}
import skode/gen/diff_gen
import skode/gen/param_gen
import skode/gen/voice_gen.{type Voice, Voice}

// -----------------------------------------------------------------------------
// FFI Declarations
// -----------------------------------------------------------------------------

@external(javascript, "./editor_ffi.mjs", "copy_to_clipboard")
fn copy_to_clipboard(text: String) -> Nil

@external(javascript, "./editor_ffi.mjs", "send_skode_command")
fn send_skode_command(cmd: String) -> Int

fn copy_effect(txt: String) -> Effect(Msg) {
  effect.from(fn(dispatch) {
    copy_to_clipboard(txt)
    dispatch(SetNotification("Copied Skode to clipboard!"))
  })
}

fn dispatch_skode_effect(cmd: String) -> Effect(Msg) {
  effect.from(fn(_) {
    let _ = send_skode_command(cmd)
    Nil
  })
}

// -----------------------------------------------------------------------------
// Model & Types
// -----------------------------------------------------------------------------

pub type Tab {
  TabOscillator
  TabFilter
  TabEnvelope
  TabModulation
  TabLinks
}

pub type Model {
  Model(
    voice: Voice,
    last_dispatched: Voice,
    active_tab: Tab,
    auto_dispatch: Bool,
    notification: Option(String),
    history: List(String),
    input_command: String,
  )
}

pub type Msg {
  SelectTab(Tab)
  SetVoiceId(Int)
  SetWaveTableIndex(Int)
  SetFreq(Float)
  SetMidiNote(Float)
  SetPitchMode(Int)
  SetAmp(Float)
  SetPan(Float)
  SetFilterMode(Int)
  SetFilterFreq(Float)
  SetFilterRes(Float)
  SetFilterEnvDepth(Float)
  SetUseFilterEnv(Bool)
  SetGlissandoTime(Float)
  SetGlissandoEnable(Bool)
  SetSmootherEnable(Bool)
  SetSmootherSmoothing(Float)
  SetCzMode(Int)
  SetCzDistortion(Float)
  SetRingAmount(Float)
  SetSampleHoldRatio(Float)
  SetQuantize(Int)
  SetDelaySend(Float)
  SetFreqBendRange(Float)
  SetAmpBendRange(Float)
  ToggleAutoDispatch
  ApplyPreset(String)
  ResetCurrentVoice
  TriggerVoice
  CopySkodeText
  SetInputCommand(String)
  SubmitInputCommand
  SetNotification(String)
  DismissNotification
}

// -----------------------------------------------------------------------------
// Initialization
// -----------------------------------------------------------------------------

pub fn init(_flags) -> #(Model, Effect(Msg)) {
  let v = voice_gen.default(0)
  let model =
    Model(
      voice: v,
      last_dispatched: v,
      active_tab: TabOscillator,
      auto_dispatch: True,
      notification: None,
      history: ["v0 w0 f440 a-6"],
      input_command: "",
    )
  #(model, effect.none())
}

// -----------------------------------------------------------------------------
// Update & Delta Streaming
// -----------------------------------------------------------------------------

fn update_voice_and_dispatch(
  model: Model,
  new_voice: Voice,
) -> #(Model, Effect(Msg)) {
  let diffs = diff_gen.diff_voice_skode(model.last_dispatched, new_voice)

  case model.auto_dispatch, diffs {
    True, [cmd, ..] -> {
      let new_history = [cmd, ..list.take(model.history, 19)]
      let next_model =
        Model(
          ..model,
          voice: new_voice,
          last_dispatched: new_voice,
          history: new_history,
        )
      #(next_model, dispatch_skode_effect(cmd))
    }
    _, _ -> {
      #(Model(..model, voice: new_voice), effect.none())
    }
  }
}

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    SelectTab(tab) -> #(Model(..model, active_tab: tab), effect.none())

    SetVoiceId(id) -> {
      let new_voice = voice_gen.Voice(..model.voice, id: id)
      update_voice_and_dispatch(model, new_voice)
    }

    SetWaveTableIndex(w) -> {
      let clamped = param_gen.clamp_wave_table_index(w)
      let new_voice = voice_gen.Voice(..model.voice, wave_table_index: clamped)
      update_voice_and_dispatch(model, new_voice)
    }

    SetFreq(f) -> {
      let clamped = param_gen.clamp_freq(f)
      let new_voice = voice_gen.Voice(..model.voice, freq: clamped)
      update_voice_and_dispatch(model, new_voice)
    }

    SetMidiNote(n) -> {
      let clamped = param_gen.clamp_midi_note(n)
      let new_voice = voice_gen.Voice(..model.voice, midi_note: clamped)
      update_voice_and_dispatch(model, new_voice)
    }

    SetPitchMode(m) -> {
      let clamped = param_gen.clamp_pitch_mode(m)
      let new_voice = voice_gen.Voice(..model.voice, pitch_mode: clamped)
      update_voice_and_dispatch(model, new_voice)
    }

    SetAmp(a) -> {
      let clamped = param_gen.clamp_user_amp(a)
      let new_voice = voice_gen.Voice(..model.voice, user_amp: clamped)
      update_voice_and_dispatch(model, new_voice)
    }

    SetPan(p) -> {
      let clamped = param_gen.clamp_pan(p)
      let new_voice = voice_gen.Voice(..model.voice, pan: clamped)
      update_voice_and_dispatch(model, new_voice)
    }

    SetFilterMode(m) -> {
      let clamped = param_gen.clamp_filter_mode(m)
      let new_voice = voice_gen.Voice(..model.voice, filter_mode: clamped)
      update_voice_and_dispatch(model, new_voice)
    }

    SetFilterFreq(f) -> {
      let clamped = param_gen.clamp_filter_freq(f)
      let new_voice = voice_gen.Voice(..model.voice, filter_freq: clamped)
      update_voice_and_dispatch(model, new_voice)
    }

    SetFilterRes(q) -> {
      let clamped = param_gen.clamp_filter_res(q)
      let new_voice = voice_gen.Voice(..model.voice, filter_res: clamped)
      update_voice_and_dispatch(model, new_voice)
    }

    SetFilterEnvDepth(d) -> {
      let clamped = param_gen.clamp_filter_env_depth(d)
      let new_voice = voice_gen.Voice(..model.voice, filter_env_depth: clamped)
      update_voice_and_dispatch(model, new_voice)
    }

    SetUseFilterEnv(use_env) -> {
      let flag = case use_env {
        True -> 1
        False -> 0
      }
      let new_voice = voice_gen.Voice(..model.voice, use_filter_envelope: flag)
      update_voice_and_dispatch(model, new_voice)
    }

    SetGlissandoTime(t) -> {
      let clamped = param_gen.clamp_glissando_time(t)
      let new_voice = voice_gen.Voice(..model.voice, glissando_time: clamped)
      update_voice_and_dispatch(model, new_voice)
    }

    SetGlissandoEnable(en) -> {
      let flag = case en {
        True -> 1
        False -> 0
      }
      let new_voice = voice_gen.Voice(..model.voice, glissando_enable: flag)
      update_voice_and_dispatch(model, new_voice)
    }

    SetSmootherEnable(en) -> {
      let flag = case en {
        True -> 1
        False -> 0
      }
      let new_voice = voice_gen.Voice(..model.voice, smoother_enable: flag)
      update_voice_and_dispatch(model, new_voice)
    }

    SetSmootherSmoothing(s) -> {
      let clamped = param_gen.clamp_smoother_smoothing(s)
      let new_voice =
        voice_gen.Voice(..model.voice, smoother_smoothing: clamped)
      update_voice_and_dispatch(model, new_voice)
    }

    SetCzMode(m) -> {
      let clamped = param_gen.clamp_cz_mode(m)
      let new_voice = voice_gen.Voice(..model.voice, cz_mode: clamped)
      update_voice_and_dispatch(model, new_voice)
    }

    SetCzDistortion(d) -> {
      let clamped = param_gen.clamp_cz_distortion(d)
      let new_voice = voice_gen.Voice(..model.voice, cz_distortion: clamped)
      update_voice_and_dispatch(model, new_voice)
    }

    SetRingAmount(a) -> {
      let clamped = param_gen.clamp_ring_amount(a)
      let new_voice = voice_gen.Voice(..model.voice, ring_amount: clamped)
      update_voice_and_dispatch(model, new_voice)
    }

    SetSampleHoldRatio(r) -> {
      let clamped = param_gen.clamp_sample_hold_ratio(r)
      let new_voice = voice_gen.Voice(..model.voice, sample_hold_ratio: clamped)
      update_voice_and_dispatch(model, new_voice)
    }

    SetQuantize(q) -> {
      let clamped = param_gen.clamp_quantize(q)
      let new_voice = voice_gen.Voice(..model.voice, quantize: clamped)
      update_voice_and_dispatch(model, new_voice)
    }

    SetDelaySend(ds) -> {
      let clamped = param_gen.clamp_delay_send(ds)
      let new_voice = voice_gen.Voice(..model.voice, delay_send: clamped)
      update_voice_and_dispatch(model, new_voice)
    }

    SetFreqBendRange(bp) -> {
      let clamped = param_gen.clamp_freq_bend_range(bp)
      let new_voice = voice_gen.Voice(..model.voice, freq_bend_range: clamped)
      update_voice_and_dispatch(model, new_voice)
    }

    SetAmpBendRange(abp) -> {
      let clamped = param_gen.clamp_amp_bend_range(abp)
      let new_voice = voice_gen.Voice(..model.voice, amp_bend_range: clamped)
      update_voice_and_dispatch(model, new_voice)
    }

    ToggleAutoDispatch -> {
      #(Model(..model, auto_dispatch: !model.auto_dispatch), effect.none())
    }

    ApplyPreset(preset_name) -> {
      let id = model.voice.id
      let preset = case preset_name {
        "Sub Saw" ->
          voice_gen.Voice(
            ..voice_gen.default(id),
            wave_table_index: 2,
            freq: 55.0,
            user_amp: -3.0,
            filter_mode: 1,
            filter_freq: 280.0,
            filter_res: 2.0,
          )
        "Acid Lead" ->
          voice_gen.Voice(
            ..voice_gen.default(id),
            wave_table_index: 2,
            freq: 220.0,
            filter_mode: 1,
            filter_freq: 850.0,
            filter_res: 7.5,
            use_filter_envelope: 1,
            filter_env_depth: 3500.0,
            glissando_enable: 1,
            glissando_time: 0.08,
          )
        "Table Noise" ->
          voice_gen.Voice(
            ..voice_gen.default(id),
            wave_table_index: 5,
            freq: 440.0,
            filter_mode: 1,
            filter_freq: 2400.0,
            filter_res: 1.5,
          )
        "PRNG White Noise" ->
          voice_gen.Voice(
            ..voice_gen.default(id),
            wave_table_index: 6,
            user_amp: -6.0,
            filter_mode: 1,
            filter_freq: 4000.0,
            filter_res: 0.707,
          )
        "CZ Phase Crunch" ->
          voice_gen.Voice(
            ..voice_gen.default(id),
            wave_table_index: 1,
            freq: 110.0,
            cz_mode: 1,
            cz_distortion: 0.85,
            quantize: 8,
          )
        _ -> voice_gen.default(id)
      }
      update_voice_and_dispatch(model, preset)
    }

    ResetCurrentVoice -> {
      let reset = voice_gen.default(model.voice.id)
      update_voice_and_dispatch(model, reset)
    }

    TriggerVoice -> {
      let cmd = voice_gen.to_skode(model.voice) <> " l1"
      #(model, dispatch_skode_effect(cmd))
    }

    CopySkodeText -> {
      let cmd = voice_gen.to_skode(model.voice)
      #(model, copy_effect(cmd))
    }

    SetInputCommand(text) -> {
      #(Model(..model, input_command: text), effect.none())
    }

    SubmitInputCommand -> {
      let raw = string.trim(model.input_command)
      case raw {
        "" -> #(model, effect.none())
        cmd -> {
          let updated_voice = apply_skode_string_to_voice(model.voice, cmd)
          let new_history = [cmd, ..list.take(model.history, 19)]
          let next_model =
            Model(
              ..model,
              voice: updated_voice,
              last_dispatched: updated_voice,
              input_command: "",
              notification: Some("Executed: " <> cmd),
              history: new_history,
            )
          #(next_model, dispatch_skode_effect(cmd))
        }
      }
    }

    SetNotification(msg_text) -> {
      #(Model(..model, notification: Some(msg_text)), effect.none())
    }

    DismissNotification -> {
      #(Model(..model, notification: None), effect.none())
    }
  }
}

// -----------------------------------------------------------------------------
// Live Command Parsing
// -----------------------------------------------------------------------------

fn is_digit(ch: String) -> Bool {
  case ch {
    "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" -> True
    _ -> False
  }
}

fn is_alpha(ch: String) -> Bool {
  case ch {
    "a"
    | "b"
    | "c"
    | "d"
    | "e"
    | "f"
    | "g"
    | "h"
    | "i"
    | "j"
    | "k"
    | "l"
    | "m"
    | "n"
    | "o"
    | "p"
    | "q"
    | "r"
    | "s"
    | "t"
    | "u"
    | "v"
    | "w"
    | "x"
    | "y"
    | "z"
    | "A"
    | "B"
    | "C"
    | "D"
    | "E"
    | "F"
    | "G"
    | "H"
    | "I"
    | "J"
    | "K"
    | "L"
    | "M"
    | "N"
    | "O"
    | "P"
    | "Q"
    | "R"
    | "S"
    | "T"
    | "U"
    | "V"
    | "W"
    | "X"
    | "Y"
    | "Z"
    | "_" -> True
    _ -> False
  }
}

fn strip_voice_prefix(token: String) -> String {
  case string.pop_grapheme(token) {
    Ok(#(ch, rest)) -> {
      case is_digit(ch) {
        True -> strip_voice_prefix(rest)
        False -> token
      }
    }
    Error(_) -> token
  }
}

fn split_op_val(token: String) -> #(String, String) {
  split_op_val_acc(token, "")
}

fn split_op_val_acc(token: String, acc: String) -> #(String, String) {
  case string.pop_grapheme(token) {
    Ok(#(ch, rest)) -> {
      case is_alpha(ch) {
        True -> split_op_val_acc(rest, acc <> ch)
        False -> #(acc, token)
      }
    }
    Error(_) -> #(acc, "")
  }
}

fn apply_single_token(voice: Voice, token: String) -> Voice {
  let cleaned = strip_voice_prefix(token)
  let #(op, val_str) = split_op_val(cleaned)
  case string.lowercase(op) {
    "v" -> Voice(..voice, id: parse_int(val_str, voice.id))
    "w" | "wave" ->
      Voice(
        ..voice,
        wave_table_index: param_gen.clamp_wave_table_index(parse_int(
          val_str,
          voice.wave_table_index,
        )),
      )
    "k" | "cutoff" ->
      Voice(
        ..voice,
        filter_freq: param_gen.clamp_filter_freq(parse_float(
          val_str,
          voice.filter_freq,
        )),
      )
    "q" | "res" | "resonance" ->
      Voice(
        ..voice,
        filter_res: param_gen.clamp_filter_res(parse_float(
          val_str,
          voice.filter_res,
        )),
      )
    "fm" | "filtermode" ->
      Voice(
        ..voice,
        filter_mode: param_gen.clamp_filter_mode(parse_int(
          val_str,
          voice.filter_mode,
        )),
      )
    "fed" | "fenv" ->
      Voice(
        ..voice,
        filter_env_depth: param_gen.clamp_filter_env_depth(parse_float(
          val_str,
          voice.filter_env_depth,
        )),
      )
    "n" | "note" ->
      Voice(
        ..voice,
        midi_note: param_gen.clamp_midi_note(parse_float(
          val_str,
          voice.midi_note,
        )),
        pitch_mode: 1,
      )
    "f" | "freq" ->
      Voice(
        ..voice,
        freq: param_gen.clamp_freq(parse_float(val_str, voice.freq)),
        pitch_mode: 0,
      )
    "amp" | "vol" ->
      Voice(..voice, amp: param_gen.clamp_amp(parse_float(val_str, voice.amp)))
    "pan" ->
      Voice(..voice, pan: param_gen.clamp_pan(parse_float(val_str, voice.pan)))
    "del" | "delay" ->
      Voice(
        ..voice,
        delay_send: param_gen.clamp_delay_send(parse_float(
          val_str,
          voice.delay_send,
        )),
      )
    "cz" ->
      Voice(
        ..voice,
        cz_mode: param_gen.clamp_cz_mode(parse_int(val_str, voice.cz_mode)),
      )
    "czd" ->
      Voice(
        ..voice,
        cz_distortion: param_gen.clamp_cz_distortion(parse_float(
          val_str,
          voice.cz_distortion,
        )),
      )
    "ring" ->
      Voice(
        ..voice,
        ring_amount: param_gen.clamp_ring_amount(parse_float(
          val_str,
          voice.ring_amount,
        )),
      )
    "sh" ->
      Voice(
        ..voice,
        sample_hold_ratio: param_gen.clamp_sample_hold_ratio(parse_float(
          val_str,
          voice.sample_hold_ratio,
        )),
      )
    "qnt" ->
      Voice(
        ..voice,
        quantize: param_gen.clamp_quantize(parse_int(val_str, voice.quantize)),
      )
    "gt" ->
      Voice(
        ..voice,
        glissando_time: param_gen.clamp_glissando_time(parse_float(
          val_str,
          voice.glissando_time,
        )),
      )
    "sm" ->
      Voice(
        ..voice,
        smoother_smoothing: param_gen.clamp_smoother_smoothing(parse_float(
          val_str,
          voice.smoother_smoothing,
        )),
      )
    "abp" ->
      Voice(
        ..voice,
        amp_bend_range: param_gen.clamp_amp_bend_range(parse_float(
          val_str,
          voice.amp_bend_range,
        )),
      )
    "pbp" ->
      Voice(
        ..voice,
        freq_bend_range: param_gen.clamp_freq_bend_range(parse_float(
          val_str,
          voice.freq_bend_range,
        )),
      )
    "reset" -> voice_gen.default(voice.id)
    _ -> voice
  }
}

fn apply_skode_string_to_voice(voice: Voice, text: String) -> Voice {
  let tokens = string.split(string.trim(text), " ")
  list.fold(tokens, voice, apply_single_token)
}

// -----------------------------------------------------------------------------
// View
// -----------------------------------------------------------------------------

fn parse_float(val: String, default: Float) -> Float {
  case float.parse(val) {
    Ok(f) -> f
    Error(_) -> default
  }
}

fn parse_int(val: String, default: Int) -> Int {
  case int.parse(val) {
    Ok(i) -> i
    Error(_) -> default
  }
}

fn slider_row(
  label_text: String,
  current_val: Float,
  min_val: Float,
  max_val: Float,
  step_val: Float,
  unit_text: String,
  on_change: fn(Float) -> Msg,
) -> Element(Msg) {
  div([styles([#("margin-bottom", "14px")])], [
    div(
      [
        styles([
          #("display", "flex"),
          #("justify-content", "space-between"),
          #("font-size", "13px"),
          #("margin-bottom", "4px"),
        ]),
      ],
      [
        span([styles([#("color", "#8b949e")])], [text(label_text)]),
        span([styles([#("font-weight", "600"), #("color", "#58a6ff")])], [
          text(float.to_string(current_val) <> " " <> unit_text),
        ]),
      ],
    ),
    input([
      type_("range"),
      min(float.to_string(min_val)),
      max(float.to_string(max_val)),
      step(float.to_string(step_val)),
      value(float.to_string(current_val)),
      on_input(fn(s) { on_change(parse_float(s, current_val)) }),
      styles([
        #("width", "100%"),
        #("accent-color", "#1f6feb"),
        #("cursor", "pointer"),
      ]),
    ]),
  ])
}

fn tab_button(active: Bool, title: String, tab: Tab) -> Element(Msg) {
  let bg = case active {
    True -> "#1f6feb"
    False -> "#21262d"
  }
  let fg = case active {
    True -> "#ffffff"
    False -> "#c9d1d9"
  }
  button(
    [
      on_click(SelectTab(tab)),
      styles([
        #("padding", "8px 16px"),
        #("background", bg),
        #("color", fg),
        #("border", "none"),
        #("border-radius", "6px"),
        #("font-weight", "500"),
        #("cursor", "pointer"),
        #("margin-right", "8px"),
      ]),
    ],
    [text(title)],
  )
}

fn preset_pill(name: String) -> Element(Msg) {
  button(
    [
      on_click(ApplyPreset(name)),
      styles([
        #("padding", "4px 10px"),
        #("background", "#30363d"),
        #("color", "#f0f6fc"),
        #("border", "1px solid #484f58"),
        #("border-radius", "14px"),
        #("font-size", "12px"),
        #("cursor", "pointer"),
        #("margin-right", "6px"),
        #("margin-bottom", "6px"),
      ]),
    ],
    [text(name)],
  )
}

pub fn view(model: Model) -> Element(Msg) {
  let skode_cmd = voice_gen.to_skode(model.voice)

  div(
    [
      styles([
        #("max-width", "860px"),
        #("margin", "0 auto"),
        #("padding", "24px"),
        #("font-family", "system-ui, -apple-system, sans-serif"),
        #("color", "#c9d1d9"),
      ]),
    ],
    [
      // Header
      header(
        [
          styles([
            #("display", "flex"),
            #("justify-content", "space-between"),
            #("align-items", "center"),
            #("margin-bottom", "20px"),
            #("border-bottom", "1px solid #30363d"),
            #("padding-bottom", "14px"),
          ]),
        ],
        [
          div([], [
            h1(
              [
                styles([
                  #("font-size", "22px"),
                  #("font-weight", "700"),
                  #("color", "#f0f6fc"),
                ]),
              ],
              [text("Pulp Voice Editor (Lustre)")],
            ),
            p([styles([#("font-size", "13px"), #("color", "#8b949e")])], [
              text("Synchronized with Pulp 0.85.0 engine schema via mksynth"),
            ]),
          ]),
          div(
            [
              styles([
                #("display", "flex"),
                #("align-items", "center"),
                #("gap", "10px"),
              ]),
            ],
            [
              label([styles([#("font-size", "13px")])], [text("Voice: ")]),
              select(
                [
                  on_input(fn(s) { SetVoiceId(parse_int(s, 0)) }),
                  styles([
                    #("padding", "6px 12px"),
                    #("background", "#21262d"),
                    #("color", "#f0f6fc"),
                    #("border", "1px solid #30363d"),
                    #("border-radius", "6px"),
                  ]),
                ],
                list.map(
                  [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
                  fn(idx) {
                    option(
                      [
                        value(int.to_string(idx)),
                        attribute.selected(idx == model.voice.id),
                      ],
                      "v" <> int.to_string(idx),
                    )
                  },
                ),
              ),
              button(
                [
                  on_click(TriggerVoice),
                  styles([
                    #("padding", "6px 14px"),
                    #("background", "#238636"),
                    #("color", "#ffffff"),
                    #("border", "none"),
                    #("border-radius", "6px"),
                    #("font-weight", "600"),
                    #("cursor", "pointer"),
                  ]),
                ],
                [text("▶ Play / Trigger")],
              ),
              button(
                [
                  on_click(ResetCurrentVoice),
                  styles([
                    #("padding", "6px 12px"),
                    #("background", "#21262d"),
                    #("color", "#f85149"),
                    #("border", "1px solid #30363d"),
                    #("border-radius", "6px"),
                    #("cursor", "pointer"),
                  ]),
                ],
                [text("↺ Reset")],
              ),
            ],
          ),
        ],
      ),
      // Live Skode Command Banner
      div(
        [
          styles([
            #("background", "#161b22"),
            #("border", "1px solid #30363d"),
            #("border-radius", "8px"),
            #("padding", "14px 18px"),
            #("margin-bottom", "20px"),
            #("display", "flex"),
            #("justify-content", "space-between"),
            #("align-items", "center"),
          ]),
        ],
        [
          div([], [
            span(
              [
                styles([
                  #("font-size", "11px"),
                  #("text-transform", "uppercase"),
                  #("letter-spacing", "0.5px"),
                  #("color", "#8b949e"),
                  #("display", "block"),
                  #("margin-bottom", "4px"),
                ]),
              ],
              [text("Live Skode Command")],
            ),
            pre(
              [
                styles([
                  #("font-family", "monospace"),
                  #("font-size", "15px"),
                  #("color", "#7ee787"),
                ]),
              ],
              [text(skode_cmd)],
            ),
          ]),
          button(
            [
              on_click(CopySkodeText),
              styles([
                #("padding", "6px 14px"),
                #("background", "#30363d"),
                #("color", "#f0f6fc"),
                #("border", "1px solid #484f58"),
                #("border-radius", "6px"),
                #("cursor", "pointer"),
                #("font-size", "13px"),
              ]),
            ],
            [text("📋 Copy")],
          ),
        ],
      ),
      // Optional Notification Banner
      case model.notification {
        Some(msg_text) ->
          div(
            [
              styles([
                #("background", "#1f6feb22"),
                #("border", "1px solid #1f6feb88"),
                #("border-radius", "6px"),
                #("padding", "10px 14px"),
                #("margin-bottom", "16px"),
                #("display", "flex"),
                #("justify-content", "space-between"),
                #("align-items", "center"),
                #("color", "#58a6ff"),
                #("font-size", "13px"),
              ]),
            ],
            [
              span([], [text("ℹ " <> msg_text)]),
              button(
                [
                  on_click(DismissNotification),
                  styles([
                    #("background", "transparent"),
                    #("border", "none"),
                    #("color", "#8b949e"),
                    #("cursor", "pointer"),
                    #("font-size", "16px"),
                  ]),
                ],
                [text("✕")],
              ),
            ],
          )
        None -> element.none()
      },
      // Live Skode Command Input Bar
      form(
        [
          on_submit(fn(_) { SubmitInputCommand }),
          styles([
            #("display", "flex"),
            #("gap", "10px"),
            #("margin-bottom", "20px"),
            #("background", "#161b22"),
            #("border", "1px solid #30363d"),
            #("border-radius", "8px"),
            #("padding", "8px 14px"),
            #("align-items", "center"),
          ]),
        ],
        [
          span(
            [
              styles([
                #("color", "#58a6ff"),
                #("font-family", "monospace"),
                #("font-size", "14px"),
                #("font-weight", "bold"),
              ]),
            ],
            [text("skode>")],
          ),
          input([
            type_("text"),
            value(model.input_command),
            placeholder(
              "Live Skode input: e.g. 0k1500 0q8.5 0w1 0n60 0T (Press Enter)",
            ),
            on_input(SetInputCommand),
            styles([
              #("flex", "1"),
              #("background", "#0d1117"),
              #("border", "1px solid #30363d"),
              #("border-radius", "6px"),
              #("padding", "8px 12px"),
              #("color", "#7ee787"),
              #("font-family", "monospace"),
              #("font-size", "14px"),
              #("outline", "none"),
            ]),
          ]),
          button(
            [
              type_("submit"),
              styles([
                #("padding", "8px 16px"),
                #("background", "#238636"),
                #("color", "#ffffff"),
                #("border", "none"),
                #("border-radius", "6px"),
                #("font-weight", "600"),
                #("cursor", "pointer"),
                #("font-size", "13px"),
              ]),
            ],
            [text("Send ↵")],
          ),
        ],
      ),
      // Presets
      div(
        [
          styles([
            #("display", "flex"),
            #("align-items", "center"),
            #("flex-wrap", "wrap"),
            #("margin-bottom", "18px"),
          ]),
        ],
        [
          span(
            [
              styles([
                #("font-size", "12px"),
                #("color", "#8b949e"),
                #("margin-right", "8px"),
              ]),
            ],
            [text("Presets:")],
          ),
          preset_pill("Sub Saw"),
          preset_pill("Acid Lead"),
          preset_pill("Table Noise"),
          preset_pill("PRNG White Noise"),
          preset_pill("CZ Phase Crunch"),
        ],
      ),
      // Tab Navigation
      nav([styles([#("display", "flex"), #("margin-bottom", "18px")])], [
        tab_button(
          model.active_tab == TabOscillator,
          "Oscillator",
          TabOscillator,
        ),
        tab_button(model.active_tab == TabFilter, "Filter", TabFilter),
        tab_button(
          model.active_tab == TabEnvelope,
          "Envelope & Mix",
          TabEnvelope,
        ),
        tab_button(
          model.active_tab == TabModulation,
          "Modulation",
          TabModulation,
        ),
        tab_button(model.active_tab == TabLinks, "Links & Sync", TabLinks),
      ]),
      // Active Tab Content
      div(
        [
          styles([
            #("background", "#161b22"),
            #("border", "1px solid #30363d"),
            #("border-radius", "8px"),
            #("padding", "20px"),
            #("margin-bottom", "20px"),
          ]),
        ],
        [
          case model.active_tab {
            TabOscillator -> view_tab_oscillator(model)
            TabFilter -> view_tab_filter(model)
            TabEnvelope -> view_tab_envelope(model)
            TabModulation -> view_tab_modulation(model)
            TabLinks -> view_tab_links(model)
          },
        ],
      ),
      // Footer info & live history
      footer(
        [
          styles([
            #("display", "flex"),
            #("justify-content", "space-between"),
            #("font-size", "12px"),
            #("color", "#8b949e"),
          ]),
        ],
        [
          span([], [text("Pulp 0.85.0 Voice Engine • Lustre 5.7")]),
          span([], [
            text(
              "Recent: "
              <> case model.history {
                [h, ..] -> h
                [] -> "None"
              },
            ),
          ]),
        ],
      ),
    ],
  )
}

fn view_tab_oscillator(model: Model) -> Element(Msg) {
  div([], [
    div([styles([#("margin-bottom", "16px")])], [
      label(
        [
          styles([
            #("font-size", "13px"),
            #("color", "#8b949e"),
            #("display", "block"),
            #("margin-bottom", "6px"),
          ]),
        ],
        [text("Wavetable Index (w)")],
      ),
      select(
        [
          on_input(fn(s) { SetWaveTableIndex(parse_int(s, 0)) }),
          styles([
            #("width", "100%"),
            #("padding", "8px 12px"),
            #("background", "#21262d"),
            #("color", "#f0f6fc"),
            #("border", "1px solid #30363d"),
            #("border-radius", "6px"),
          ]),
        ],
        [
          option(
            [value("0"), attribute.selected(model.voice.wave_table_index == 0)],
            "0: Sine Wave",
          ),
          option(
            [value("1"), attribute.selected(model.voice.wave_table_index == 1)],
            "1: Triangle Wave",
          ),
          option(
            [value("2"), attribute.selected(model.voice.wave_table_index == 2)],
            "2: Sawtooth Wave",
          ),
          option(
            [value("3"), attribute.selected(model.voice.wave_table_index == 3)],
            "3: Square Wave",
          ),
          option(
            [value("4"), attribute.selected(model.voice.wave_table_index == 4)],
            "4: Pulse Wave",
          ),
          option(
            [value("5"), attribute.selected(model.voice.wave_table_index == 5)],
            "5: Table Noise (Cyclic, tracks pitch)",
          ),
          option(
            [value("6"), attribute.selected(model.voice.wave_table_index == 6)],
            "6: PRNG White Noise (Audio RNG Function)",
          ),
          option(
            [value("7"), attribute.selected(model.voice.wave_table_index == 7)],
            "7: Physical Line-In Capture Left",
          ),
          option(
            [value("8"), attribute.selected(model.voice.wave_table_index == 8)],
            "8: Physical Line-In Capture Right",
          ),
          option(
            [
              value("15"),
              attribute.selected(model.voice.wave_table_index == 15),
            ],
            "15: Korg DW-8000 Bell Wave",
          ),
          option(
            [
              value("50"),
              attribute.selected(model.voice.wave_table_index == 50),
            ],
            "50: Ensoniq ESQ-1 Brass Wave",
          ),
          option(
            [
              value("82"),
              attribute.selected(model.voice.wave_table_index == 82),
            ],
            "82: 808 Bass Drum Single-Cycle",
          ),
        ],
      ),
    ]),
    slider_row(
      "Frequency (f)",
      model.voice.freq,
      20.0,
      4000.0,
      1.0,
      "Hz",
      SetFreq,
    ),
    slider_row(
      "MIDI Note (n)",
      model.voice.midi_note,
      0.0,
      127.0,
      1.0,
      "semitone",
      SetMidiNote,
    ),
  ])
}

fn view_tab_filter(model: Model) -> Element(Msg) {
  div([], [
    div([styles([#("margin-bottom", "16px")])], [
      label(
        [
          styles([
            #("font-size", "13px"),
            #("color", "#8b949e"),
            #("display", "block"),
            #("margin-bottom", "6px"),
          ]),
        ],
        [text("Filter Mode (j)")],
      ),
      select(
        [
          on_input(fn(s) { SetFilterMode(parse_int(s, 1)) }),
          styles([
            #("width", "100%"),
            #("padding", "8px 12px"),
            #("background", "#21262d"),
            #("color", "#f0f6fc"),
            #("border", "1px solid #30363d"),
            #("border-radius", "6px"),
          ]),
        ],
        [
          option(
            [value("0"), attribute.selected(model.voice.filter_mode == 0)],
            "0: Filter Off (Bypass)",
          ),
          option(
            [value("1"), attribute.selected(model.voice.filter_mode == 1)],
            "1: Low-Pass (Standard 12dB)",
          ),
          option(
            [value("2"), attribute.selected(model.voice.filter_mode == 2)],
            "2: Band-Pass",
          ),
          option(
            [value("3"), attribute.selected(model.voice.filter_mode == 3)],
            "3: High-Pass",
          ),
          option(
            [value("4"), attribute.selected(model.voice.filter_mode == 4)],
            "4: Notch Filter",
          ),
          option(
            [value("11"), attribute.selected(model.voice.filter_mode == 11)],
            "11: Vintage Ladder Low-Pass (Moog Character)",
          ),
          option(
            [value("21"), attribute.selected(model.voice.filter_mode == 21)],
            "21: Acid Diode Filter (TB-303 Character)",
          ),
        ],
      ),
    ]),
    slider_row(
      "Cutoff Frequency (k)",
      model.voice.filter_freq,
      20.0,
      20_000.0,
      10.0,
      "Hz",
      SetFilterFreq,
    ),
    slider_row(
      "Resonance (q)",
      model.voice.filter_res,
      0.1,
      20.0,
      0.1,
      "Q",
      SetFilterRes,
    ),
    slider_row(
      "Filter Env Depth (kd)",
      model.voice.filter_env_depth,
      -10_000.0,
      10_000.0,
      50.0,
      "Hz",
      SetFilterEnvDepth,
    ),
  ])
}

fn view_tab_envelope(model: Model) -> Element(Msg) {
  div([], [
    slider_row(
      "User Amplitude (a)",
      model.voice.user_amp,
      -60.0,
      12.0,
      0.5,
      "dB",
      SetAmp,
    ),
    slider_row("Pan (p)", model.voice.pan, -1.0, 1.0, 0.05, "", SetPan),
    slider_row(
      "Delay Bus Send (ds)",
      model.voice.delay_send,
      0.0,
      1.0,
      0.02,
      "",
      SetDelaySend,
    ),
    slider_row(
      "Parameter Smoother (sm)",
      model.voice.smoother_smoothing,
      0.0,
      1.0,
      0.01,
      "tau",
      SetSmootherSmoothing,
    ),
    slider_row(
      "Glissando / Portamento (gl)",
      model.voice.glissando_time,
      0.0,
      5.0,
      0.02,
      "sec",
      SetGlissandoTime,
    ),
  ])
}

fn view_tab_modulation(model: Model) -> Element(Msg) {
  div([], [
    slider_row(
      "Casio CZ Distortion (c)",
      model.voice.cz_distortion,
      0.0,
      1.0,
      0.02,
      "",
      SetCzDistortion,
    ),
    slider_row(
      "Ring Mod Wet/Dry (XM)",
      model.voice.ring_amount,
      0.0,
      1.0,
      0.02,
      "",
      SetRingAmount,
    ),
    slider_row(
      "Sample & Hold Ratio (sh)",
      model.voice.sample_hold_ratio,
      0.0,
      1.0,
      0.02,
      "",
      SetSampleHoldRatio,
    ),
    slider_row(
      "Bit-Depth Quantize (q)",
      int.to_float(model.voice.quantize),
      0.0,
      16.0,
      1.0,
      "bits",
      fn(f) { SetQuantize(float.round(f)) },
    ),
  ])
}

fn view_tab_links(model: Model) -> Element(Msg) {
  div([], [
    slider_row(
      "Pitch Bend Wheel Range (bp)",
      model.voice.freq_bend_range,
      0.0,
      48.0,
      1.0,
      "semitones",
      SetFreqBendRange,
    ),
    slider_row(
      "Amp Bend Wheel Range (abp)",
      model.voice.amp_bend_range,
      0.0,
      48.0,
      1.0,
      "dB",
      SetAmpBendRange,
    ),
  ])
}

// -----------------------------------------------------------------------------
// App Entry
// -----------------------------------------------------------------------------

pub fn main() {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)
}
