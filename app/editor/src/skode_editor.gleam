//// # Skode Voice Editor
////
//// A modern, reactive Lustre 5 web interface for designing, shaping, and
//// live-previewing synthesizer voices using the Pulp 0.85.0 synchronized schema.
//// Supports full 256-voice sparse patches, pill-based parameter inspection,
//// side-by-side linked voice cards, and a responsive parameter palette.

import gleam/dict
import gleam/dynamic/decode
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
  button, div, footer, form, h1, header, input, label, optgroup, option, p, pre,
  select, span,
}
import lustre/event.{
  on_change, on_click, on_input, on_keydown, on_submit, prevent_default,
}
import skode/delay.{type DelayBus, DelayBus, NativeFloat, Quantized}
import skode/gen/diff_gen
import skode/gen/param_gen
import skode/gen/voice_gen.{type Voice, Voice}
import skode/global.{type EngineSettings}
import skode/param
import skode/pattern.{
  type Pattern, Pattern, PatternPaused, PatternRunning, PatternStopped,
}
import skode/transport/wasm

// -----------------------------------------------------------------------------
// FFI Declarations & Transport Integration
// -----------------------------------------------------------------------------

@external(javascript, "./editor_ffi.mjs", "copy_to_clipboard")
fn copy_to_clipboard(text: String) -> Nil

/// Dispatch a Skode command to the native audio engine via the official WASM transport.
fn send_skode_command(cmd: String) -> String {
  case wasm.exec(cmd) {
    Ok(output) -> output
    Error(err) -> "Error: " <> err
  }
}

@external(javascript, "./editor_ffi.mjs", "render_waveform_buffer")
fn render_waveform_buffer(_canvas_id: String, _wave_idx: Int) -> Nil {
  Nil
}

@external(javascript, "./editor_ffi.mjs", "attach_vfs_file_dialog")
fn attach_vfs_file_dialog() -> Nil {
  Nil
}

@external(javascript, "./editor_ffi.mjs", "delete_vfs_file")
fn delete_vfs_file(_filename: String) -> Nil {
  Nil
}

@external(javascript, "./editor_ffi.mjs", "export_project_zip")
fn export_project_zip(_session_script: String) -> Nil {
  Nil
}

@external(javascript, "./editor_ffi.mjs", "import_project_zip_dialog")
fn import_project_zip_dialog() -> Nil {
  Nil
}

@external(javascript, "./editor_ffi.mjs", "read_vfs_text_file")
fn read_vfs_text_file(_filename: String) -> String {
  ""
}

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
// Data Types & Envelopes
// -----------------------------------------------------------------------------

pub type Envelope {
  Envelope(attack: Float, decay: Float, sustain: Float, release: Float)
}

pub type VoiceEnvelopes {
  VoiceEnvelopes(amp_env: Envelope, filter_env: Envelope)
}

pub fn default_amp_env() -> Envelope {
  Envelope(attack: 0.01, decay: 0.1, sustain: 0.8, release: 0.2)
}

pub fn default_filter_env() -> Envelope {
  Envelope(attack: 0.02, decay: 0.2, sustain: 0.5, release: 0.3)
}

pub fn default_voice_envelopes() -> VoiceEnvelopes {
  VoiceEnvelopes(amp_env: default_amp_env(), filter_env: default_filter_env())
}

pub type PillCategory {
  CatWavePitch
  CatFilter
  CatEnvelope
  CatModulation
  CatLink
  CatEffects
}

pub type PillId {
  PillWave
  PillFreq
  PillNote
  PillPitchMode
  PillAmp
  PillPan
  PillFilterMode
  PillFilterFreq
  PillFilterRes
  PillFilterEnvDepth
  PillAmpEnv
  PillFilterEnv
  PillGlissando
  PillSmoother
  PillCzDistortion
  PillRingAmount
  PillSampleHold
  PillQuantize
  PillDelaySend
  PillFreqBend
  PillAmpBend
  PillLinkSync
  PillLinkFreqMod
  PillLinkAmpMod
  PillLinkRingMod
  PillLinkCzMod
  PillLinkPanMod
  PillLinkMidi
  PillLinkVelo
  PillRecordTrack
}

pub type VoicePill {
  VoicePill(
    id: PillId,
    label: String,
    value_summary: String,
    category: PillCategory,
    bg_color: String,
    fg_color: String,
  )
}

pub type PaletteItem {
  PaletteItem(
    id: PillId,
    opcode: String,
    name: String,
    description: String,
    category: PillCategory,
    bg_color: String,
    fg_color: String,
  )
}

// -----------------------------------------------------------------------------
// Model & State
// -----------------------------------------------------------------------------

pub type StreamSlot {
  StreamSlot(id: Int, mode: Int, pos: Int, data: String)
}

pub type EditorMode {
  ModeVoices
  ModePatterns
  ModeDelays
  ModeMacros
  ModeKSynth
  ModeAudioMidi
  ModeFiles
  ModeStreams
}

pub type VfsItem {
  VfsItem(name: String, size_str: String, kind: String)
}

pub type Theme {
  ThemeDark
  ThemeLight
}

pub type CommandLog {
  CommandLog(
    id: Int,
    raw_cmd: String,
    tokens: List(String),
    summary: String,
    output: String,
  )
}

pub type Model {
  Model(
    editor_mode: EditorMode,
    voice: Voice,
    last_dispatched: Voice,
    pinned_pills: List(#(Int, PillId)),
    dragged_pill_index: Option(Int),
    history_cursor: Option(Int),
    command_logs: List(CommandLog),
    show_console: Bool,
    pattern_pointer: Int,
    show_add_menu: Option(Int),
    palette_open: Bool,
    palette_search: String,
    wave_search: String,
    voice_wave_search: dict.Dict(Int, String),
    auto_dispatch: Bool,
    notification: Option(String),
    history: List(String),
    input_command: String,
    voice_jump_input: String,
    all_voices: List(Voice),
    all_envelopes: List(#(Int, VoiceEnvelopes)),
    active_pattern_id: Int,
    all_patterns: List(Pattern),
    active_delay_id: Int,
    engine_settings: EngineSettings,
    ksynth_input: String,
    ksynth_slot: Int,
    macros: List(#(Int, String)),
    macro_slot: Int,
    macro_input: String,
    step_edit_index: Option(Int),
    step_edit_code: String,
    theme: Theme,
    control_voice_events: Bool,
    control_pattern_events: Bool,
    midi_channel_input: Int,
    midi_target_voice: Int,
    midi_target_pool: Int,
    active_stream_slot: Int,
    active_stream_mode: Int,
    active_stream_pos: Int,
    stream_data_input: String,
    stream_slots: dict.Dict(Int, StreamSlot),
    variables: dict.Dict(Int, Float),
    active_var_id: Int,
    var_input_val: String,
    sample_slot_input: Int,
    vfs_items: List(VfsItem),
  )
}

pub type Msg {
  SetEditorMode(EditorMode)
  // Voice selection & navigation (0..255)
  SetVoiceId(Int)
  StepVoice(Int)
  JumpNextConfigured
  JumpPrevConfigured
  SetVoiceJumpInput(String)
  SubmitVoiceJump
  // Pill inspector & parameters
  SelectVoicePill(Int, PillId)
  ToggleVoicePill(Int, PillId)
  ClosePillInspector
  CloseSinglePill(Int, PillId)
  ClearAllPinnedPills
  CloseVoicePinnedPills(Int)
  StartDragPill(Int)
  DragOverPill(Int)
  DropPill(Int)
  ShiftPinnedPill(Int, Int)
  ToggleAddMenu(Int)
  AddVoiceParam(Int, PillId)
  ResetVoiceParam(Int, PillId)
  // Waveform browser
  SetWaveSearch(String)
  StepVoiceWave(Int, Int)
  SetVoiceWaveSearch(Int, String)
  // Palette Drawer
  TogglePalette
  SetPaletteSearch(String)
  // Parameter modifications (parameterized by voice_id: Int)
  UpdateVoiceWave(Int, Int)
  UpdateVoiceFreq(Int, Float)
  UpdateVoiceNote(Int, Float)
  UpdateVoicePitchMode(Int, Int)
  UpdateVoiceAmp(Int, Float)
  UpdateVoicePan(Int, Float)
  UpdateVoiceFilterMode(Int, Int)
  UpdateVoiceFilterFreq(Int, Float)
  UpdateVoiceFilterRes(Int, Float)
  UpdateVoiceFilterEnvDepth(Int, Float)
  UpdateVoiceAmpAttack(Int, Float)
  UpdateVoiceAmpDecay(Int, Float)
  UpdateVoiceAmpSustain(Int, Float)
  UpdateVoiceAmpRelease(Int, Float)
  UpdateVoiceFilterAttack(Int, Float)
  UpdateVoiceFilterDecay(Int, Float)
  UpdateVoiceFilterSustain(Int, Float)
  UpdateVoiceFilterRelease(Int, Float)
  UpdateVoiceGlissandoTime(Int, Float)
  UpdateVoiceGlissandoEnable(Int, Int)
  UpdateVoiceSmoother(Int, Float)
  UpdateVoiceCzMode(Int, Int)
  UpdateVoiceCzDistortion(Int, Float)
  UpdateVoiceRecord(Int, Int)
  UpdateVoiceRingAmount(Int, Float)
  UpdateVoiceSampleHold(Int, Float)
  UpdateVoiceQuantize(Int, Int)
  UpdateVoiceDelaySend(Int, Float)
  UpdateVoiceFreqBend(Int, Float)
  UpdateVoiceAmpBend(Int, Float)
  UpdateVoiceLinkSync(Int, Int)
  UpdateVoiceLinkFreqMod(Int, Int)
  UpdateVoiceFreqModDepth(Int, Float)
  UpdateVoiceLinkAmpMod(Int, Int)
  UpdateVoiceLinkRingMod(Int, Int)
  UpdateVoiceLinkCzMod(Int, Int)
  UpdateVoiceLinkPanMod(Int, Int)
  UpdateVoiceLinkMidi(Int, Int)
  UpdateVoiceLinkVelo(Int, Int)
  // Pattern Sequencer
  SetPatternId(Int)
  StepPattern(Int)
  SetPatternSpeed(Int, Int)
  SetPatternLength(Int, Int)
  TogglePatternMute(Int)
  SetPatternState(Int, pattern.PatternState)
  SetPatternStepCode(Int, Int, String)
  ClearPatternStep(Int, Int)
  ToggleStepEdit(Int)
  SetStepEditCode(String)
  SubmitStepEdit(Int)
  ApplyPatternPreset(Int, String)
  // Delay Bus
  SetDelayBusId(Int)
  UpdateDelayCoarse(Int, Int)
  UpdateDelayFine(Int, Int)
  UpdateDelayFeedback(Int, Int)
  UpdateDelayDamping(Int, Int)
  UpdateDelayHighpass(Int, Int)
  UpdateDelayModFreq(Int, Int)
  UpdateDelayModDepth(Int, Int)
  UpdateDelayLevel(Int, Int)
  UpdateDelayPingPong(Int, Bool)
  UpdateDelayFreeze(Int, Bool)
  UpdateDelayGrit(Int, delay.DelayGrit)
  ApplyDelayPreset(Int, String)
  // Global Engine Controls
  UpdateMasterVolume(Float)
  UpdateMasterTempo(Float)
  // KSynth & Streams
  SetKSynthInput(String)
  SetKSynthSlot(Int)
  SubmitKSynthEval
  SubmitKSynthQuery
  SubmitKSynthToData
  SubmitQueryDataArray
  SubmitKSynthToWave(Int)
  LoadKSynthFile(Int)
  SetStreamMode(Int)
  // Macro Trigger Pad (e!0..e!15)
  SetMacroSlot(Int)
  SetMacroInput(String)
  StoreMacro(Int, String)
  ExecMacro(Int)
  QueryMacro(Int)
  QueryAllMacros
  ClearAllMacros
  // Actions
  ToggleAutoDispatch
  ApplyPreset(String)
  ResetVoiceId(Int)
  TriggerVoiceId(Int)
  CopySkodeText
  CopyCustomText(String)
  SetInputCommand(String)
  SubmitInputCommand
  ToggleConsole
  ClearConsoleLogs
  RecallHistoryItem(String)
  CommandKeyDown(String)
  SetNotification(String)
  DismissNotification
  ToggleTheme
  SubmitAudioList
  SubmitAudioQuery
  SubmitAudioOut(Int)
  SubmitAudioIn(Int)
  SubmitMidiList
  SubmitMidiQuery
  SubmitMidiIn(Int)
  SubmitMidiOut(Int)
  SubmitMidiVoiceRoute(Int, Int)
  SubmitMidiPoolRoute(Int, Int)
  ToggleControlVoiceEvents
  ToggleControlPatternEvents
  SubmitUserControlEvent(Int, Int, Int, Int)
  SubmitControlEventQuery
  SubmitControlEventClear
  SubmitScheduledQueueQuery
  InspectVoiceWaveformBuffer(Int, Int)
  // VFS & Files
  AttachFilesViaDialog
  DeleteVfsItem(String)
  LoadFileToWaveSlot(String, Int)
  MountZipFile(String)
  UnmountZipFile
  RunVfsScript(String)
  // Project State Zip Bundles
  ExportSessionZip
  ImportSessionZip
  // Streams Studio
  SelectStreamSlot(Int)
  SetStreamSlotMode(Int, Int)
  SetStreamSlotPos(Int, Int)
  SetStreamDataInput(String)
  SubmitStreamDataSet(Int, String)
  CopyStreamSlot(Int, Int)
  QueryStreamSlot(Int)
  // Variable Registers ($0..$127)
  SelectVariable(Int)
  SetVariableInput(String)
  SubmitSetVariable(Int, Float)
  SubmitOpVariable(String, Int, Float)
  ClearVariable(Int)
}

// -----------------------------------------------------------------------------
// Initialization
// -----------------------------------------------------------------------------

pub fn init(_flags) -> #(Model, Effect(Msg)) {
  let v0 = voice_gen.default(0)
  let initial_voices = [v0]
  let initial_envs = [#(0, default_voice_envelopes())]
  let initial_patterns = []
  let initial_engine = global.default()

  let empty_macros = [
    #(0, ""),
    #(1, ""),
    #(2, ""),
    #(3, ""),
    #(4, ""),
    #(5, ""),
    #(6, ""),
    #(7, ""),
    #(8, ""),
    #(9, ""),
    #(10, ""),
    #(11, ""),
    #(12, ""),
    #(13, ""),
    #(14, ""),
    #(15, ""),
  ]

  let empty_streams =
    dict.from_list([
      #(0, StreamSlot(0, 0, 0, "")),
      #(1, StreamSlot(1, 0, 0, "")),
      #(2, StreamSlot(2, 0, 0, "")),
      #(3, StreamSlot(3, 0, 0, "")),
      #(4, StreamSlot(4, 0, 0, "")),
      #(5, StreamSlot(5, 0, 0, "")),
      #(6, StreamSlot(6, 0, 0, "")),
      #(7, StreamSlot(7, 0, 0, "")),
      #(8, StreamSlot(8, 0, 0, "")),
      #(9, StreamSlot(9, 0, 0, "")),
      #(10, StreamSlot(10, 0, 0, "")),
      #(11, StreamSlot(11, 0, 0, "")),
      #(12, StreamSlot(12, 0, 0, "")),
      #(13, StreamSlot(13, 0, 0, "")),
      #(14, StreamSlot(14, 0, 0, "")),
      #(15, StreamSlot(15, 0, 0, "")),
    ])

  let model =
    Model(
      editor_mode: ModeVoices,
      voice: v0,
      last_dispatched: v0,
      pinned_pills: [#(0, PillWave), #(0, PillFreq), #(0, PillAmp)],
      dragged_pill_index: None,
      history_cursor: None,
      command_logs: [
        CommandLog(
          id: 1,
          raw_cmd: "v0 w 0 f 440 a -6",
          tokens: ["v0", "w0", "f440", "a-6"],
          summary: "Voice 0 initialized (Sine 440Hz)",
          output: "Pulp Audio Engine initialized • 256 sparse voices ready",
        ),
      ],
      show_console: False,
      pattern_pointer: 0,
      show_add_menu: None,
      palette_open: True,
      palette_search: "",
      wave_search: "",
      voice_wave_search: dict.new(),
      auto_dispatch: True,
      notification: None,
      history: ["v0 w 0 f 440 a -6"],
      input_command: "",
      voice_jump_input: "0",
      all_voices: initial_voices,
      all_envelopes: initial_envs,
      active_pattern_id: 0,
      all_patterns: initial_patterns,
      active_delay_id: 1,
      engine_settings: initial_engine,
      ksynth_input: "w s +\\(1024#440*6.28318%44100)",
      ksynth_slot: 0,
      macros: empty_macros,
      macro_slot: 0,
      macro_input: "",
      step_edit_index: None,
      step_edit_code: "",
      theme: ThemeDark,
      control_voice_events: False,
      control_pattern_events: False,
      midi_channel_input: 1,
      midi_target_voice: 0,
      midi_target_pool: 0,
      active_stream_slot: 0,
      active_stream_mode: 0,
      active_stream_pos: 0,
      stream_data_input: "",
      stream_slots: empty_streams,
      variables: dict.new(),
      active_var_id: 0,
      var_input_val: "0.0",
      sample_slot_input: 0,
      vfs_items: [],
    )

  let wave_init_eff =
    effect.from(fn(_) {
      render_waveform_buffer("voice-wave-0", 0)
      Nil
    })
  #(
    model,
    effect.batch([
      dispatch_skode_effect("v0 w 0 f 440 a -6"),
      wave_init_eff,
    ]),
  )
}

// -----------------------------------------------------------------------------
// Envelope Helpers
// -----------------------------------------------------------------------------

fn get_voice_envelopes(model: Model, voice_id: Int) -> VoiceEnvelopes {
  case list.key_find(model.all_envelopes, voice_id) {
    Ok(envs) -> envs
    Error(_) -> default_voice_envelopes()
  }
}

fn set_voice_envelopes(
  model: Model,
  voice_id: Int,
  envs: VoiceEnvelopes,
) -> Model {
  let updated = list.key_set(model.all_envelopes, voice_id, envs)
  Model(..model, all_envelopes: updated)
}

fn format_adsr(env: Envelope) -> String {
  param.format_float(env.attack)
  <> ", "
  <> param.format_float(env.decay)
  <> ", "
  <> param.format_float(env.sustain)
  <> ", "
  <> param.format_float(env.release)
}

fn parse_adsr_token(str: String, default: Envelope) -> Envelope {
  let normalized = string.replace(str, " ", ",")
  let parts =
    string.split(normalized, ",")
    |> list.map(string.trim)
    |> list.filter(fn(s) { s != "" })

  case parts {
    [a, d, s, r, ..] ->
      Envelope(
        attack: float.clamp(parse_float(a, default.attack), 0.001, 10.0),
        decay: float.clamp(parse_float(d, default.decay), 0.001, 10.0),
        sustain: float.clamp(parse_float(s, default.sustain), 0.0, 1.0),
        release: float.clamp(parse_float(r, default.release), 0.0, 10.0),
      )
    [a, d, s] ->
      Envelope(
        attack: float.clamp(parse_float(a, default.attack), 0.001, 10.0),
        decay: float.clamp(parse_float(d, default.decay), 0.001, 10.0),
        sustain: float.clamp(parse_float(s, default.sustain), 0.0, 1.0),
        release: default.release,
      )
    [a, d] ->
      Envelope(
        attack: float.clamp(parse_float(a, default.attack), 0.001, 10.0),
        decay: float.clamp(parse_float(d, default.decay), 0.001, 10.0),
        sustain: default.sustain,
        release: default.release,
      )
    [a] ->
      Envelope(
        attack: float.clamp(parse_float(a, default.attack), 0.001, 10.0),
        decay: default.decay,
        sustain: default.sustain,
        release: default.release,
      )
    _ -> default
  }
}

// -----------------------------------------------------------------------------
// Sparse Voice Management (0..255)
// -----------------------------------------------------------------------------

fn get_or_create_voice(
  voices: List(Voice),
  voice_id: Int,
) -> #(Voice, List(Voice)) {
  case list.find(voices, fn(v) { v.id == voice_id }) {
    Ok(v) -> #(v, voices)
    Error(_) -> {
      let new_v = voice_gen.default(voice_id)
      let updated = [new_v, ..voices]
      let sorted = list.sort(updated, fn(a, b) { int.compare(a.id, b.id) })
      #(new_v, sorted)
    }
  }
}

fn update_voice_in_list(voices: List(Voice), updated: Voice) -> List(Voice) {
  case list.any(voices, fn(v) { v.id == updated.id }) {
    True ->
      list.map(voices, fn(v) {
        case v.id == updated.id {
          True -> updated
          False -> v
        }
      })
    False -> {
      let updated_list = [updated, ..voices]
      list.sort(updated_list, fn(a, b) { int.compare(a.id, b.id) })
    }
  }
}

fn get_configured_voices(
  all_voices: List(Voice),
  active_id: Int,
) -> List(Voice) {
  let all_links = list.flat_map(all_voices, voice_gen.get_links)
  let linked_ids =
    list.flat_map(all_links, fn(l) { [l.from_voice, l.to_voice] })

  let filtered =
    list.filter(all_voices, fn(v) {
      v.id == active_id
      || voice_gen.is_configured(v)
      || list.contains(linked_ids, v.id)
    })
  list.sort(filtered, fn(a, b) { int.compare(a.id, b.id) })
}

// -----------------------------------------------------------------------------
// Linked Voice Topology Relationships
// -----------------------------------------------------------------------------

fn get_direct_contributors(
  voice_id: Int,
  all_voices: List(Voice),
) -> List(Int) {
  let #(voice, _) = get_or_create_voice(all_voices, voice_id)
  let direct = []
  let direct = case voice.freq_mod_osc >= 0 && voice.freq_mod_osc != voice_id {
    True -> [voice.freq_mod_osc, ..direct]
    False -> direct
  }
  let direct = case voice.amp_mod_osc >= 0 && voice.amp_mod_osc != voice_id {
    True -> [voice.amp_mod_osc, ..direct]
    False -> direct
  }
  let direct = case voice.ring_osc >= 0 && voice.ring_osc != voice_id {
    True -> [voice.ring_osc, ..direct]
    False -> direct
  }
  let direct = case voice.cz_mod_osc >= 0 && voice.cz_mod_osc != voice_id {
    True -> [voice.cz_mod_osc, ..direct]
    False -> direct
  }
  let direct = case voice.pan_mod_osc >= 0 && voice.pan_mod_osc != voice_id {
    True -> [voice.pan_mod_osc, ..direct]
    False -> direct
  }
  let direct =
    list.fold(all_voices, direct, fn(acc, v) {
      case v.id != voice_id {
        True -> {
          let has_sync =
            list.any(v.link_sync, fn(t) { float.round(t) == voice_id })
          let has_midi =
            list.any(v.link_midi, fn(t) { float.round(t) == voice_id })
          let has_velo =
            list.any(v.link_velo, fn(t) { float.round(t) == voice_id })
          case has_sync || has_midi || has_velo {
            True -> [v.id, ..acc]
            False -> acc
          }
        }
        False -> acc
      }
    })
  list.unique(direct)
}

fn walk_upstream_contributors(
  pending: List(Int),
  all_voices: List(Voice),
  visited: List(Int),
) -> List(Int) {
  case pending {
    [] -> visited
    [curr, ..rest] -> {
      case list.contains(visited, curr) {
        True -> walk_upstream_contributors(rest, all_voices, visited)
        False -> {
          let next_visited = [curr, ..visited]
          let parents = get_direct_contributors(curr, all_voices)
          let next_pending = list.append(rest, parents)
          walk_upstream_contributors(next_pending, all_voices, next_visited)
        }
      }
    }
  }
}

fn get_direct_dependents(voice_id: Int, all_voices: List(Voice)) -> List(Int) {
  let #(voice, _) = get_or_create_voice(all_voices, voice_id)
  let direct = []
  let direct =
    list.fold(voice.link_sync, direct, fn(acc, t) {
      let tid = float.round(t)
      case tid >= 0 && tid != voice_id {
        True -> [tid, ..acc]
        False -> acc
      }
    })
  let direct =
    list.fold(voice.link_midi, direct, fn(acc, t) {
      let tid = float.round(t)
      case tid >= 0 && tid != voice_id {
        True -> [tid, ..acc]
        False -> acc
      }
    })
  let direct =
    list.fold(voice.link_velo, direct, fn(acc, t) {
      let tid = float.round(t)
      case tid >= 0 && tid != voice_id {
        True -> [tid, ..acc]
        False -> acc
      }
    })
  let direct =
    list.fold(all_voices, direct, fn(acc, v) {
      case v.id != voice_id {
        True -> {
          case
            v.freq_mod_osc == voice_id
            || v.amp_mod_osc == voice_id
            || v.ring_osc == voice_id
            || v.cz_mod_osc == voice_id
            || v.pan_mod_osc == voice_id
          {
            True -> [v.id, ..acc]
            False -> acc
          }
        }
        False -> acc
      }
    })
  list.unique(direct)
}

fn find_linked_partner_ids(voice: Voice, all_voices: List(Voice)) -> List(Int) {
  let direct_up = get_direct_contributors(voice.id, all_voices)
  let all_up = walk_upstream_contributors(direct_up, all_voices, [])
  let all_down = get_direct_dependents(voice.id, all_voices)
  let all_connected =
    list.append(all_up, all_down)
    |> list.unique
    |> list.filter(fn(id) { id != voice.id && id >= 0 && id <= 255 })
  list.sort(all_connected, int.compare)
}

fn get_relationship_badge(
  partner_id: Int,
  active_voice: Voice,
  all_voices: List(Voice),
) -> #(String, String, String) {
  let #(partner_voice, _) = get_or_create_voice(all_voices, partner_id)

  case active_voice.freq_mod_osc == partner_id {
    True -> #(
      "#58a6ff22",
      "#58a6ff",
      "🌊 FM Modulator ➔ v"
        <> int.to_string(active_voice.id)
        <> " ("
        <> param.format_float(active_voice.freq_mod_depth)
        <> ")",
    )
    False ->
      case active_voice.ring_osc == partner_id {
        True -> #(
          "#f0883e22",
          "#f0883e",
          "🔔 Ring Modulator ➔ v"
            <> int.to_string(active_voice.id)
            <> " ("
            <> param.format_float(active_voice.ring_amount)
            <> ")",
        )
        False ->
          case active_voice.amp_mod_osc == partner_id {
            True -> #(
              "#a371f722",
              "#a371f7",
              "📶 AM Modulator ➔ v" <> int.to_string(active_voice.id),
            )
            False ->
              case active_voice.cz_mod_osc == partner_id {
                True -> #(
                  "#bc8cff22",
                  "#bc8cff",
                  "📐 Phase Modulator ➔ v" <> int.to_string(active_voice.id),
                )
                False ->
                  case active_voice.pan_mod_osc == partner_id {
                    True -> #(
                      "#3fb95022",
                      "#3fb950",
                      "↔ Pan Modulator ➔ v" <> int.to_string(active_voice.id),
                    )
                    False ->
                      case
                        list.any(partner_voice.link_sync, fn(t) {
                          float.round(t) == active_voice.id
                        })
                      {
                        True -> #(
                          "#d2992222",
                          "#d29922",
                          "⚡ Sync Master ➔ v" <> int.to_string(active_voice.id),
                        )
                        False ->
                          case
                            list.any(partner_voice.link_midi, fn(t) {
                              float.round(t) == active_voice.id
                            })
                          {
                            True -> #(
                              "#3fb95022",
                              "#3fb950",
                              "🎹 Gate Master ➔ v"
                                <> int.to_string(active_voice.id),
                            )
                            False ->
                              case
                                partner_voice.freq_mod_osc == active_voice.id
                              {
                                True -> #(
                                  "#58a6ff22",
                                  "#58a6ff",
                                  "🌊 FM Target from v"
                                    <> int.to_string(active_voice.id),
                                )
                                False ->
                                  case
                                    partner_voice.ring_osc == active_voice.id
                                  {
                                    True -> #(
                                      "#f0883e22",
                                      "#f0883e",
                                      "🔔 Ring Target from v"
                                        <> int.to_string(active_voice.id),
                                    )
                                    False ->
                                      case
                                        list.any(active_voice.link_sync, fn(t) {
                                          float.round(t) == partner_id
                                        })
                                      {
                                        True -> #(
                                          "#d2992222",
                                          "#d29922",
                                          "⚡ Sync Target from v"
                                            <> int.to_string(active_voice.id),
                                        )
                                        False ->
                                          case
                                            list.any(
                                              active_voice.link_midi,
                                              fn(t) {
                                                float.round(t) == partner_id
                                              },
                                            )
                                          {
                                            True -> #(
                                              "#3fb95022",
                                              "#3fb950",
                                              "🎹 Gate Target from v"
                                                <> int.to_string(
                                                active_voice.id,
                                              ),
                                            )
                                            False -> #(
                                              "#8b949e22",
                                              "#8b949e",
                                              "🔗 Connected in patch with v"
                                                <> int.to_string(
                                                active_voice.id,
                                              ),
                                            )
                                          }
                                      }
                                  }
                              }
                          }
                      }
                  }
              }
          }
      }
  }
}

// -----------------------------------------------------------------------------
// Non-Default Parameter Pills Derivation
// -----------------------------------------------------------------------------

pub type WaveInfo {
  WaveInfo(index: Int, name: String, category: String)
}

pub fn get_all_wavetables() -> List(WaveInfo) {
  [
    // Classic Analog & Noise (Pulp 0.85.0 parts/synth-wave.c & synth-types.h)
    WaveInfo(0, "Sine Wave", "Classic"),
    WaveInfo(1, "Square Wave", "Classic"),
    WaveInfo(2, "Saw-Down Wave", "Classic"),
    WaveInfo(3, "Saw-Up Wave", "Classic"),
    WaveInfo(4, "Triangle Wave", "Classic"),
    WaveInfo(5, "Table Noise (Cyclic)", "Classic"),
    WaveInfo(6, "PRNG White Noise", "Classic"),
    // Live Input Capture
    WaveInfo(7, "Input 1 Left", "Live In"),
    WaveInfo(8, "Input 1 Right", "Live In"),
    WaveInfo(9, "Input 2 Left", "Live In"),
    WaveInfo(10, "Input 2 Right", "Live In"),
    WaveInfo(11, "Input 3 Left", "Live In"),
    WaveInfo(12, "Input 3 Right", "Live In"),
    WaveInfo(13, "Input 4 Left", "Live In"),
    WaveInfo(14, "Input 4 Right", "Live In"),
    // Korg DW-8000 Digital Acoustic Models (Slots 15..30)
    WaveInfo(15, "DWG Strings", "DW-8000"),
    WaveInfo(16, "DWG Clarinet", "DW-8000"),
    WaveInfo(17, "DWG Acoustic Piano", "DW-8000"),
    WaveInfo(18, "DWG Electric Piano", "DW-8000"),
    WaveInfo(19, "DWG Electric Piano Hard", "DW-8000"),
    WaveInfo(20, "DWG Clavinet", "DW-8000"),
    WaveInfo(21, "DWG Organ", "DW-8000"),
    WaveInfo(22, "DWG Brass", "DW-8000"),
    WaveInfo(23, "DWG Saxophone", "DW-8000"),
    WaveInfo(24, "DWG Violin", "DW-8000"),
    WaveInfo(25, "DWG Acoustic Guitar", "DW-8000"),
    WaveInfo(26, "DWG Distortion Guitar", "DW-8000"),
    WaveInfo(27, "DWG Electric Bass", "DW-8000"),
    WaveInfo(28, "DWG Upright Bass", "DW-8000"),
    WaveInfo(29, "DWG Bell", "DW-8000"),
    WaveInfo(30, "DWG Whistle", "DW-8000"),
    // Ensoniq ESQ-1 Vintage Digital Wavetables (Slots 50..81)
    WaveInfo(50, "ESQ-1 Saw", "ESQ-1"),
    WaveInfo(51, "ESQ-1 Bell", "ESQ-1"),
    WaveInfo(52, "ESQ-1 Sine", "ESQ-1"),
    WaveInfo(53, "ESQ-1 Square", "ESQ-1"),
    WaveInfo(54, "ESQ-1 Pulse", "ESQ-1"),
    WaveInfo(55, "ESQ-1 Noise 1", "ESQ-1"),
    WaveInfo(56, "ESQ-1 Noise 2", "ESQ-1"),
    WaveInfo(57, "ESQ-1 Noise 3", "ESQ-1"),
    WaveInfo(58, "ESQ-1 Bass", "ESQ-1"),
    WaveInfo(59, "ESQ-1 Piano", "ESQ-1"),
    WaveInfo(60, "ESQ-1 El. Piano", "ESQ-1"),
    WaveInfo(61, "ESQ-1 Voice 1", "ESQ-1"),
    WaveInfo(62, "ESQ-1 Voice 2", "ESQ-1"),
    WaveInfo(63, "ESQ-1 Kick", "ESQ-1"),
    WaveInfo(64, "ESQ-1 Reed", "ESQ-1"),
    WaveInfo(65, "ESQ-1 Organ", "ESQ-1"),
    WaveInfo(66, "ESQ-1 Synth 1", "ESQ-1"),
    WaveInfo(67, "ESQ-1 Synth 2", "ESQ-1"),
    WaveInfo(68, "ESQ-1 Synth 3", "ESQ-1"),
    WaveInfo(69, "ESQ-1 Formant 1", "ESQ-1"),
    WaveInfo(70, "ESQ-1 Formant 2", "ESQ-1"),
    WaveInfo(71, "ESQ-1 Formant 3", "ESQ-1"),
    WaveInfo(72, "ESQ-1 Formant 4", "ESQ-1"),
    WaveInfo(73, "ESQ-1 Formant 5", "ESQ-1"),
    WaveInfo(74, "ESQ-1 Pulse 2", "ESQ-1"),
    WaveInfo(75, "ESQ-1 Square 2", "ESQ-1"),
    WaveInfo(76, "ESQ-1 4-Octaves", "ESQ-1"),
    WaveInfo(77, "ESQ-1 Prime", "ESQ-1"),
    WaveInfo(78, "ESQ-1 Brass", "ESQ-1"),
    WaveInfo(79, "ESQ-1 Strings", "ESQ-1"),
    WaveInfo(80, "ESQ-1 Octave", "ESQ-1"),
    WaveInfo(81, "ESQ-1 Octave + 5th", "ESQ-1"),
    // Roland TR-808 Single-Cycle Drums & Percussion (Slots 82..99)
    WaveInfo(82, "808 Kick Drum", "808 Drums"),
    WaveInfo(83, "808 Snare Drum", "808 Drums"),
    WaveInfo(84, "808 Closed Hat", "808 Drums"),
    WaveInfo(85, "808 Open Hat", "808 Drums"),
    WaveInfo(86, "808 Handclap", "808 Drums"),
    WaveInfo(87, "808 Rimshot", "808 Drums"),
    WaveInfo(88, "808 Low Tom", "808 Drums"),
    WaveInfo(89, "808 Mid Tom", "808 Drums"),
    WaveInfo(90, "808 Hi Tom", "808 Drums"),
    WaveInfo(91, "808 Low Conga", "808 Drums"),
    WaveInfo(92, "808 Mid Conga", "808 Drums"),
    WaveInfo(93, "808 Hi Conga", "808 Drums"),
    WaveInfo(94, "808 Crash Cymbal", "808 Drums"),
    WaveInfo(95, "808 Ride Cymbal", "808 Drums"),
    WaveInfo(96, "808 Cowbell", "808 Drums"),
    WaveInfo(97, "808 Clave", "808 Drums"),
    WaveInfo(98, "808 Maracas", "808 Drums"),
    WaveInfo(99, "808 Accent Trigger", "808 Drums"),
  ]
}

fn wave_name(idx: Int) -> String {
  case list.find(get_all_wavetables(), fn(w) { w.index == idx }) {
    Ok(w) -> w.name
    Error(_) -> "Wave " <> int.to_string(idx)
  }
}

fn step_wave_index(current: Int, delta: Int) -> Int {
  let waves = get_all_wavetables()
  let indices = list.map(waves, fn(w) { w.index })
  case delta > 0 {
    True -> {
      case list.find(indices, fn(i) { i > current }) {
        Ok(next_i) -> next_i
        Error(_) ->
          case list.first(indices) {
            Ok(first) -> first
            Error(_) -> 0
          }
      }
    }
    False -> {
      let rev = list.reverse(indices)
      case list.find(rev, fn(i) { i < current }) {
        Ok(prev_i) -> prev_i
        Error(_) ->
          case list.first(rev) {
            Ok(last) -> last
            Error(_) -> 0
          }
      }
    }
  }
}

fn filter_mode_name(mode: Int) -> String {
  case mode {
    0 -> "Bypass"
    1 -> "LowPass"
    2 -> "HighPass"
    3 -> "BandPass"
    _ -> "Mode " <> int.to_string(mode)
  }
}

pub fn get_voice_pills(voice: Voice, envs: VoiceEnvelopes) -> List(VoicePill) {
  let def = voice_gen.default(voice.id)
  let pills = []

  // 1. Oscillator & Pitch - Waveform is an intrinsic property of every voice
  let pills = [
    VoicePill(
      PillWave,
      "Wave",
      wave_name(voice.wave_table_index),
      CatWavePitch,
      "#1f6feb22",
      "#58a6ff",
    ),
    ..pills
  ]

  let pills = case voice.freq != def.freq && voice.pitch_mode == 0 {
    True -> [
      VoicePill(
        PillFreq,
        "Freq",
        int.to_string(float.round(voice.freq)) <> " Hz",
        CatWavePitch,
        "#1f6feb22",
        "#58a6ff",
      ),
      ..pills
    ]
    False -> pills
  }

  let pills = case voice.midi_note != def.midi_note && voice.pitch_mode == 1 {
    True -> [
      VoicePill(
        PillNote,
        "Note",
        "MIDI " <> int.to_string(float.round(voice.midi_note)),
        CatWavePitch,
        "#1f6feb22",
        "#58a6ff",
      ),
      ..pills
    ]
    False -> pills
  }

  // 2. Mix & Gain
  let pills = case voice.user_amp != def.user_amp {
    True -> [
      VoicePill(
        PillAmp,
        "Amp",
        param.format_float(voice.user_amp) <> " dB",
        CatEffects,
        "#23863622",
        "#3fb950",
      ),
      ..pills
    ]
    False -> pills
  }

  let pills = case voice.pan != def.pan {
    True -> [
      VoicePill(
        PillPan,
        "Pan",
        param.format_float(voice.pan),
        CatEffects,
        "#23863622",
        "#3fb950",
      ),
      ..pills
    ]
    False -> pills
  }

  // 3. Filter
  let pills = case voice.filter_mode != def.filter_mode {
    True -> [
      VoicePill(
        PillFilterMode,
        "Filter",
        filter_mode_name(voice.filter_mode),
        CatFilter,
        "#da363322",
        "#f85149",
      ),
      ..pills
    ]
    False -> pills
  }

  let pills = case voice.filter_freq != def.filter_freq {
    True -> [
      VoicePill(
        PillFilterFreq,
        "Cutoff",
        int.to_string(float.round(voice.filter_freq)) <> " Hz",
        CatFilter,
        "#da363322",
        "#f85149",
      ),
      ..pills
    ]
    False -> pills
  }

  let pills = case voice.filter_res != def.filter_res {
    True -> [
      VoicePill(
        PillFilterRes,
        "Res",
        param.format_float(voice.filter_res),
        CatFilter,
        "#da363322",
        "#f85149",
      ),
      ..pills
    ]
    False -> pills
  }

  let pills = case voice.filter_env_depth != def.filter_env_depth {
    True -> [
      VoicePill(
        PillFilterEnvDepth,
        "FEnv Depth",
        param.format_float(voice.filter_env_depth),
        CatFilter,
        "#da363322",
        "#f85149",
      ),
      ..pills
    ]
    False -> pills
  }

  // 4. Envelopes
  let pills = case envs.amp_env != default_amp_env() {
    True -> [
      VoicePill(
        PillAmpEnv,
        "ADSR",
        format_adsr(envs.amp_env),
        CatEnvelope,
        "#8957e522",
        "#bc8cff",
      ),
      ..pills
    ]
    False -> pills
  }

  let pills = case envs.filter_env != default_filter_env() {
    True -> [
      VoicePill(
        PillFilterEnv,
        "Filter ADSR",
        format_adsr(envs.filter_env),
        CatEnvelope,
        "#8957e522",
        "#bc8cff",
      ),
      ..pills
    ]
    False -> pills
  }

  // 5. Modulation & Sync Links
  let pills = case voice.link_sync {
    [t, ..] if t >=. 0.0 -> [
      VoicePill(
        PillLinkSync,
        "Hard Sync",
        "⚡ ➔ v" <> int.to_string(float.round(t)),
        CatLink,
        "#d2992222",
        "#d29922",
      ),
      ..pills
    ]
    _ -> pills
  }

  let pills = case voice.freq_mod_osc >= 0 {
    True -> [
      VoicePill(
        PillLinkFreqMod,
        "FM Mod",
        "🌊 ➔ v"
          <> int.to_string(voice.freq_mod_osc)
          <> " ("
          <> param.format_float(voice.freq_mod_depth)
          <> ")",
        CatLink,
        "#58a6ff22",
        "#58a6ff",
      ),
      ..pills
    ]
    False -> pills
  }

  let pills = case voice.amp_mod_osc >= 0 {
    True -> [
      VoicePill(
        PillLinkAmpMod,
        "AM Mod",
        "📶 ➔ v" <> int.to_string(voice.amp_mod_osc),
        CatLink,
        "#a371f722",
        "#a371f7",
      ),
      ..pills
    ]
    False -> pills
  }

  let pills = case voice.ring_osc >= 0 {
    True -> [
      VoicePill(
        PillLinkRingMod,
        "Ring Mod",
        "🔔 ➔ v" <> int.to_string(voice.ring_osc),
        CatLink,
        "#f0883e22",
        "#f0883e",
      ),
      ..pills
    ]
    False -> pills
  }

  let pills = case voice.cz_mod_osc >= 0 {
    True -> [
      VoicePill(
        PillLinkCzMod,
        "CZ Mod",
        "📐 ➔ v" <> int.to_string(voice.cz_mod_osc),
        CatLink,
        "#bc8cff22",
        "#bc8cff",
      ),
      ..pills
    ]
    False -> pills
  }

  let pills = case voice.pan_mod_osc >= 0 {
    True -> [
      VoicePill(
        PillLinkPanMod,
        "Pan Mod",
        "↔ ➔ v" <> int.to_string(voice.pan_mod_osc),
        CatLink,
        "#3fb95022",
        "#3fb950",
      ),
      ..pills
    ]
    False -> pills
  }

  let pills = case voice.link_midi {
    [t, ..] if t >=. 0.0 -> [
      VoicePill(
        PillLinkMidi,
        "Gate Link",
        "🎹 ➔ v" <> int.to_string(float.round(t)),
        CatLink,
        "#3fb95022",
        "#3fb950",
      ),
      ..pills
    ]
    _ -> pills
  }

  let pills = case voice.link_velo {
    [t, ..] if t >=. 0.0 -> [
      VoicePill(
        PillLinkVelo,
        "Velo Link",
        "💥 ➔ v" <> int.to_string(float.round(t)),
        CatLink,
        "#f8514922",
        "#f85149",
      ),
      ..pills
    ]
    _ -> pills
  }

  // 6. Effects & Shaping
  let pills = case voice.record != 0 {
    True -> [
      VoicePill(
        PillRecordTrack,
        "Record",
        "Track " <> int.to_string(voice.record),
        CatEffects,
        "#d2992222",
        "#d29922",
      ),
      ..pills
    ]
    False -> pills
  }

  let pills = case voice.glissando_enable != 0 || voice.glissando_time >. 0.0 {
    True -> [
      VoicePill(
        PillGlissando,
        "Glide",
        param.format_float(voice.glissando_time) <> "s",
        CatEffects,
        "#d2992222",
        "#d29922",
      ),
      ..pills
    ]
    False -> pills
  }

  let pills = case
    voice.smoother_enable != 0 || voice.smoother_smoothing != 0.0
  {
    True -> [
      VoicePill(
        PillSmoother,
        "Smoother",
        param.format_float(voice.smoother_smoothing),
        CatEffects,
        "#d2992222",
        "#d29922",
      ),
      ..pills
    ]
    False -> pills
  }

  let pills = case voice.cz_mode != 0 || voice.cz_distortion != 0.0 {
    True -> [
      VoicePill(
        PillCzDistortion,
        "CZ Mode / Dist",
        "M"
          <> int.to_string(voice.cz_mode)
          <> " • "
          <> param.format_float(voice.cz_distortion),
        CatModulation,
        "#bc8cff22",
        "#bc8cff",
      ),
      ..pills
    ]
    False -> pills
  }

  let pills = case voice.ring_amount != 0.0 {
    True -> [
      VoicePill(
        PillRingAmount,
        "Ring Amt",
        param.format_float(voice.ring_amount),
        CatModulation,
        "#f0883e22",
        "#f0883e",
      ),
      ..pills
    ]
    False -> pills
  }

  let pills = case voice.sample_hold_ratio != 0.0 {
    True -> [
      VoicePill(
        PillSampleHold,
        "S&H",
        param.format_float(voice.sample_hold_ratio),
        CatEffects,
        "#d2992222",
        "#d29922",
      ),
      ..pills
    ]
    False -> pills
  }

  let pills = case voice.quantize != 0 {
    True -> [
      VoicePill(
        PillQuantize,
        "Quantize",
        int.to_string(voice.quantize),
        CatEffects,
        "#d2992222",
        "#d29922",
      ),
      ..pills
    ]
    False -> pills
  }

  let pills = case voice.delay_send != 0.0 {
    True -> [
      VoicePill(
        PillDelaySend,
        "Delay Send",
        param.format_float(voice.delay_send),
        CatEffects,
        "#23863622",
        "#3fb950",
      ),
      ..pills
    ]
    False -> pills
  }

  let pills = case voice.freq_bend_range != def.freq_bend_range {
    True -> [
      VoicePill(
        PillFreqBend,
        "PB Range",
        param.format_float(voice.freq_bend_range) <> " st",
        CatEffects,
        "#8b949e22",
        "#8b949e",
      ),
      ..pills
    ]
    False -> pills
  }

  let pills = case voice.amp_bend_range != def.amp_bend_range {
    True -> [
      VoicePill(
        PillAmpBend,
        "Amp Bend",
        param.format_float(voice.amp_bend_range) <> " dB",
        CatEffects,
        "#8b949e22",
        "#8b949e",
      ),
      ..pills
    ]
    False -> pills
  }

  list.reverse(pills)
}

// -----------------------------------------------------------------------------
// Master Palette Definitions (89 Schema Parameters Chunked into Musical Swatches)
// -----------------------------------------------------------------------------

fn get_master_palette() -> List(PaletteItem) {
  [
    // 🌊 Tone & Pitch
    PaletteItem(
      PillWave,
      "w",
      "Waveform",
      "Sine, Tri, Saw, Square, Noise, DW8000, ESQ1, Drums",
      CatWavePitch,
      "#1f6feb22",
      "#58a6ff",
    ),
    PaletteItem(
      PillFreq,
      "f",
      "Frequency",
      "Direct Hz pitch frequency (20 to 20000 Hz)",
      CatWavePitch,
      "#1f6feb22",
      "#58a6ff",
    ),
    PaletteItem(
      PillNote,
      "n",
      "MIDI Note",
      "Equal-tempered semitone pitch (0 to 127)",
      CatWavePitch,
      "#1f6feb22",
      "#58a6ff",
    ),
    PaletteItem(
      PillFreqBend,
      "bp",
      "Pitch Bend",
      "Pitch wheel deflection range (semitones)",
      CatWavePitch,
      "#1f6feb22",
      "#58a6ff",
    ),

    // 🎛 Filter & Color
    PaletteItem(
      PillFilterFreq,
      "k",
      "Filter Cutoff",
      "12dB multimode biquad cutoff frequency in Hz",
      CatFilter,
      "#da363322",
      "#f85149",
    ),
    PaletteItem(
      PillFilterRes,
      "q",
      "Resonance (Q)",
      "Filter resonance peak / bandwidth factor",
      CatFilter,
      "#da363322",
      "#f85149",
    ),
    PaletteItem(
      PillFilterMode,
      "j",
      "Filter Mode",
      "LowPass (1), HighPass (2), BandPass (3), Bypass (0)",
      CatFilter,
      "#da363322",
      "#f85149",
    ),
    PaletteItem(
      PillFilterEnvDepth,
      "kd",
      "FEnv Depth",
      "Bipolar envelope cutoff modulation depth",
      CatFilter,
      "#da363322",
      "#f85149",
    ),
    PaletteItem(
      PillFilterEnv,
      "kt",
      "Filter ADSR",
      "Dedicated filter attack, decay, sustain, release",
      CatFilter,
      "#da363322",
      "#f85149",
    ),

    // 📈 Dynamics & Envelopes
    PaletteItem(
      PillAmpEnv,
      "t",
      "Amp ADSR",
      "Amplitude envelope contour (a, d, s, r)",
      CatEnvelope,
      "#8957e522",
      "#bc8cff",
    ),
    PaletteItem(
      PillAmp,
      "a",
      "Gain Level",
      "Master voice amplitude in decibels (-48 to +12 dB)",
      CatEnvelope,
      "#8957e522",
      "#bc8cff",
    ),
    PaletteItem(
      PillPan,
      "p",
      "Stereo Pan",
      "Stereo positioning field (-1.0 Left to +1.0 Right)",
      CatEnvelope,
      "#8957e522",
      "#bc8cff",
    ),
    PaletteItem(
      PillAmpBend,
      "abp",
      "Amp Bend",
      "Amplitude wheel expression range in dB",
      CatEnvelope,
      "#8957e522",
      "#bc8cff",
    ),
    PaletteItem(
      PillDelaySend,
      "del",
      "Delay Send",
      "Studio stereo ping-pong delay send level",
      CatEnvelope,
      "#8957e522",
      "#bc8cff",
    ),

    // ⚡ Cross-Modulation & Distortion
    PaletteItem(
      PillLinkFreqMod,
      "FM",
      "FM Modulator",
      "Cross-voice frequency modulation from target voice",
      CatModulation,
      "#58a6ff22",
      "#58a6ff",
    ),
    PaletteItem(
      PillLinkAmpMod,
      "am",
      "AM Modulator",
      "Dynamic amplitude modulation from target voice",
      CatModulation,
      "#a371f722",
      "#a371f7",
    ),
    PaletteItem(
      PillLinkRingMod,
      "XM",
      "Ring Modulator",
      "Four-quadrant audio rate cross-voice multiplication",
      CatModulation,
      "#f0883e22",
      "#f0883e",
    ),
    PaletteItem(
      PillLinkCzMod,
      "cmod",
      "CZ Phase Mod",
      "Dynamic Casio CZ phase distortion modulator",
      CatModulation,
      "#bc8cff22",
      "#bc8cff",
    ),
    PaletteItem(
      PillCzDistortion,
      "czd",
      "CZ Distortion",
      "Phase distortion factor / waveform warp coefficient",
      CatModulation,
      "#bc8cff22",
      "#bc8cff",
    ),
    PaletteItem(
      PillLinkPanMod,
      "pm",
      "Pan Modulator",
      "Audio-rate cross-voice stereo auto-panning",
      CatModulation,
      "#3fb95022",
      "#3fb950",
    ),
    PaletteItem(
      PillSampleHold,
      "sh",
      "Sample & Hold",
      "Stepped decimator / sample rate reduction ratio",
      CatModulation,
      "#d2992222",
      "#d29922",
    ),
    PaletteItem(
      PillRingAmount,
      "xm",
      "Ring Amount",
      "Static ring modulation mix depth",
      CatModulation,
      "#f0883e22",
      "#f0883e",
    ),

    // 🔗 Topology & Performance Links
    PaletteItem(
      PillLinkSync,
      "HS",
      "Hard Sync",
      "Bandlimited PolyBLEP phase reset link to target voice",
      CatLink,
      "#d2992222",
      "#d29922",
    ),
    PaletteItem(
      PillLinkMidi,
      "G",
      "Gate Follower",
      "Slave voice pitch and trigger follower link",
      CatLink,
      "#3fb95022",
      "#3fb950",
    ),
    PaletteItem(
      PillLinkVelo,
      "H",
      "Velocity Follower",
      "Dynamic note velocity tracking link",
      CatLink,
      "#f8514922",
      "#f85149",
    ),
    PaletteItem(
      PillGlissando,
      "gl, gt",
      "Glissando / Portamento",
      "Pitch glide / glissando slew rate in seconds",
      CatEffects,
      "#d2992222",
      "#d29922",
    ),
    PaletteItem(
      PillSmoother,
      "sm",
      "Parameter Smoother",
      "One-pole parameter interpolation filter / de-zipper",
      CatEffects,
      "#d2992222",
      "#d29922",
    ),
    PaletteItem(
      PillQuantize,
      "qnt",
      "Quantizer",
      "Scale quantizer (12-EDO, quarter-tones)",
      CatLink,
      "#d2992222",
      "#d29922",
    ),
  ]
}

// -----------------------------------------------------------------------------
// Pinned Pills Management Helpers
// -----------------------------------------------------------------------------

fn pin_pill(model: Model, voice_id: Int, pill_id: PillId) -> Model {
  case list.contains(model.pinned_pills, #(voice_id, pill_id)) {
    True -> model
    False ->
      Model(..model, pinned_pills: [#(voice_id, pill_id), ..model.pinned_pills])
  }
}

fn unpin_pill(model: Model, voice_id: Int, pill_id: PillId) -> Model {
  Model(
    ..model,
    pinned_pills: list.filter(model.pinned_pills, fn(pair) {
      pair != #(voice_id, pill_id)
    }),
  )
}

fn toggle_pinned_pill(model: Model, voice_id: Int, pill_id: PillId) -> Model {
  case list.contains(model.pinned_pills, #(voice_id, pill_id)) {
    True -> unpin_pill(model, voice_id, pill_id)
    False -> pin_pill(model, voice_id, pill_id)
  }
}

// -----------------------------------------------------------------------------
// Update & State Transitions
// -----------------------------------------------------------------------------

fn apply_voice_update(
  model: Model,
  voice_id: Int,
  update_fn: fn(Voice) -> Voice,
) -> #(Model, Effect(Msg)) {
  let #(target_voice, current_voices) =
    get_or_create_voice(model.all_voices, voice_id)
  let updated_voice = update_fn(target_voice)
  let diff_tokens = diff_gen.diff_voice_skode(target_voice, updated_voice)
  let updated_all = update_voice_in_list(current_voices, updated_voice)

  let active_v = case model.voice.id == voice_id {
    True -> updated_voice
    False -> model.voice
  }

  let next_model =
    Model(
      ..model,
      voice: active_v,
      last_dispatched: active_v,
      all_voices: updated_all,
    )

  case model.auto_dispatch && !list.is_empty(diff_tokens) {
    True -> {
      let cmd = string.join(diff_tokens, " ")
      #(next_model, dispatch_skode_effect(cmd))
    }
    False -> #(next_model, effect.none())
  }
}

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    // Voice navigation
    SetVoiceId(id) -> {
      let clamped = int.clamp(id, 0, 255)
      let #(target_v, updated_all) =
        get_or_create_voice(model.all_voices, clamped)
      let next_model =
        Model(
          ..model,
          voice: target_v,
          last_dispatched: target_v,
          all_voices: updated_all,
          voice_jump_input: int.to_string(clamped),
        )
      #(next_model, effect.none())
    }

    StepVoice(delta) -> {
      let next_id = int.clamp(model.voice.id + delta, 0, 255)
      let #(target_v, updated_all) =
        get_or_create_voice(model.all_voices, next_id)
      let next_model =
        Model(
          ..model,
          voice: target_v,
          last_dispatched: target_v,
          all_voices: updated_all,
          voice_jump_input: int.to_string(next_id),
        )
      #(next_model, effect.none())
    }

    JumpNextConfigured -> {
      let configured = get_configured_voices(model.all_voices, model.voice.id)
      let configured_ids = list.map(configured, fn(v) { v.id })
      let higher_ids =
        list.filter(configured_ids, fn(id) { id > model.voice.id })
      let next_id = case higher_ids {
        [first, ..] -> first
        [] ->
          case configured_ids {
            [first, ..] -> first
            [] -> model.voice.id
          }
      }
      let #(target_v, updated_all) =
        get_or_create_voice(model.all_voices, next_id)
      #(
        Model(
          ..model,
          voice: target_v,
          last_dispatched: target_v,
          all_voices: updated_all,
          voice_jump_input: int.to_string(next_id),
        ),
        effect.none(),
      )
    }

    JumpPrevConfigured -> {
      let configured = get_configured_voices(model.all_voices, model.voice.id)
      let configured_ids = list.map(configured, fn(v) { v.id })
      let lower_ids =
        list.filter(configured_ids, fn(id) { id < model.voice.id })
      let prev_id = case list.reverse(lower_ids) {
        [last, ..] -> last
        [] ->
          case list.reverse(configured_ids) {
            [last, ..] -> last
            [] -> model.voice.id
          }
      }
      let #(target_v, updated_all) =
        get_or_create_voice(model.all_voices, prev_id)
      #(
        Model(
          ..model,
          voice: target_v,
          last_dispatched: target_v,
          all_voices: updated_all,
          voice_jump_input: int.to_string(prev_id),
        ),
        effect.none(),
      )
    }

    SetVoiceJumpInput(str) -> {
      #(Model(..model, voice_jump_input: str), effect.none())
    }

    SubmitVoiceJump -> {
      case int.parse(string.trim(model.voice_jump_input)) {
        Ok(id) if id >= 0 && id <= 255 -> {
          let #(target_v, updated_all) =
            get_or_create_voice(model.all_voices, id)
          #(
            Model(
              ..model,
              voice: target_v,
              last_dispatched: target_v,
              all_voices: updated_all,
              voice_jump_input: int.to_string(id),
            ),
            effect.none(),
          )
        }
        _ -> #(model, effect.none())
      }
    }

    // Pill Inspector Management
    SelectVoicePill(voice_id, pill_id) -> {
      #(pin_pill(model, voice_id, pill_id), effect.none())
    }

    ToggleVoicePill(voice_id, pill_id) -> {
      #(toggle_pinned_pill(model, voice_id, pill_id), effect.none())
    }

    ClosePillInspector -> {
      #(Model(..model, pinned_pills: []), effect.none())
    }

    CloseSinglePill(voice_id, pill_id) -> {
      #(unpin_pill(model, voice_id, pill_id), effect.none())
    }

    ClearAllPinnedPills -> {
      #(Model(..model, pinned_pills: []), effect.none())
    }

    CloseVoicePinnedPills(vid) -> {
      let remaining =
        list.filter(model.pinned_pills, fn(pair) { pair.0 != vid })
      #(Model(..model, pinned_pills: remaining), effect.none())
    }

    StartDragPill(idx) -> {
      #(Model(..model, dragged_pill_index: Some(idx)), effect.none())
    }

    DragOverPill(_) -> {
      #(model, effect.none())
    }

    DropPill(target_idx) -> {
      case model.dragged_pill_index {
        Some(from_idx) -> {
          let reordered =
            move_list_item(model.pinned_pills, from_idx, target_idx)
          #(
            Model(..model, pinned_pills: reordered, dragged_pill_index: None),
            effect.none(),
          )
        }
        None -> #(model, effect.none())
      }
    }

    ShiftPinnedPill(idx, delta) -> {
      let target_idx = idx + delta
      let reordered = move_list_item(model.pinned_pills, idx, target_idx)
      #(Model(..model, pinned_pills: reordered), effect.none())
    }

    ToggleAddMenu(voice_id) -> {
      let next_menu = case model.show_add_menu == Some(voice_id) {
        True -> None
        False -> Some(voice_id)
      }
      #(Model(..model, show_add_menu: next_menu), effect.none())
    }

    TogglePalette -> {
      #(Model(..model, palette_open: !model.palette_open), effect.none())
    }

    SetPaletteSearch(query) -> {
      #(Model(..model, palette_search: query), effect.none())
    }

    SetWaveSearch(query) -> {
      #(Model(..model, wave_search: query), effect.none())
    }

    SetVoiceWaveSearch(vid, query) -> {
      let next_searches = dict.insert(model.voice_wave_search, vid, query)
      #(Model(..model, voice_wave_search: next_searches), effect.none())
    }

    StepVoiceWave(vid, delta) -> {
      let #(target_v, _) = get_or_create_voice(model.all_voices, vid)
      let next_w = step_wave_index(target_v.wave_table_index, delta)
      update(model, UpdateVoiceWave(vid, next_w))
    }

    AddVoiceParam(voice_id, pill_id) -> {
      let model_with_menu_closed = Model(..model, show_add_menu: None)
      let m = pin_pill(model_with_menu_closed, voice_id, pill_id)
      #(m, effect.none())
    }

    ResetVoiceParam(voice_id, pill_id) -> {
      let def = voice_gen.default(voice_id)
      let next_model = unpin_pill(model, voice_id, pill_id)
      case pill_id {
        PillWave ->
          apply_voice_update(next_model, voice_id, fn(v) {
            Voice(..v, wave_table_index: def.wave_table_index)
          })
        PillFreq ->
          apply_voice_update(next_model, voice_id, fn(v) {
            Voice(..v, freq: def.freq, pitch_mode: def.pitch_mode)
          })
        PillNote ->
          apply_voice_update(next_model, voice_id, fn(v) {
            Voice(..v, midi_note: def.midi_note, pitch_mode: def.pitch_mode)
          })
        PillPitchMode ->
          apply_voice_update(next_model, voice_id, fn(v) {
            Voice(..v, pitch_mode: def.pitch_mode)
          })
        PillAmp ->
          apply_voice_update(next_model, voice_id, fn(v) {
            Voice(..v, user_amp: def.user_amp)
          })
        PillPan ->
          apply_voice_update(next_model, voice_id, fn(v) {
            Voice(..v, pan: def.pan)
          })
        PillFilterMode ->
          apply_voice_update(next_model, voice_id, fn(v) {
            Voice(..v, filter_mode: def.filter_mode)
          })
        PillFilterFreq ->
          apply_voice_update(next_model, voice_id, fn(v) {
            Voice(..v, filter_freq: def.filter_freq)
          })
        PillFilterRes ->
          apply_voice_update(next_model, voice_id, fn(v) {
            Voice(..v, filter_res: def.filter_res)
          })
        PillFilterEnvDepth ->
          apply_voice_update(next_model, voice_id, fn(v) {
            Voice(
              ..v,
              filter_env_depth: def.filter_env_depth,
              use_filter_envelope: 0,
            )
          })
        PillAmpEnv -> {
          let envs = get_voice_envelopes(next_model, voice_id)
          let reset_envs = VoiceEnvelopes(..envs, amp_env: default_amp_env())
          let m = set_voice_envelopes(next_model, voice_id, reset_envs)
          let cmd =
            "v"
            <> int.to_string(voice_id)
            <> " t "
            <> format_adsr(default_amp_env())
          #(m, dispatch_skode_effect(cmd))
        }
        PillFilterEnv -> {
          let envs = get_voice_envelopes(next_model, voice_id)
          let reset_envs =
            VoiceEnvelopes(..envs, filter_env: default_filter_env())
          let m = set_voice_envelopes(next_model, voice_id, reset_envs)
          let cmd =
            "v"
            <> int.to_string(voice_id)
            <> " kt "
            <> format_adsr(default_filter_env())
          #(m, dispatch_skode_effect(cmd))
        }
        PillLinkSync ->
          apply_voice_update(next_model, voice_id, fn(v) {
            Voice(..v, link_sync: [])
          })
        PillLinkFreqMod ->
          apply_voice_update(next_model, voice_id, fn(v) {
            Voice(..v, freq_mod_osc: -1, freq_mod_depth: 0.0)
          })
        PillLinkAmpMod ->
          apply_voice_update(next_model, voice_id, fn(v) {
            Voice(..v, amp_mod_osc: -1, amp_mod_depth: 0.0)
          })
        PillLinkRingMod ->
          apply_voice_update(next_model, voice_id, fn(v) {
            Voice(..v, ring_osc: -1, ring_amount: 0.0)
          })
        PillLinkCzMod ->
          apply_voice_update(next_model, voice_id, fn(v) {
            Voice(..v, cz_mod_osc: -1, cz_mod_depth: 0.0)
          })
        PillLinkPanMod ->
          apply_voice_update(next_model, voice_id, fn(v) {
            Voice(..v, pan_mod_osc: -1, pan_mod_depth: 0.0)
          })
        PillLinkMidi ->
          apply_voice_update(next_model, voice_id, fn(v) {
            Voice(..v, link_midi: [])
          })
        PillLinkVelo ->
          apply_voice_update(next_model, voice_id, fn(v) {
            Voice(..v, link_velo: [])
          })
        PillGlissando ->
          apply_voice_update(next_model, voice_id, fn(v) {
            Voice(..v, glissando_enable: 0, glissando_time: 0.0)
          })
        PillSmoother ->
          apply_voice_update(next_model, voice_id, fn(v) {
            Voice(..v, smoother_enable: 0, smoother_smoothing: 0.0)
          })
        PillCzDistortion ->
          apply_voice_update(next_model, voice_id, fn(v) {
            Voice(..v, cz_mode: 0, cz_distortion: 0.0)
          })
        PillRingAmount ->
          apply_voice_update(next_model, voice_id, fn(v) {
            Voice(..v, ring_amount: 0.0)
          })
        PillSampleHold ->
          apply_voice_update(next_model, voice_id, fn(v) {
            Voice(..v, sample_hold_ratio: 0.0)
          })
        PillQuantize ->
          apply_voice_update(next_model, voice_id, fn(v) {
            Voice(..v, quantize: 0)
          })
        PillDelaySend ->
          apply_voice_update(next_model, voice_id, fn(v) {
            Voice(..v, delay_send: 0.0)
          })
        PillFreqBend ->
          apply_voice_update(next_model, voice_id, fn(v) {
            Voice(..v, freq_bend_range: def.freq_bend_range)
          })
        PillAmpBend ->
          apply_voice_update(next_model, voice_id, fn(v) {
            Voice(..v, amp_bend_range: def.amp_bend_range)
          })
        PillRecordTrack ->
          apply_voice_update(next_model, voice_id, fn(v) {
            Voice(..v, record: def.record)
          })
      }
    }

    // Direct parameter updates (voice_id parameterized)
    UpdateVoiceWave(vid, idx) -> {
      let #(next_m, eff) =
        apply_voice_update(model, vid, fn(v) {
          Voice(..v, wave_table_index: param_gen.clamp_wave_table_index(idx))
        })
      let wave_eff =
        effect.from(fn(_) {
          render_waveform_buffer("voice-wave-" <> int.to_string(vid), idx)
          Nil
        })
      #(next_m, effect.batch([eff, wave_eff]))
    }

    UpdateVoiceFreq(vid, val) -> {
      apply_voice_update(model, vid, fn(v) {
        Voice(..v, freq: param_gen.clamp_freq(val), pitch_mode: 0)
      })
    }

    UpdateVoiceNote(vid, val) -> {
      apply_voice_update(model, vid, fn(v) {
        Voice(..v, midi_note: param_gen.clamp_midi_note(val), pitch_mode: 1)
      })
    }

    UpdateVoicePitchMode(vid, val) -> {
      apply_voice_update(model, vid, fn(v) {
        Voice(..v, pitch_mode: param_gen.clamp_pitch_mode(val))
      })
    }

    UpdateVoiceAmp(vid, val) -> {
      apply_voice_update(model, vid, fn(v) {
        Voice(..v, user_amp: param_gen.clamp_user_amp(val))
      })
    }

    UpdateVoicePan(vid, val) -> {
      apply_voice_update(model, vid, fn(v) {
        Voice(..v, pan: param_gen.clamp_pan(val))
      })
    }

    UpdateVoiceFilterMode(vid, val) -> {
      apply_voice_update(model, vid, fn(v) {
        Voice(..v, filter_mode: param_gen.clamp_filter_mode(val))
      })
    }

    UpdateVoiceFilterFreq(vid, val) -> {
      apply_voice_update(model, vid, fn(v) {
        Voice(..v, filter_freq: param_gen.clamp_filter_freq(val))
      })
    }

    UpdateVoiceFilterRes(vid, val) -> {
      apply_voice_update(model, vid, fn(v) {
        Voice(..v, filter_res: param_gen.clamp_filter_res(val))
      })
    }

    UpdateVoiceFilterEnvDepth(vid, val) -> {
      apply_voice_update(model, vid, fn(v) {
        Voice(
          ..v,
          filter_env_depth: param_gen.clamp_filter_env_depth(val),
          use_filter_envelope: case val != 0.0 {
            True -> 1
            False -> 0
          },
        )
      })
    }

    UpdateVoiceAmpAttack(vid, val) -> {
      let envs = get_voice_envelopes(model, vid)
      let next_env =
        Envelope(..envs.amp_env, attack: float.clamp(val, 0.001, 10.0))
      let updated_envs = VoiceEnvelopes(..envs, amp_env: next_env)
      let next_m = set_voice_envelopes(model, vid, updated_envs)
      let cmd = "v" <> int.to_string(vid) <> " t " <> format_adsr(next_env)
      #(next_m, dispatch_skode_effect(cmd))
    }

    UpdateVoiceAmpDecay(vid, val) -> {
      let envs = get_voice_envelopes(model, vid)
      let next_env =
        Envelope(..envs.amp_env, decay: float.clamp(val, 0.001, 10.0))
      let updated_envs = VoiceEnvelopes(..envs, amp_env: next_env)
      let next_m = set_voice_envelopes(model, vid, updated_envs)
      let cmd = "v" <> int.to_string(vid) <> " t " <> format_adsr(next_env)
      #(next_m, dispatch_skode_effect(cmd))
    }

    UpdateVoiceAmpSustain(vid, val) -> {
      let envs = get_voice_envelopes(model, vid)
      let next_env =
        Envelope(..envs.amp_env, sustain: float.clamp(val, 0.0, 1.0))
      let updated_envs = VoiceEnvelopes(..envs, amp_env: next_env)
      let next_m = set_voice_envelopes(model, vid, updated_envs)
      let cmd = "v" <> int.to_string(vid) <> " t " <> format_adsr(next_env)
      #(next_m, dispatch_skode_effect(cmd))
    }

    UpdateVoiceAmpRelease(vid, val) -> {
      let envs = get_voice_envelopes(model, vid)
      let next_env =
        Envelope(..envs.amp_env, release: float.clamp(val, 0.0, 10.0))
      let updated_envs = VoiceEnvelopes(..envs, amp_env: next_env)
      let next_m = set_voice_envelopes(model, vid, updated_envs)
      let cmd = "v" <> int.to_string(vid) <> " t " <> format_adsr(next_env)
      #(next_m, dispatch_skode_effect(cmd))
    }

    UpdateVoiceFilterAttack(vid, val) -> {
      let envs = get_voice_envelopes(model, vid)
      let next_env =
        Envelope(..envs.filter_env, attack: float.clamp(val, 0.001, 10.0))
      let updated_envs = VoiceEnvelopes(..envs, filter_env: next_env)
      let next_m = set_voice_envelopes(model, vid, updated_envs)
      let cmd = "v" <> int.to_string(vid) <> " kt " <> format_adsr(next_env)
      #(next_m, dispatch_skode_effect(cmd))
    }

    UpdateVoiceFilterDecay(vid, val) -> {
      let envs = get_voice_envelopes(model, vid)
      let next_env =
        Envelope(..envs.filter_env, decay: float.clamp(val, 0.001, 10.0))
      let updated_envs = VoiceEnvelopes(..envs, filter_env: next_env)
      let next_m = set_voice_envelopes(model, vid, updated_envs)
      let cmd = "v" <> int.to_string(vid) <> " kt " <> format_adsr(next_env)
      #(next_m, dispatch_skode_effect(cmd))
    }

    UpdateVoiceFilterSustain(vid, val) -> {
      let envs = get_voice_envelopes(model, vid)
      let next_env =
        Envelope(..envs.filter_env, sustain: float.clamp(val, 0.0, 1.0))
      let updated_envs = VoiceEnvelopes(..envs, filter_env: next_env)
      let next_m = set_voice_envelopes(model, vid, updated_envs)
      let cmd = "v" <> int.to_string(vid) <> " kt " <> format_adsr(next_env)
      #(next_m, dispatch_skode_effect(cmd))
    }

    UpdateVoiceFilterRelease(vid, val) -> {
      let envs = get_voice_envelopes(model, vid)
      let next_env =
        Envelope(..envs.filter_env, release: float.clamp(val, 0.0, 10.0))
      let updated_envs = VoiceEnvelopes(..envs, filter_env: next_env)
      let next_m = set_voice_envelopes(model, vid, updated_envs)
      let cmd = "v" <> int.to_string(vid) <> " kt " <> format_adsr(next_env)
      #(next_m, dispatch_skode_effect(cmd))
    }

    UpdateVoiceGlissandoTime(vid, val) -> {
      apply_voice_update(model, vid, fn(v) {
        Voice(
          ..v,
          glissando_time: param_gen.clamp_glissando_time(val),
          glissando_enable: case val >. 0.0 {
            True -> 1
            False -> 0
          },
        )
      })
    }

    UpdateVoiceSmoother(vid, val) -> {
      apply_voice_update(model, vid, fn(v) {
        Voice(
          ..v,
          smoother_smoothing: param_gen.clamp_smoother_smoothing(val),
          smoother_enable: case val >. 0.0 {
            True -> 1
            False -> 0
          },
        )
      })
    }

    UpdateVoiceGlissandoEnable(vid, en) -> {
      apply_voice_update(model, vid, fn(v) {
        Voice(..v, glissando_enable: int.clamp(en, 0, 1))
      })
    }

    UpdateVoiceCzMode(vid, mode) -> {
      apply_voice_update(model, vid, fn(v) {
        Voice(..v, cz_mode: param_gen.clamp_cz_mode(mode))
      })
    }

    UpdateVoiceCzDistortion(vid, val) -> {
      apply_voice_update(model, vid, fn(v) {
        Voice(
          ..v,
          cz_distortion: param_gen.clamp_cz_distortion(val),
          cz_mode: case v.cz_mode == 0 && val >. 0.0 {
            True -> 1
            False -> v.cz_mode
          },
        )
      })
    }

    UpdateVoiceRecord(vid, trk) -> {
      apply_voice_update(model, vid, fn(v) {
        Voice(..v, record: int.clamp(trk, 0, 15))
      })
    }

    UpdateVoiceRingAmount(vid, val) -> {
      apply_voice_update(model, vid, fn(v) {
        Voice(..v, ring_amount: param_gen.clamp_ring_amount(val))
      })
    }

    UpdateVoiceSampleHold(vid, val) -> {
      apply_voice_update(model, vid, fn(v) {
        Voice(..v, sample_hold_ratio: param_gen.clamp_sample_hold_ratio(val))
      })
    }

    UpdateVoiceQuantize(vid, val) -> {
      apply_voice_update(model, vid, fn(v) {
        Voice(..v, quantize: param_gen.clamp_quantize(val))
      })
    }

    UpdateVoiceDelaySend(vid, val) -> {
      apply_voice_update(model, vid, fn(v) {
        Voice(..v, delay_send: param_gen.clamp_delay_send(val))
      })
    }

    UpdateVoiceFreqBend(vid, val) -> {
      apply_voice_update(model, vid, fn(v) {
        Voice(..v, freq_bend_range: param_gen.clamp_freq_bend_range(val))
      })
    }

    UpdateVoiceAmpBend(vid, val) -> {
      apply_voice_update(model, vid, fn(v) {
        Voice(..v, amp_bend_range: param_gen.clamp_amp_bend_range(val))
      })
    }

    // Link updates (0..255)
    UpdateVoiceLinkSync(vid, target) -> {
      let sync_list = case target >= 0 && target <= 255 && target != vid {
        True -> [int.to_float(target)]
        False -> []
      }
      apply_voice_update(model, vid, fn(v) { Voice(..v, link_sync: sync_list) })
    }

    UpdateVoiceLinkFreqMod(vid, target) -> {
      let tgt = case target >= 0 && target <= 255 && target != vid {
        True -> target
        False -> -1
      }
      apply_voice_update(model, vid, fn(v) {
        Voice(..v, freq_mod_osc: tgt, freq_mod_depth: case tgt >= 0 {
          True ->
            case v.freq_mod_depth == 0.0 {
              True -> 2.0
              False -> v.freq_mod_depth
            }
          False -> 0.0
        })
      })
    }

    UpdateVoiceFreqModDepth(vid, d) -> {
      apply_voice_update(model, vid, fn(v) {
        Voice(..v, freq_mod_depth: param_gen.clamp_freq_mod_depth(d))
      })
    }

    UpdateVoiceLinkAmpMod(vid, target) -> {
      let tgt = case target >= 0 && target <= 255 && target != vid {
        True -> target
        False -> -1
      }
      apply_voice_update(model, vid, fn(v) {
        Voice(..v, amp_mod_osc: tgt, amp_mod_depth: case tgt >= 0 {
          True ->
            case v.amp_mod_depth == 0.0 {
              True -> 0.5
              False -> v.amp_mod_depth
            }
          False -> 0.0
        })
      })
    }

    UpdateVoiceLinkRingMod(vid, target) -> {
      let tgt = case target >= 0 && target <= 255 && target != vid {
        True -> target
        False -> -1
      }
      apply_voice_update(model, vid, fn(v) {
        Voice(..v, ring_osc: tgt, ring_amount: case tgt >= 0 {
          True ->
            case v.ring_amount == 0.0 {
              True -> 0.8
              False -> v.ring_amount
            }
          False -> 0.0
        })
      })
    }

    UpdateVoiceLinkCzMod(vid, target) -> {
      let tgt = case target >= 0 && target <= 255 && target != vid {
        True -> target
        False -> -1
      }
      apply_voice_update(model, vid, fn(v) {
        Voice(..v, cz_mod_osc: tgt, cz_mod_depth: case tgt >= 0 {
          True ->
            case v.cz_mod_depth == 0.0 {
              True -> 0.5
              False -> v.cz_mod_depth
            }
          False -> 0.0
        })
      })
    }

    UpdateVoiceLinkPanMod(vid, target) -> {
      let tgt = case target >= 0 && target <= 255 && target != vid {
        True -> target
        False -> -1
      }
      apply_voice_update(model, vid, fn(v) {
        Voice(..v, pan_mod_osc: tgt, pan_mod_depth: case tgt >= 0 {
          True ->
            case v.pan_mod_depth == 0.0 {
              True -> 0.5
              False -> v.pan_mod_depth
            }
          False -> 0.0
        })
      })
    }

    UpdateVoiceLinkMidi(vid, target) -> {
      let midi_list = case target >= 0 && target <= 255 && target != vid {
        True -> [int.to_float(target)]
        False -> []
      }
      apply_voice_update(model, vid, fn(v) { Voice(..v, link_midi: midi_list) })
    }

    UpdateVoiceLinkVelo(vid, target) -> {
      let velo_list = case target >= 0 && target <= 255 && target != vid {
        True -> [int.to_float(target)]
        False -> []
      }
      apply_voice_update(model, vid, fn(v) { Voice(..v, link_velo: velo_list) })
    }

    // Global Actions
    ToggleAutoDispatch -> {
      #(Model(..model, auto_dispatch: !model.auto_dispatch), effect.none())
    }

    TriggerVoiceId(vid) -> {
      let cmd = "v" <> int.to_string(vid) <> " l1"
      #(model, dispatch_skode_effect(cmd))
    }

    ResetVoiceId(vid) -> {
      let def = voice_gen.default(vid)
      let updated_all = update_voice_in_list(model.all_voices, def)
      let reset_envs =
        list.key_set(model.all_envelopes, vid, default_voice_envelopes())
      let active_v = case model.voice.id == vid {
        True -> def
        False -> model.voice
      }
      let next_m =
        Model(
          ..model,
          voice: active_v,
          last_dispatched: active_v,
          all_voices: updated_all,
          all_envelopes: reset_envs,
        )
      #(next_m, dispatch_skode_effect("v" <> int.to_string(vid) <> " reset"))
    }

    CopySkodeText -> {
      let active_cmd = voice_gen.to_skode(model.voice)
      #(model, copy_effect(active_cmd))
    }

    CopyCustomText(txt) -> {
      #(model, copy_effect(txt))
    }

    ApplyPreset(name) -> {
      let preset_cmd = case name {
        "Acid Lead" -> "v0 w 2 f 110 j 1 k 800 q 12.0 a -4"
        "Hard-Sync Lead" -> "v0 w 1 f 220 a -3 HS 1 v1 w 2 f 660 a -6"
        "FM 2-Op Lead" -> "v0 w 0 f 440 a -3 FM 1 v1 w 0 f 880 a -12"
        "Table Noise" -> "v0 w 5 f 330 k 2500 q 4.0 a -6"
        "PRNG White Noise" -> "v0 w 6 k 3000 q 1.0 a -6"
        "CZ Phase Crunch" -> "v0 w 0 cz 1 czd 0.8 a -4"
        _ -> "v0 w 0 f 440 a -6"
      }
      let #(new_all, new_envs, final_vid, touched_pills) =
        apply_skode_string_to_state(
          model.all_voices,
          model.all_envelopes,
          model.voice.id,
          preset_cmd,
        )
      let #(cur_voice, _) = get_or_create_voice(new_all, final_vid)
      let next_pinned =
        list.unique(list.append(touched_pills, model.pinned_pills))
      let output = send_skode_command(preset_cmd)
      let new_log =
        CommandLog(
          id: list.length(model.command_logs) + 1,
          raw_cmd: preset_cmd,
          tokens: tokenize_skode_string(preset_cmd),
          summary: "Preset '"
            <> name
            <> "' applied to v"
            <> int.to_string(final_vid),
          output: output,
        )
      let next_model =
        Model(
          ..model,
          voice: cur_voice,
          last_dispatched: cur_voice,
          all_voices: new_all,
          all_envelopes: new_envs,
          pinned_pills: next_pinned,
          notification: Some("Applied preset: " <> name),
          history: [
            preset_cmd,
            ..list.filter(model.history, fn(h) { h != preset_cmd })
          ],
          command_logs: [new_log, ..list.take(model.command_logs, 49)],
        )
      #(next_model, effect.none())
    }

    SetInputCommand(str) -> {
      #(Model(..model, input_command: str), effect.none())
    }

    SubmitInputCommand -> {
      let raw = string.trim(model.input_command)
      case raw {
        "" -> #(model, effect.none())
        cmd -> {
          case string.contains(cmd, "\n") {
            True -> {
              let updated_model = apply_skode_script_to_model(model, cmd)
              let new_log =
                CommandLog(
                  id: list.length(model.command_logs) + 1,
                  raw_cmd: cmd,
                  tokens: ["<script>"],
                  summary: "Executed multi-line script ("
                    <> int.to_string(list.length(updated_model.all_voices))
                    <> " voices, "
                    <> int.to_string(list.length(updated_model.all_patterns))
                    <> " patterns)",
                  output: "Script executed and synced to studio state",
                )
              #(
                Model(
                  ..updated_model,
                  input_command: "",
                  notification: Some("Multi-line script executed"),
                  history: [
                    cmd,
                    ..list.filter(model.history, fn(h) { h != cmd })
                  ],
                  command_logs: [new_log, ..list.take(model.command_logs, 49)],
                ),
                effect.none(),
              )
            }
            False -> {
              let parsed_toks = tokenize_skode_string(cmd)
              let output = send_skode_command(cmd)

              // 1. Check for Pattern pointer or pattern modifications (y<N>, %, z, zmu, etc.)
              let #(pattern_changes, maybe_new_pid, updated_patterns_base) =
                parse_pattern_command_line(
                  parsed_toks,
                  model.active_pattern_id,
                  model.all_patterns,
                )

              // 1b. Check for Pattern Reset (Y or Y<pid>)
              let active_p_target = case maybe_new_pid {
                Some(pid) -> pid
                None -> model.active_pattern_id
              }
              let updated_patterns_reset = case
                parse_pattern_reset(parsed_toks, active_p_target)
              {
                Some(r_pid) -> {
                  let #(_p, all_p) =
                    get_or_create_pattern(updated_patterns_base, r_pid)
                  update_pattern_in_list(all_p, pattern.default(r_pid))
                }
                None -> updated_patterns_base
              }

              // 1c. Parse bracketed pattern steps: [<code inside>] x<step>
              let parsed_steps = parse_skode_steps_string(cmd, active_p_target)
              let updated_patterns =
                apply_parsed_steps_to_patterns(
                  updated_patterns_reset,
                  parsed_steps,
                )

              // 2. Check for Delay pointer (d0..d3)
              let maybe_new_did = parse_delay_pointer(parsed_toks)

              // 3. Check for Voice pointer (v0..v255)
              let maybe_new_vid = parse_voice_pointer(parsed_toks)

              // 3b. Update Master Volume (V) and Tempo BPM (M)
              let next_engine =
                parse_engine_settings(parsed_toks, model.engine_settings)

              // 3c. Parse Variable assignments (=var,val or = var val)
              let next_vars =
                parse_variable_command(parsed_toks, model.variables)

              // 3d. Parse Stream definitions (( ... ) /SS slot, /SM, /SP)
              let next_stream_slots =
                scan_stream_definitions(
                  string.to_graphemes(cmd),
                  model.stream_slots,
                )

              // 4. Voice parameter updates
              let target_vid = case maybe_new_vid {
                Some(v) -> v
                None -> model.voice.id
              }
              let #(new_all_raw, new_envs_raw, final_vid_raw, touched_pills) =
                apply_skode_string_to_state(
                  model.all_voices,
                  model.all_envelopes,
                  target_vid,
                  cmd,
                )

              // 4b. Check for Voice Reset (S or S<vid>)
              let #(new_all, new_envs, final_vid, next_pinned) = case
                parse_voice_reset(parsed_toks, target_vid)
              {
                Some(r_vid) -> {
                  let #(_v, all_v) = get_or_create_voice(new_all_raw, r_vid)
                  let cleared_v = voice_gen.default(r_vid)
                  let updated_v_list = update_voice_in_list(all_v, cleared_v)
                  let updated_envs =
                    list.key_set(new_envs_raw, r_vid, default_voice_envelopes())
                  let filtered_pinned =
                    list.filter(model.pinned_pills, fn(p) { p.0 != r_vid })
                  #(updated_v_list, updated_envs, r_vid, filtered_pinned)
                }
                None -> {
                  let p_list =
                    list.unique(list.append(touched_pills, model.pinned_pills))
                  #(new_all_raw, new_envs_raw, final_vid_raw, p_list)
                }
              }
              let #(cur_voice, _) = get_or_create_voice(new_all, final_vid)

              // Determine next editor mode and active target
              let has_pattern_edits =
                !list.is_empty(pattern_changes) || !list.is_empty(parsed_steps)
              let #(
                next_mode,
                next_pat_id,
                next_pat_ptr,
                next_delay_id,
                target_summary,
              ) = case
                maybe_new_pid,
                !has_pattern_edits,
                maybe_new_did,
                maybe_new_vid
              {
                Some(pid), _, _, _ -> #(
                  ModePatterns,
                  pid,
                  pid,
                  model.active_delay_id,
                  "Pattern y"
                    <> int.to_string(pid)
                    <> " selected (Pattern Sequencer)"
                    <> case list.is_empty(pattern_changes) {
                    True -> ""
                    False -> " [" <> string.join(pattern_changes, ", ") <> "]"
                  },
                )
                None, False, _, _ -> #(
                  ModePatterns,
                  model.active_pattern_id,
                  model.pattern_pointer,
                  model.active_delay_id,
                  "Pattern y"
                    <> int.to_string(model.active_pattern_id)
                    <> " ["
                    <> string.join(pattern_changes, ", ")
                    <> "]",
                )
                None, True, Some(did), _ -> #(
                  ModeDelays,
                  model.active_pattern_id,
                  model.pattern_pointer,
                  did,
                  "Delay Bus d" <> int.to_string(did) <> " selected",
                )
                None, True, None, Some(vid) -> #(
                  ModeVoices,
                  model.active_pattern_id,
                  model.pattern_pointer,
                  model.active_delay_id,
                  case list.is_empty(touched_pills) {
                    True -> "Voice v" <> int.to_string(vid) <> " selected"
                    False ->
                      "Target v"
                      <> int.to_string(vid)
                      <> " updated ("
                      <> int.to_string(list.length(touched_pills))
                      <> " params: "
                      <> string.join(
                        list.map(touched_pills, fn(tp) {
                          let #(_, pid) = tp
                          get_pill_inspector_title(pid)
                        }),
                        ", ",
                      )
                      <> ")"
                  },
                )
                None, True, None, None -> #(
                  model.editor_mode,
                  model.active_pattern_id,
                  model.pattern_pointer,
                  model.active_delay_id,
                  "Target v"
                    <> int.to_string(final_vid)
                    <> " updated ("
                    <> int.to_string(list.length(touched_pills))
                    <> " params: "
                    <> string.join(
                    list.map(touched_pills, fn(tp) {
                      let #(_, pid) = tp
                      get_pill_inspector_title(pid)
                    }),
                    ", ",
                  )
                    <> ")",
                )
              }

              let new_log =
                CommandLog(
                  id: list.length(model.command_logs) + 1,
                  raw_cmd: cmd,
                  tokens: parsed_toks,
                  summary: target_summary,
                  output: output,
                )
              let next_history = [
                cmd,
                ..list.filter(model.history, fn(h) { h != cmd })
              ]

              // Trigger wave render if wave index was modified or touched
              let wave_effect = case
                cur_voice.wave_table_index != model.voice.wave_table_index
                || list.any(touched_pills, fn(tp) { tp.1 == PillWave })
              {
                True ->
                  effect.from(fn(_) {
                    render_waveform_buffer(
                      "voice-wave-" <> int.to_string(final_vid),
                      cur_voice.wave_table_index,
                    )
                    Nil
                  })
                False -> effect.none()
              }

              let next_model =
                Model(
                  ..model,
                  editor_mode: next_mode,
                  voice: cur_voice,
                  last_dispatched: cur_voice,
                  all_voices: new_all,
                  all_envelopes: new_envs,
                  pinned_pills: next_pinned,
                  active_pattern_id: next_pat_id,
                  pattern_pointer: next_pat_ptr,
                  all_patterns: updated_patterns,
                  active_delay_id: next_delay_id,
                  engine_settings: next_engine,
                  variables: next_vars,
                  stream_slots: next_stream_slots,
                  input_command: "",
                  history_cursor: None,
                  notification: Some("Executed: " <> cmd),
                  history: list.take(next_history, 30),
                  show_console: case output != "" {
                    True -> True
                    False -> model.show_console
                  },
                  command_logs: [new_log, ..list.take(model.command_logs, 49)],
                )
              #(next_model, wave_effect)
            }
          }
        }
      }
    }

    ToggleConsole -> {
      #(Model(..model, show_console: !model.show_console), effect.none())
    }

    ClearConsoleLogs -> {
      #(Model(..model, command_logs: []), effect.none())
    }

    RecallHistoryItem(cmd) -> {
      #(Model(..model, input_command: cmd, history_cursor: None), effect.none())
    }

    CommandKeyDown(key) -> {
      case key {
        "ArrowUp" -> {
          let max_idx = list.length(model.history) - 1
          case max_idx >= 0 {
            True -> {
              let next_idx = case model.history_cursor {
                None -> 0
                Some(i) -> int.min(i + 1, max_idx)
              }
              let item = case list.drop(model.history, next_idx) {
                [h, ..] -> h
                [] -> model.input_command
              }
              #(
                Model(
                  ..model,
                  input_command: item,
                  history_cursor: Some(next_idx),
                ),
                effect.none(),
              )
            }
            False -> #(model, effect.none())
          }
        }
        "ArrowDown" -> {
          case model.history_cursor {
            Some(i) if i > 0 -> {
              let next_idx = i - 1
              let item = case list.drop(model.history, next_idx) {
                [h, ..] -> h
                [] -> ""
              }
              #(
                Model(
                  ..model,
                  input_command: item,
                  history_cursor: Some(next_idx),
                ),
                effect.none(),
              )
            }
            Some(0) -> {
              #(
                Model(..model, input_command: "", history_cursor: None),
                effect.none(),
              )
            }
            _ -> #(model, effect.none())
          }
        }
        _ -> #(model, effect.none())
      }
    }

    SetNotification(str) -> {
      #(Model(..model, notification: Some(str)), effect.none())
    }

    DismissNotification -> {
      #(Model(..model, notification: None), effect.none())
    }

    SetEditorMode(mode) -> {
      #(Model(..model, editor_mode: mode), effect.none())
    }

    // Pattern Sequencer
    SetPatternId(pid) -> {
      let clamped = param.clamp_pattern_id(pid)
      let #(_, all_p) = get_or_create_pattern(model.all_patterns, clamped)
      let next_model =
        Model(
          ..model,
          active_pattern_id: clamped,
          pattern_pointer: clamped,
          all_patterns: all_p,
          step_edit_index: None,
        )
      #(next_model, dispatch_skode_effect("y" <> int.to_string(clamped)))
    }

    StepPattern(delta) -> {
      let next_id = param.clamp_pattern_id(model.active_pattern_id + delta)
      let #(_, all_p) = get_or_create_pattern(model.all_patterns, next_id)
      let next_model =
        Model(
          ..model,
          active_pattern_id: next_id,
          pattern_pointer: next_id,
          all_patterns: all_p,
          step_edit_index: None,
        )
      #(next_model, dispatch_skode_effect("y" <> int.to_string(next_id)))
    }

    SetPatternSpeed(pid, spd) -> {
      let clamped = int.clamp(spd, 1, 64)
      let #(p, all_p) = get_or_create_pattern(model.all_patterns, pid)
      let updated_p = Pattern(..p, speed: clamped)
      let next_all = update_pattern_in_list(all_p, updated_p)
      let cmd = "y" <> int.to_string(pid) <> " %" <> int.to_string(clamped)
      #(Model(..model, all_patterns: next_all), dispatch_skode_effect(cmd))
    }

    SetPatternLength(pid, len) -> {
      let clamped = int.clamp(len, 1, 64)
      let #(p, all_p) = get_or_create_pattern(model.all_patterns, pid)
      let updated_p = Pattern(..p, length: clamped)
      let next_all = update_pattern_in_list(all_p, updated_p)
      #(Model(..model, all_patterns: next_all), effect.none())
    }

    TogglePatternMute(pid) -> {
      let #(p, all_p) = get_or_create_pattern(model.all_patterns, pid)
      let next_mute = !p.mute
      let updated_p = Pattern(..p, mute: next_mute)
      let next_all = update_pattern_in_list(all_p, updated_p)
      let cmd =
        "y"
        <> int.to_string(pid)
        <> " zmu"
        <> case next_mute {
          True -> "1"
          False -> "0"
        }
      #(Model(..model, all_patterns: next_all), dispatch_skode_effect(cmd))
    }

    SetPatternState(pid, state) -> {
      let #(p, all_p) = get_or_create_pattern(model.all_patterns, pid)
      let updated_p = Pattern(..p, state: state)
      let next_all = update_pattern_in_list(all_p, updated_p)
      let cmd =
        "y"
        <> int.to_string(pid)
        <> " "
        <> case state {
          PatternRunning -> "z1"
          PatternPaused -> "z2"
          PatternStopped -> "z0"
        }
      #(Model(..model, all_patterns: next_all), dispatch_skode_effect(cmd))
    }

    SetPatternStepCode(pid, step_idx, code) -> {
      let #(p, all_p) = get_or_create_pattern(model.all_patterns, pid)
      let updated_p = pattern.set_step(p, step_idx, code)
      let next_all = update_pattern_in_list(all_p, updated_p)
      let cmd =
        "y"
        <> int.to_string(pid)
        <> " ["
        <> code
        <> "] x"
        <> int.to_string(step_idx)
      #(Model(..model, all_patterns: next_all), dispatch_skode_effect(cmd))
    }

    ClearPatternStep(pid, step_idx) -> {
      let #(p, all_p) = get_or_create_pattern(model.all_patterns, pid)
      let updated_p = pattern.clear_step(p, step_idx)
      let next_all = update_pattern_in_list(all_p, updated_p)
      let cmd = "y" <> int.to_string(pid) <> " [] x" <> int.to_string(step_idx)
      #(Model(..model, all_patterns: next_all), dispatch_skode_effect(cmd))
    }

    ToggleStepEdit(step_idx) -> {
      let #(p, _) =
        get_or_create_pattern(model.all_patterns, model.active_pattern_id)
      let current_code = case dict.get(p.steps, step_idx) {
        Ok(c) -> c
        Error(_) -> "v0 n60 T"
      }
      case model.step_edit_index == Some(step_idx) {
        True -> #(Model(..model, step_edit_index: None), effect.none())
        False -> #(
          Model(
            ..model,
            step_edit_index: Some(step_idx),
            step_edit_code: current_code,
          ),
          effect.none(),
        )
      }
    }

    SetStepEditCode(code) -> {
      #(Model(..model, step_edit_code: code), effect.none())
    }

    SubmitStepEdit(pid) -> {
      case model.step_edit_index {
        Some(idx) -> {
          let #(p, all_p) = get_or_create_pattern(model.all_patterns, pid)
          let updated_p = pattern.set_step(p, idx, model.step_edit_code)
          let next_all = update_pattern_in_list(all_p, updated_p)
          let cmd =
            "y"
            <> int.to_string(pid)
            <> " ["
            <> model.step_edit_code
            <> "] x"
            <> int.to_string(idx)
          #(
            Model(..model, all_patterns: next_all, step_edit_index: None),
            dispatch_skode_effect(cmd),
          )
        }
        None -> #(model, effect.none())
      }
    }

    ApplyPatternPreset(pid, name) -> {
      let preset_p = case name {
        "4-on-the-Floor" ->
          pattern.default(pid)
          |> pattern.set_step(0, "v0 n36 T")
          |> pattern.set_step(4, "v0 n36 T")
          |> pattern.set_step(8, "v0 n36 T")
          |> pattern.set_step(12, "v0 n36 T")
          |> pattern.set_step(2, "v1 n42 T")
          |> pattern.set_step(6, "v1 n42 T")
          |> pattern.set_step(10, "v1 n42 T")
          |> pattern.set_step(14, "v1 n42 T")
        "Acid Bassline" ->
          pattern.default(pid)
          |> pattern.set_step(0, "v0 n36 k600 q12 T")
          |> pattern.set_step(3, "v0 n39 k1200 q14 T")
          |> pattern.set_step(6, "v0 n41 k2400 q16 T")
          |> pattern.set_step(8, "v0 n36 k800 q10 T")
          |> pattern.set_step(11, "v0 n48 k3200 q18 T")
          |> pattern.set_step(14, "v0 n46 k1500 q12 T")
        "Polyrhythm" ->
          pattern.default(pid)
          |> pattern.set_step(0, "v0 n60 T")
          |> pattern.set_step(3, "v1 n67 T")
          |> pattern.set_step(6, "v0 n63 T")
          |> pattern.set_step(9, "v1 n70 T")
          |> pattern.set_step(12, "v0 n65 T")
        _ -> pattern.default(pid)
      }
      let next_all = update_pattern_in_list(model.all_patterns, preset_p)
      let skode_text = pattern.to_skode(preset_p)
      #(
        Model(
          ..model,
          all_patterns: next_all,
          notification: Some("Applied pattern preset: " <> name),
        ),
        dispatch_skode_effect(skode_text),
      )
    }

    // Delay Bus Updates
    SetDelayBusId(bid) -> {
      #(
        Model(..model, active_delay_id: param.clamp_delay_bus_id(bid)),
        effect.none(),
      )
    }

    UpdateDelayCoarse(bid, val) -> {
      let bus = get_delay_bus(model.engine_settings, bid)
      let updated_bus = DelayBus(..bus, coarse: int.clamp(val, 0, 7))
      let next_engine =
        global.update_delay_bus(model.engine_settings, bid, fn(_) {
          updated_bus
        })
      #(
        Model(..model, engine_settings: next_engine),
        dispatch_skode_effect(delay.to_skode(updated_bus)),
      )
    }

    UpdateDelayFine(bid, val) -> {
      let bus = get_delay_bus(model.engine_settings, bid)
      let updated_bus = DelayBus(..bus, fine: int.clamp(val, 0, 15))
      let next_engine =
        global.update_delay_bus(model.engine_settings, bid, fn(_) {
          updated_bus
        })
      #(
        Model(..model, engine_settings: next_engine),
        dispatch_skode_effect(delay.to_skode(updated_bus)),
      )
    }

    UpdateDelayFeedback(bid, val) -> {
      let bus = get_delay_bus(model.engine_settings, bid)
      let updated_bus = DelayBus(..bus, feedback: int.clamp(val, 0, 15))
      let next_engine =
        global.update_delay_bus(model.engine_settings, bid, fn(_) {
          updated_bus
        })
      #(
        Model(..model, engine_settings: next_engine),
        dispatch_skode_effect(delay.to_skode(updated_bus)),
      )
    }

    UpdateDelayDamping(bid, val) -> {
      let bus = get_delay_bus(model.engine_settings, bid)
      let updated_bus = DelayBus(..bus, damping: int.clamp(val, 0, 15))
      let next_engine =
        global.update_delay_bus(model.engine_settings, bid, fn(_) {
          updated_bus
        })
      #(
        Model(..model, engine_settings: next_engine),
        dispatch_skode_effect(delay.to_skode(updated_bus)),
      )
    }

    UpdateDelayHighpass(bid, val) -> {
      let bus = get_delay_bus(model.engine_settings, bid)
      let updated_bus = DelayBus(..bus, highpass: int.clamp(val, 0, 15))
      let next_engine =
        global.update_delay_bus(model.engine_settings, bid, fn(_) {
          updated_bus
        })
      #(
        Model(..model, engine_settings: next_engine),
        dispatch_skode_effect(delay.to_skode(updated_bus)),
      )
    }

    UpdateDelayModFreq(bid, val) -> {
      let bus = get_delay_bus(model.engine_settings, bid)
      let updated_bus = DelayBus(..bus, mod_freq: int.clamp(val, 0, 31))
      let next_engine =
        global.update_delay_bus(model.engine_settings, bid, fn(_) {
          updated_bus
        })
      #(
        Model(..model, engine_settings: next_engine),
        dispatch_skode_effect(delay.to_skode(updated_bus)),
      )
    }

    UpdateDelayModDepth(bid, val) -> {
      let bus = get_delay_bus(model.engine_settings, bid)
      let updated_bus = DelayBus(..bus, mod_depth: int.clamp(val, 0, 31))
      let next_engine =
        global.update_delay_bus(model.engine_settings, bid, fn(_) {
          updated_bus
        })
      #(
        Model(..model, engine_settings: next_engine),
        dispatch_skode_effect(delay.to_skode(updated_bus)),
      )
    }

    UpdateDelayLevel(bid, val) -> {
      let bus = get_delay_bus(model.engine_settings, bid)
      let updated_bus = DelayBus(..bus, level: int.clamp(val, 0, 15))
      let next_engine =
        global.update_delay_bus(model.engine_settings, bid, fn(_) {
          updated_bus
        })
      #(
        Model(..model, engine_settings: next_engine),
        dispatch_skode_effect(delay.to_skode(updated_bus)),
      )
    }

    UpdateDelayPingPong(bid, val) -> {
      let bus = get_delay_bus(model.engine_settings, bid)
      let updated_bus = DelayBus(..bus, pingpong: val)
      let next_engine =
        global.update_delay_bus(model.engine_settings, bid, fn(_) {
          updated_bus
        })
      #(
        Model(..model, engine_settings: next_engine),
        dispatch_skode_effect(delay.to_skode(updated_bus)),
      )
    }

    UpdateDelayFreeze(bid, val) -> {
      let bus = get_delay_bus(model.engine_settings, bid)
      let updated_bus = DelayBus(..bus, freeze: val)
      let next_engine =
        global.update_delay_bus(model.engine_settings, bid, fn(_) {
          updated_bus
        })
      #(
        Model(..model, engine_settings: next_engine),
        dispatch_skode_effect(delay.to_skode(updated_bus)),
      )
    }

    UpdateDelayGrit(bid, grit) -> {
      let bus = get_delay_bus(model.engine_settings, bid)
      let updated_bus = DelayBus(..bus, grit: grit)
      let next_engine =
        global.update_delay_bus(model.engine_settings, bid, fn(_) {
          updated_bus
        })
      #(
        Model(..model, engine_settings: next_engine),
        dispatch_skode_effect(delay.to_skode(updated_bus)),
      )
    }

    ApplyDelayPreset(bid, name) -> {
      let preset_bus = case name {
        "Dub Space Echo" | "Dub Echo" ->
          DelayBus(
            id: bid,
            coarse: 5,
            fine: 12,
            feedback: 12,
            mod_freq: 2,
            mod_depth: 4,
            level: 11,
            damping: 6,
            highpass: 2,
            pingpong: True,
            freeze: False,
            grit: Quantized(12),
            sync: None,
          )
        "Slapback" | "Stereo Slapback" ->
          DelayBus(
            id: bid,
            coarse: 2,
            fine: 8,
            feedback: 3,
            mod_freq: 0,
            mod_depth: 0,
            level: 12,
            damping: 1,
            highpass: 0,
            pingpong: True,
            freeze: False,
            grit: NativeFloat,
            sync: None,
          )
        "12-Bit Lo-Fi Repeat" | "12-Bit Lo-Fi" | "Lo-Fi" ->
          DelayBus(
            id: bid,
            coarse: 4,
            fine: 15,
            feedback: 10,
            mod_freq: 0,
            mod_depth: 0,
            level: 10,
            damping: 4,
            highpass: 3,
            pingpong: False,
            freeze: False,
            grit: Quantized(8),
            sync: None,
          )
        "Infinite Freeze" | "Infinite Ambient Freeze" | "Freeze" ->
          DelayBus(
            id: bid,
            coarse: 6,
            fine: 15,
            feedback: 15,
            mod_freq: 4,
            mod_depth: 8,
            level: 14,
            damping: 8,
            highpass: 2,
            pingpong: True,
            freeze: True,
            grit: NativeFloat,
            sync: None,
          )
        "Tape Chorus" | "Chorus / Flange" | "Chorus" ->
          DelayBus(
            id: bid,
            coarse: 0,
            fine: 4,
            feedback: 8,
            mod_freq: 8,
            mod_depth: 16,
            level: 12,
            damping: 0,
            highpass: 0,
            pingpong: False,
            freeze: False,
            grit: NativeFloat,
            sync: None,
          )
        _ -> delay.default(bid)
      }
      let next_engine =
        global.update_delay_bus(model.engine_settings, bid, fn(_) { preset_bus })
      #(
        Model(
          ..model,
          engine_settings: next_engine,
          notification: Some("Applied delay preset: " <> name),
        ),
        dispatch_skode_effect(delay.to_skode(preset_bus)),
      )
    }

    // Global Master Volume & Tempo
    UpdateMasterVolume(db) -> {
      let clamped = param.clamp_db(db)
      let next_engine =
        global.set_master_volume_db(model.engine_settings, clamped)
      let cmd = "V " <> param.format_float(clamped)
      #(
        Model(..model, engine_settings: next_engine),
        dispatch_skode_effect(cmd),
      )
    }

    UpdateMasterTempo(bpm) -> {
      let clamped = param.clamp_bpm(bpm)
      let next_engine =
        global.set_tempo(
          model.engine_settings,
          clamped,
          model.engine_settings.subdivision,
        )
      let cmd =
        "M "
        <> param.format_float(clamped)
        <> " "
        <> param.format_float(model.engine_settings.subdivision)
      #(
        Model(..model, engine_settings: next_engine),
        dispatch_skode_effect(cmd),
      )
    }

    // KSynth & Streams
    SetKSynthInput(str) -> {
      #(Model(..model, ksynth_input: str), effect.none())
    }

    SetKSynthSlot(slot) -> {
      #(Model(..model, ksynth_slot: int.clamp(slot, 0, 15)), effect.none())
    }

    SubmitKSynthEval -> {
      let trimmed = string.trim(model.ksynth_input)
      let cmd = case
        string.starts_with(trimmed, "[") && string.ends_with(trimmed, "]")
      {
        True -> trimmed <> " ks"
        False ->
          case string.length(trimmed) > 0 {
            True -> "[" <> trimmed <> "] ks"
            False -> "[] ks"
          }
      }
      let output = send_skode_command(cmd)
      let new_log =
        CommandLog(
          id: list.length(model.command_logs) + 1,
          raw_cmd: cmd,
          tokens: [cmd],
          summary: "Evaluate K-Synth expression ([expr] ks)",
          output: output,
        )
      #(
        Model(..model, show_console: True, command_logs: [
          new_log,
          ..list.take(model.command_logs, 49)
        ]),
        effect.none(),
      )
    }

    SubmitKSynthQuery -> {
      let cmd = "k?"
      let output = send_skode_command(cmd)
      let new_log =
        CommandLog(
          id: list.length(model.command_logs) + 1,
          raw_cmd: cmd,
          tokens: ["k?"],
          summary: "Dump last K-Synth result vector (k?)",
          output: output,
        )
      #(
        Model(..model, show_console: True, command_logs: [
          new_log,
          ..list.take(model.command_logs, 49)
        ]),
        effect.none(),
      )
    }

    SubmitKSynthToData -> {
      let cmd = "k>d"
      let output = send_skode_command(cmd)
      let new_log =
        CommandLog(
          id: list.length(model.command_logs) + 1,
          raw_cmd: cmd,
          tokens: ["k>d"],
          summary: "Copy last K-Synth result vector to data array (k>d)",
          output: output,
        )
      #(
        Model(..model, show_console: True, command_logs: [
          new_log,
          ..list.take(model.command_logs, 49)
        ]),
        effect.none(),
      )
    }

    SubmitQueryDataArray -> {
      let cmd = "?d"
      let output = send_skode_command(cmd)
      let new_log =
        CommandLog(
          id: list.length(model.command_logs) + 1,
          raw_cmd: cmd,
          tokens: ["?d"],
          summary: "Dump data array contents (?d)",
          output: output,
        )
      #(
        Model(..model, show_console: True, command_logs: [
          new_log,
          ..list.take(model.command_logs, 49)
        ]),
        effect.none(),
      )
    }

    SubmitKSynthToWave(w_slot) -> {
      let cmd = "k>w " <> int.to_string(w_slot)
      let output = send_skode_command(cmd)
      let new_log =
        CommandLog(
          id: list.length(model.command_logs) + 1,
          raw_cmd: cmd,
          tokens: ["k>w", int.to_string(w_slot)],
          summary: "Install K-Synth result into wavetable slot w"
            <> int.to_string(w_slot),
          output: output,
        )
      #(
        Model(..model, show_console: True, command_logs: [
          new_log,
          ..list.take(model.command_logs, 49)
        ]),
        effect.none(),
      )
    }

    LoadKSynthFile(slot) -> {
      let cmd = "/k " <> int.to_string(slot)
      let output = send_skode_command(cmd)
      let new_log =
        CommandLog(
          id: list.length(model.command_logs) + 1,
          raw_cmd: cmd,
          tokens: ["/k", int.to_string(slot)],
          summary: "Load script "
            <> int.to_string(slot)
            <> ".ks from disk/VFS (/k)",
          output: output,
        )
      #(
        Model(..model, show_console: True, command_logs: [
          new_log,
          ..list.take(model.command_logs, 49)
        ]),
        effect.none(),
      )
    }

    SetStreamMode(mode) -> {
      let cmd = "/SM " <> int.to_string(mode)
      #(model, dispatch_skode_effect(cmd))
    }

    // Macro Trigger Pad (e!0..e!15)
    SetMacroSlot(slot) -> {
      let clamped = int.clamp(slot, 0, 15)
      let existing_code = case
        list.find(model.macros, fn(m) { m.0 == clamped })
      {
        Ok(#(_, c)) -> c
        Error(_) -> ""
      }
      #(
        Model(..model, macro_slot: clamped, macro_input: existing_code),
        effect.none(),
      )
    }

    SetMacroInput(str) -> {
      #(Model(..model, macro_input: str), effect.none())
    }

    StoreMacro(slot, code) -> {
      let clamped = int.clamp(slot, 0, 15)
      let trimmed = string.trim(code)
      let cmd = "[" <> trimmed <> "] e>" <> int.to_string(clamped)
      let output = send_skode_command(cmd)
      let updated_macros =
        list.map(model.macros, fn(entry) {
          case entry.0 == clamped {
            True -> #(clamped, trimmed)
            False -> entry
          }
        })
      let new_log =
        CommandLog(
          id: list.length(model.command_logs) + 1,
          raw_cmd: cmd,
          tokens: [cmd],
          summary: "Store macro into slot e>" <> int.to_string(clamped),
          output: output,
        )
      #(
        Model(
          ..model,
          macros: updated_macros,
          notification: Some("Stored macro into e>" <> int.to_string(clamped)),
          command_logs: [new_log, ..list.take(model.command_logs, 49)],
        ),
        effect.none(),
      )
    }

    ExecMacro(slot) -> {
      let clamped = int.clamp(slot, 0, 15)
      let cmd = "e!" <> int.to_string(clamped)
      let output = send_skode_command(cmd)
      let new_log =
        CommandLog(
          id: list.length(model.command_logs) + 1,
          raw_cmd: cmd,
          tokens: ["e!", int.to_string(clamped)],
          summary: "Execute macro slot e!" <> int.to_string(clamped),
          output: output,
        )
      #(
        Model(
          ..model,
          notification: Some("Fired macro e!" <> int.to_string(clamped)),
          command_logs: [new_log, ..list.take(model.command_logs, 49)],
        ),
        effect.none(),
      )
    }

    QueryMacro(slot) -> {
      let clamped = int.clamp(slot, 0, 15)
      let cmd = "e? " <> int.to_string(clamped)
      let output = send_skode_command(cmd)
      let new_log =
        CommandLog(
          id: list.length(model.command_logs) + 1,
          raw_cmd: cmd,
          tokens: ["e?", int.to_string(clamped)],
          summary: "Query macro slot e?" <> int.to_string(clamped),
          output: output,
        )
      #(
        Model(..model, show_console: True, command_logs: [
          new_log,
          ..list.take(model.command_logs, 49)
        ]),
        effect.none(),
      )
    }

    QueryAllMacros -> {
      let cmd = "?m"
      let output = send_skode_command(cmd)
      let new_log =
        CommandLog(
          id: list.length(model.command_logs) + 1,
          raw_cmd: cmd,
          tokens: ["?m"],
          summary: "List all defined macros (?m)",
          output: output,
        )
      #(
        Model(..model, show_console: True, command_logs: [
          new_log,
          ..list.take(model.command_logs, 49)
        ]),
        effect.none(),
      )
    }

    ClearAllMacros -> {
      let cmd = "/m!"
      let output = send_skode_command(cmd)
      let cleared = list.map(model.macros, fn(entry) { #(entry.0, "") })
      let new_log =
        CommandLog(
          id: list.length(model.command_logs) + 1,
          raw_cmd: cmd,
          tokens: ["/m!"],
          summary: "Clear all user macros (/m!)",
          output: output,
        )
      #(
        Model(
          ..model,
          macros: cleared,
          notification: Some("Cleared all macros (/m!)"),
          command_logs: [new_log, ..list.take(model.command_logs, 49)],
        ),
        effect.none(),
      )
    }

    ToggleTheme -> {
      let next_theme = case model.theme {
        ThemeDark -> ThemeLight
        ThemeLight -> ThemeDark
      }
      let effect =
        dispatch_skode_effect(case next_theme {
          ThemeDark -> "-dark"
          ThemeLight -> "-light"
        })
      #(Model(..model, theme: next_theme), effect)
    }

    SubmitAudioList -> {
      let cmd = "/als"
      let output = send_skode_command(cmd)
      let new_log =
        CommandLog(
          id: list.length(model.command_logs) + 1,
          raw_cmd: cmd,
          tokens: ["/als"],
          summary: "List audio host devices (/als)",
          output: output,
        )
      #(
        Model(..model, show_console: True, command_logs: [
          new_log,
          ..list.take(model.command_logs, 49)
        ]),
        effect.none(),
      )
    }

    SubmitAudioQuery -> {
      let cmd = "?a"
      let output = send_skode_command(cmd)
      let new_log =
        CommandLog(
          id: list.length(model.command_logs) + 1,
          raw_cmd: cmd,
          tokens: ["?a"],
          summary: "Query audio engine status (?a)",
          output: output,
        )
      #(
        Model(..model, show_console: True, command_logs: [
          new_log,
          ..list.take(model.command_logs, 49)
        ]),
        effect.none(),
      )
    }

    SubmitAudioOut(dev) -> {
      let cmd = "/ao " <> int.to_string(dev)
      let output = send_skode_command(cmd)
      let new_log =
        CommandLog(
          id: list.length(model.command_logs) + 1,
          raw_cmd: cmd,
          tokens: ["/ao", int.to_string(dev)],
          summary: "Set audio output device (" <> cmd <> ")",
          output: output,
        )
      #(
        Model(
          ..model,
          notification: Some(
            "Set audio output to device " <> int.to_string(dev),
          ),
          command_logs: [new_log, ..list.take(model.command_logs, 49)],
        ),
        effect.none(),
      )
    }

    SubmitAudioIn(dev) -> {
      let cmd = "/ai " <> int.to_string(dev)
      let output = send_skode_command(cmd)
      let new_log =
        CommandLog(
          id: list.length(model.command_logs) + 1,
          raw_cmd: cmd,
          tokens: ["/ai", int.to_string(dev)],
          summary: "Set audio input device (" <> cmd <> ")",
          output: output,
        )
      #(
        Model(
          ..model,
          notification: Some("Set audio input to device " <> int.to_string(dev)),
          command_logs: [new_log, ..list.take(model.command_logs, 49)],
        ),
        effect.none(),
      )
    }

    SubmitMidiList -> {
      let cmd = "/mls"
      let output = send_skode_command(cmd)
      let new_log =
        CommandLog(
          id: list.length(model.command_logs) + 1,
          raw_cmd: cmd,
          tokens: ["/mls"],
          summary: "List MIDI interfaces (/mls)",
          output: output,
        )
      #(
        Model(..model, show_console: True, command_logs: [
          new_log,
          ..list.take(model.command_logs, 49)
        ]),
        effect.none(),
      )
    }

    SubmitMidiQuery -> {
      let cmd = "?m"
      let output = send_skode_command(cmd)
      let new_log =
        CommandLog(
          id: list.length(model.command_logs) + 1,
          raw_cmd: cmd,
          tokens: ["?m"],
          summary: "Query MIDI configuration (?m)",
          output: output,
        )
      #(
        Model(..model, show_console: True, command_logs: [
          new_log,
          ..list.take(model.command_logs, 49)
        ]),
        effect.none(),
      )
    }

    SubmitMidiIn(dev) -> {
      let cmd = "/mi " <> int.to_string(dev)
      let output = send_skode_command(cmd)
      let new_log =
        CommandLog(
          id: list.length(model.command_logs) + 1,
          raw_cmd: cmd,
          tokens: ["/mi", int.to_string(dev)],
          summary: "Open MIDI input device (" <> cmd <> ")",
          output: output,
        )
      #(
        Model(
          ..model,
          notification: Some("Opened MIDI input " <> int.to_string(dev)),
          command_logs: [new_log, ..list.take(model.command_logs, 49)],
        ),
        effect.none(),
      )
    }

    SubmitMidiOut(dev) -> {
      let cmd = "/mo " <> int.to_string(dev)
      let output = send_skode_command(cmd)
      let new_log =
        CommandLog(
          id: list.length(model.command_logs) + 1,
          raw_cmd: cmd,
          tokens: ["/mo", int.to_string(dev)],
          summary: "Open MIDI output device (" <> cmd <> ")",
          output: output,
        )
      #(
        Model(
          ..model,
          notification: Some("Opened MIDI output " <> int.to_string(dev)),
          command_logs: [new_log, ..list.take(model.command_logs, 49)],
        ),
        effect.none(),
      )
    }

    SubmitMidiVoiceRoute(ch, voice_id) -> {
      let cmd = "/mv " <> int.to_string(ch) <> "," <> int.to_string(voice_id)
      let output = send_skode_command(cmd)
      let new_log =
        CommandLog(
          id: list.length(model.command_logs) + 1,
          raw_cmd: cmd,
          tokens: ["/mv", int.to_string(ch), int.to_string(voice_id)],
          summary: "Route MIDI channel "
            <> int.to_string(ch)
            <> " to voice "
            <> int.to_string(voice_id),
          output: output,
        )
      #(
        Model(
          ..model,
          notification: Some(
            "Routed MIDI Ch "
            <> int.to_string(ch)
            <> " -> Voice "
            <> int.to_string(voice_id),
          ),
          command_logs: [new_log, ..list.take(model.command_logs, 49)],
        ),
        effect.none(),
      )
    }

    SubmitMidiPoolRoute(ch, pool_id) -> {
      let cmd = "/mp " <> int.to_string(ch) <> "," <> int.to_string(pool_id)
      let output = send_skode_command(cmd)
      let new_log =
        CommandLog(
          id: list.length(model.command_logs) + 1,
          raw_cmd: cmd,
          tokens: ["/mp", int.to_string(ch), int.to_string(pool_id)],
          summary: "Route MIDI channel "
            <> int.to_string(ch)
            <> " to poly pool "
            <> int.to_string(pool_id),
          output: output,
        )
      #(
        Model(
          ..model,
          notification: Some(
            "Routed MIDI Ch "
            <> int.to_string(ch)
            <> " -> Pool "
            <> int.to_string(pool_id),
          ),
          command_logs: [new_log, ..list.take(model.command_logs, 49)],
        ),
        effect.none(),
      )
    }

    ToggleControlVoiceEvents -> {
      let next = !model.control_voice_events
      let cmd = case next {
        True -> "vc1"
        False -> "vc0"
      }
      let output = send_skode_command(cmd)
      let new_log =
        CommandLog(
          id: list.length(model.command_logs) + 1,
          raw_cmd: cmd,
          tokens: [cmd],
          summary: "Set voice control event publishing (" <> cmd <> ")",
          output: output,
        )
      #(
        Model(
          ..model,
          control_voice_events: next,
          notification: Some(
            "Voice control events "
            <> case next {
              True -> "enabled (vc1)"
              False -> "disabled (vc0)"
            },
          ),
          command_logs: [new_log, ..list.take(model.command_logs, 49)],
        ),
        effect.none(),
      )
    }

    ToggleControlPatternEvents -> {
      let next = !model.control_pattern_events
      let cmd = case next {
        True -> "yc1"
        False -> "yc0"
      }
      let output = send_skode_command(cmd)
      let new_log =
        CommandLog(
          id: list.length(model.command_logs) + 1,
          raw_cmd: cmd,
          tokens: [cmd],
          summary: "Set pattern boundary event publishing (" <> cmd <> ")",
          output: output,
        )
      #(
        Model(
          ..model,
          control_pattern_events: next,
          notification: Some(
            "Pattern boundary events "
            <> case next {
              True -> "enabled (yc1)"
              False -> "disabled (yc0)"
            },
          ),
          command_logs: [new_log, ..list.take(model.command_logs, 49)],
        ),
        effect.none(),
      )
    }

    SubmitUserControlEvent(id, a, b, c) -> {
      let cmd =
        "ce "
        <> int.to_string(id)
        <> ","
        <> int.to_string(a)
        <> ","
        <> int.to_string(b)
        <> ","
        <> int.to_string(c)
      let output = send_skode_command(cmd)
      let new_log =
        CommandLog(
          id: list.length(model.command_logs) + 1,
          raw_cmd: cmd,
          tokens: ["ce", int.to_string(id)],
          summary: "Emit user control marker (" <> cmd <> ")",
          output: output,
        )
      #(
        Model(
          ..model,
          notification: Some("Emitted control marker ce " <> int.to_string(id)),
          command_logs: [new_log, ..list.take(model.command_logs, 49)],
        ),
        effect.none(),
      )
    }

    SubmitControlEventQuery -> {
      let cmd = "?ce"
      let output = send_skode_command(cmd)
      let new_log =
        CommandLog(
          id: list.length(model.command_logs) + 1,
          raw_cmd: cmd,
          tokens: ["?ce"],
          summary: "Poll control events (?ce)",
          output: output,
        )
      #(
        Model(..model, show_console: True, command_logs: [
          new_log,
          ..list.take(model.command_logs, 49)
        ]),
        effect.none(),
      )
    }

    SubmitControlEventClear -> {
      let cmd = "?ce!"
      let output = send_skode_command(cmd)
      let new_log =
        CommandLog(
          id: list.length(model.command_logs) + 1,
          raw_cmd: cmd,
          tokens: ["?ce!"],
          summary: "Flush control events (?ce!)",
          output: output,
        )
      #(
        Model(
          ..model,
          notification: Some("Flushed control events (?ce!)"),
          command_logs: [new_log, ..list.take(model.command_logs, 49)],
        ),
        effect.none(),
      )
    }

    SubmitScheduledQueueQuery -> {
      let cmd = "?q"
      let output = send_skode_command(cmd)
      let new_log =
        CommandLog(
          id: list.length(model.command_logs) + 1,
          raw_cmd: cmd,
          tokens: ["?q"],
          summary: "Inspect scheduled event queue (?q)",
          output: output,
        )
      #(
        Model(..model, show_console: True, command_logs: [
          new_log,
          ..list.take(model.command_logs, 49)
        ]),
        effect.none(),
      )
    }

    InspectVoiceWaveformBuffer(voice_id, wave_idx) -> {
      let canvas_id = "voice-wave-" <> int.to_string(voice_id)
      let effect =
        effect.from(fn(_) {
          render_waveform_buffer(canvas_id, wave_idx)
          Nil
        })
      #(
        Model(
          ..model,
          notification: Some(
            "Inspected waveform buffer W"
            <> int.to_string(wave_idx)
            <> " (v"
            <> int.to_string(voice_id)
            <> ")",
          ),
        ),
        effect,
      )
    }

    AttachFilesViaDialog -> {
      let effect =
        effect.from(fn(_) {
          attach_vfs_file_dialog()
          Nil
        })
      #(
        Model(..model, notification: Some("Opened file attachment dialog")),
        effect,
      )
    }

    DeleteVfsItem(filename) -> {
      let effect =
        effect.from(fn(_) {
          delete_vfs_file(filename)
          Nil
        })
      let updated_items =
        list.filter(model.vfs_items, fn(item) { item.name != filename })
      #(
        Model(
          ..model,
          vfs_items: updated_items,
          notification: Some("Unlinked [" <> filename <> "] from VFS"),
        ),
        effect,
      )
    }

    LoadFileToWaveSlot(filename, slot) -> {
      let cmd = "[" <> filename <> "] /ws " <> int.to_string(slot)
      let output = send_skode_command(cmd)
      let new_log =
        CommandLog(
          id: list.length(model.command_logs) + 1,
          raw_cmd: cmd,
          tokens: [filename, "/ws", int.to_string(slot)],
          summary: "Load file into wave slot (" <> cmd <> ")",
          output: output,
        )
      #(
        Model(
          ..model,
          notification: Some(
            "Loaded [" <> filename <> "] to wave slot w" <> int.to_string(slot),
          ),
          command_logs: [new_log, ..list.take(model.command_logs, 49)],
        ),
        effect.none(),
      )
    }

    MountZipFile(filename) -> {
      let cmd = "[" <> filename <> "] %z"
      let output = send_skode_command(cmd)
      let new_log =
        CommandLog(
          id: list.length(model.command_logs) + 1,
          raw_cmd: cmd,
          tokens: [filename, "%z"],
          summary: "Mount zip bundle (" <> cmd <> ")",
          output: output,
        )
      #(
        Model(
          ..model,
          notification: Some("Mounted zip asset bundle [" <> filename <> "]"),
          command_logs: [new_log, ..list.take(model.command_logs, 49)],
        ),
        effect.none(),
      )
    }

    UnmountZipFile -> {
      let cmd = "%u"
      let output = send_skode_command(cmd)
      let new_log =
        CommandLog(
          id: list.length(model.command_logs) + 1,
          raw_cmd: cmd,
          tokens: ["%u"],
          summary: "Unmount zip bundle (%u)",
          output: output,
        )
      #(
        Model(
          ..model,
          notification: Some("Unmounted zip asset bundle (%u)"),
          command_logs: [new_log, ..list.take(model.command_logs, 49)],
        ),
        effect.none(),
      )
    }

    RunVfsScript(filename) -> {
      let script_content = read_vfs_text_file(filename)
      let updated_model = case string.trim(script_content) {
        "" -> {
          let cmd = case string.ends_with(filename, ".ks") {
            True -> "[" <> filename <> "] /ks"
            False -> "[" <> filename <> "] /ls"
          }
          let _ = send_skode_command(cmd)
          model
        }
        content -> apply_skode_script_to_model(model, content)
      }
      let cmd_label = "[" <> filename <> "] /ls"
      let new_log =
        CommandLog(
          id: list.length(model.command_logs) + 1,
          raw_cmd: cmd_label,
          tokens: ["[" <> filename <> "]", "/ls"],
          summary: "Loaded script "
            <> filename
            <> " ("
            <> int.to_string(list.length(updated_model.all_voices))
            <> " voices, "
            <> int.to_string(list.length(updated_model.all_patterns))
            <> " patterns)",
          output: "Script executed and synced to studio state",
        )
      #(
        Model(
          ..updated_model,
          notification: Some("Loaded and ran script: " <> filename),
          command_logs: [new_log, ..list.take(model.command_logs, 49)],
        ),
        effect.none(),
      )
    }

    ExportSessionZip -> {
      let session_script = generate_full_session_skode(model)
      let effect =
        effect.from(fn(_) {
          export_project_zip(session_script)
          Nil
        })
      #(
        Model(
          ..model,
          notification: Some(
            "Exported full session (.zip archive with session.sk & VFS)",
          ),
        ),
        effect,
      )
    }

    ImportSessionZip -> {
      let effect =
        effect.from(fn(_) {
          import_project_zip_dialog()
          Nil
        })
      #(
        Model(..model, notification: Some("Opened project .zip import dialog")),
        effect,
      )
    }

    SelectStreamSlot(slot) -> {
      let slot_info = case dict.get(model.stream_slots, slot) {
        Ok(s) -> s
        Error(_) -> StreamSlot(slot, 0, 0, "")
      }
      #(
        Model(
          ..model,
          active_stream_slot: slot,
          active_stream_mode: slot_info.mode,
          active_stream_pos: slot_info.pos,
          stream_data_input: slot_info.data,
        ),
        effect.none(),
      )
    }

    SetStreamSlotMode(slot, mode) -> {
      let cmd = "/SM " <> int.to_string(slot) <> " " <> int.to_string(mode)
      let _ = send_skode_command(cmd)
      let cur_slot = case dict.get(model.stream_slots, slot) {
        Ok(s) -> s
        Error(_) -> StreamSlot(slot, 0, 0, "")
      }
      let next_slots =
        dict.insert(
          model.stream_slots,
          slot,
          StreamSlot(..cur_slot, mode: mode),
        )
      #(
        Model(
          ..model,
          active_stream_mode: mode,
          stream_slots: next_slots,
          notification: Some(
            "Set stream "
            <> int.to_string(slot)
            <> " mode to "
            <> int.to_string(mode),
          ),
        ),
        effect.none(),
      )
    }

    SetStreamSlotPos(slot, pos) -> {
      let cmd = "/SP " <> int.to_string(slot) <> " " <> int.to_string(pos)
      let _ = send_skode_command(cmd)
      let cur_slot = case dict.get(model.stream_slots, slot) {
        Ok(s) -> s
        Error(_) -> StreamSlot(slot, 0, 0, "")
      }
      let next_slots =
        dict.insert(model.stream_slots, slot, StreamSlot(..cur_slot, pos: pos))
      #(
        Model(
          ..model,
          active_stream_pos: pos,
          stream_slots: next_slots,
          notification: Some(
            "Set stream "
            <> int.to_string(slot)
            <> " pos to "
            <> int.to_string(pos),
          ),
        ),
        effect.none(),
      )
    }

    SetStreamDataInput(str) -> {
      #(Model(..model, stream_data_input: str), effect.none())
    }

    SubmitStreamDataSet(slot, data_str) -> {
      let cmd = "( " <> data_str <> " ) /SS " <> int.to_string(slot)
      let output = send_skode_command(cmd)
      let cur_slot = case dict.get(model.stream_slots, slot) {
        Ok(s) -> s
        Error(_) -> StreamSlot(slot, 0, 0, "")
      }
      let next_slots =
        dict.insert(
          model.stream_slots,
          slot,
          StreamSlot(..cur_slot, data: string.trim(data_str)),
        )
      let new_log =
        CommandLog(
          id: list.length(model.command_logs) + 1,
          raw_cmd: cmd,
          tokens: ["/SS", int.to_string(slot)],
          summary: "Set stream data array (" <> cmd <> ")",
          output: output,
        )
      #(
        Model(
          ..model,
          stream_slots: next_slots,
          notification: Some(
            "Populated stream " <> int.to_string(slot) <> " data array",
          ),
          command_logs: [new_log, ..list.take(model.command_logs, 49)],
        ),
        effect.none(),
      )
    }

    SelectVariable(vid) -> {
      let clamped = int.clamp(vid, 0, 127)
      let cur_val = case dict.get(model.variables, clamped) {
        Ok(v) -> v
        Error(_) -> 0.0
      }
      #(
        Model(
          ..model,
          active_var_id: clamped,
          var_input_val: param.format_float(cur_val),
        ),
        effect.none(),
      )
    }

    SetVariableInput(str) -> {
      #(Model(..model, var_input_val: str), effect.none())
    }

    SubmitSetVariable(vid, val) -> {
      let clamped_id = int.clamp(vid, 0, 127)
      let next_vars = dict.insert(model.variables, clamped_id, val)
      let cmd =
        "=" <> int.to_string(clamped_id) <> "," <> param.format_float(val)
      let output = send_skode_command(cmd)
      let new_log =
        CommandLog(
          id: list.length(model.command_logs) + 1,
          raw_cmd: cmd,
          tokens: ["=", int.to_string(clamped_id)],
          summary: "Set variable $"
            <> int.to_string(clamped_id)
            <> " = "
            <> param.format_float(val),
          output: output,
        )
      #(
        Model(
          ..model,
          variables: next_vars,
          active_var_id: clamped_id,
          command_logs: [new_log, ..list.take(model.command_logs, 49)],
          notification: Some(
            "Set $"
            <> int.to_string(clamped_id)
            <> " = "
            <> param.format_float(val),
          ),
        ),
        effect.none(),
      )
    }

    SubmitOpVariable(op, vid, val) -> {
      let clamped_id = int.clamp(vid, 0, 127)
      let old_val = case dict.get(model.variables, clamped_id) {
        Ok(v) -> v
        Error(_) -> 0.0
      }
      let new_val = case op {
        "a=" -> old_val +. val
        "s=" -> old_val -. val
        "*=" -> old_val *. val
        "/=" ->
          case val != 0.0 {
            True -> old_val /. val
            False -> old_val
          }
        _ -> val
      }
      let next_vars = dict.insert(model.variables, clamped_id, new_val)
      let cmd =
        op <> int.to_string(clamped_id) <> "," <> param.format_float(val)
      let output = send_skode_command(cmd)
      let new_log =
        CommandLog(
          id: list.length(model.command_logs) + 1,
          raw_cmd: cmd,
          tokens: [op, int.to_string(clamped_id)],
          summary: op
            <> "$"
            <> int.to_string(clamped_id)
            <> " -> "
            <> param.format_float(new_val),
          output: output,
        )
      #(
        Model(
          ..model,
          variables: next_vars,
          active_var_id: clamped_id,
          var_input_val: param.format_float(new_val),
          command_logs: [new_log, ..list.take(model.command_logs, 49)],
          notification: Some(
            op
            <> "$"
            <> int.to_string(clamped_id)
            <> " = "
            <> param.format_float(new_val),
          ),
        ),
        effect.none(),
      )
    }

    ClearVariable(vid) -> {
      let clamped_id = int.clamp(vid, 0, 127)
      let next_vars = dict.delete(model.variables, clamped_id)
      let cmd = "=" <> int.to_string(clamped_id) <> ",0"
      let _ = send_skode_command(cmd)
      #(
        Model(
          ..model,
          variables: next_vars,
          var_input_val: "0.0",
          notification: Some("Cleared $" <> int.to_string(clamped_id)),
        ),
        effect.none(),
      )
    }

    CopyStreamSlot(src, dst) -> {
      let cmd = int.to_string(src) <> " " <> int.to_string(dst) <> " /SC"
      let output = send_skode_command(cmd)
      let new_log =
        CommandLog(
          id: list.length(model.command_logs) + 1,
          raw_cmd: cmd,
          tokens: ["/SC"],
          summary: "Copy stream (" <> cmd <> ")",
          output: output,
        )
      #(
        Model(
          ..model,
          notification: Some(
            "Copied stream "
            <> int.to_string(src)
            <> " -> "
            <> int.to_string(dst),
          ),
          command_logs: [new_log, ..list.take(model.command_logs, 49)],
        ),
        effect.none(),
      )
    }

    QueryStreamSlot(slot) -> {
      let cmd = case slot {
        -1 -> "?S"
        s -> int.to_string(s) <> " ?S"
      }
      let output = send_skode_command(cmd)
      let new_log =
        CommandLog(
          id: list.length(model.command_logs) + 1,
          raw_cmd: cmd,
          tokens: ["?S"],
          summary: "Query stream state (" <> cmd <> ")",
          output: output,
        )
      #(
        Model(..model, show_console: True, command_logs: [
          new_log,
          ..list.take(model.command_logs, 49)
        ]),
        effect.none(),
      )
    }
  }
}

// -----------------------------------------------------------------------------
// Pattern & Delay Bus Helpers
// -----------------------------------------------------------------------------

fn get_or_create_pattern(
  patterns: List(Pattern),
  pattern_id: Int,
) -> #(Pattern, List(Pattern)) {
  case list.find(patterns, fn(p) { p.id == pattern_id }) {
    Ok(p) -> #(p, patterns)
    Error(_) -> {
      let new_p = pattern.default(pattern_id)
      #(new_p, [new_p, ..patterns])
    }
  }
}

fn update_pattern_in_list(
  patterns: List(Pattern),
  updated: Pattern,
) -> List(Pattern) {
  case list.any(patterns, fn(p) { p.id == updated.id }) {
    True ->
      list.map(patterns, fn(p) {
        case p.id == updated.id {
          True -> updated
          False -> p
        }
      })
    False -> [updated, ..patterns]
  }
}

fn get_delay_bus(settings: EngineSettings, bus_id: Int) -> DelayBus {
  case list.find(settings.delay_buses, fn(b) { b.id == bus_id }) {
    Ok(b) -> b
    Error(_) -> delay.default(bus_id)
  }
}

// -----------------------------------------------------------------------------
// Live Command Parsing (0..255 Voices & ADSR Envelopes)
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

fn apply_single_token(
  voice: Voice,
  envs: VoiceEnvelopes,
  token: String,
) -> #(Voice, VoiceEnvelopes) {
  let #(op, val_str) = split_op_val(token)
  case op {
    "G" -> {
      let targets =
        string.split(val_str, ",")
        |> list.filter_map(fn(s) {
          case int.parse(string.trim(s)) {
            Ok(tid) if tid >= 0 && tid <= 255 -> Ok(int.to_float(tid))
            _ -> Error(Nil)
          }
        })
      #(Voice(..voice, link_midi: targets), envs)
    }
    "H" -> {
      let targets =
        string.split(val_str, ",")
        |> list.filter_map(fn(s) {
          case int.parse(string.trim(s)) {
            Ok(tid) if tid >= 0 && tid <= 255 -> Ok(int.to_float(tid))
            _ -> Error(Nil)
          }
        })
      #(Voice(..voice, link_velo: targets), envs)
    }
    "C" -> {
      let parts = string.split(val_str, ",")
      case parts {
        [osc_str, depth_str, ..] -> {
          let osc = parse_int(osc_str, voice.cz_mod_osc)
          let depth = parse_float(depth_str, voice.cz_mod_depth)
          #(Voice(..voice, cz_mod_osc: osc, cz_mod_depth: depth), envs)
        }
        _ -> #(voice, envs)
      }
    }
    _ -> {
      case string.lowercase(op) {
        "v" -> #(Voice(..voice, id: parse_int(val_str, voice.id)), envs)
        "w" | "wave" -> #(
          Voice(
            ..voice,
            wave_table_index: param_gen.clamp_wave_table_index(parse_int(
              val_str,
              voice.wave_table_index,
            )),
          ),
          envs,
        )
        "hs" | "linksync" -> {
          let targets =
            string.split(val_str, ",")
            |> list.filter_map(fn(s) {
              case int.parse(string.trim(s)) {
                Ok(tid) if tid >= 0 && tid <= 255 -> Ok(int.to_float(tid))
                _ -> Error(Nil)
              }
            })
          #(Voice(..voice, link_sync: targets), envs)
        }
        "f" | "freq" -> {
          case string.contains(val_str, ",") {
            True -> {
              let parts = string.split(val_str, ",")
              case parts {
                [osc_str, depth_str, ..] -> {
                  let osc = parse_int(osc_str, voice.freq_mod_osc)
                  let depth = parse_float(depth_str, voice.freq_mod_depth)
                  #(
                    Voice(..voice, freq_mod_osc: osc, freq_mod_depth: depth),
                    envs,
                  )
                }
                _ -> #(voice, envs)
              }
            }
            False -> #(
              Voice(
                ..voice,
                freq: param_gen.clamp_freq(parse_float(val_str, voice.freq)),
                pitch_mode: 0,
              ),
              envs,
            )
          }
        }
        "n" | "note" -> {
          let parts = string.split(val_str, ",")
          case parts {
            [note_str, ..] -> #(
              Voice(
                ..voice,
                midi_note: param_gen.clamp_midi_note(parse_float(
                  note_str,
                  voice.midi_note,
                )),
                pitch_mode: 1,
              ),
              envs,
            )
            _ -> #(voice, envs)
          }
        }
        "a" | "amp" | "vol" -> #(
          Voice(
            ..voice,
            user_amp: param_gen.clamp_user_amp(parse_float(
              val_str,
              voice.user_amp,
            )),
          ),
          envs,
        )
        "p" | "pan" -> #(
          Voice(
            ..voice,
            pan: param_gen.clamp_pan(parse_float(val_str, voice.pan)),
          ),
          envs,
        )
        "j" | "filtermode" -> {
          let parts = string.split(val_str, ",")
          case parts {
            [m_str, ..] -> #(
              Voice(
                ..voice,
                filter_mode: param_gen.clamp_filter_mode(parse_int(
                  m_str,
                  voice.filter_mode,
                )),
              ),
              envs,
            )
            _ -> #(voice, envs)
          }
        }
        "k" | "cutoff" -> #(
          Voice(
            ..voice,
            filter_freq: param_gen.clamp_filter_freq(parse_float(
              val_str,
              voice.filter_freq,
            )),
          ),
          envs,
        )
        "q" | "res" -> #(
          Voice(
            ..voice,
            filter_res: param_gen.clamp_filter_res(parse_float(
              val_str,
              voice.filter_res,
            )),
          ),
          envs,
        )
        "kd" | "fed" | "fd" | "fmd" -> #(
          Voice(
            ..voice,
            filter_env_depth: param_gen.clamp_filter_env_depth(parse_float(
              val_str,
              voice.filter_env_depth,
            )),
            use_filter_envelope: 1,
          ),
          envs,
        )
        "t" -> {
          let next_amp = parse_adsr_token(val_str, envs.amp_env)
          #(
            Voice(..voice, use_amp_envelope: 1),
            VoiceEnvelopes(..envs, amp_env: next_amp),
          )
        }
        "kt" | "ft" -> {
          let next_flt = parse_adsr_token(val_str, envs.filter_env)
          #(
            Voice(..voice, use_filter_envelope: 1),
            VoiceEnvelopes(..envs, filter_env: next_flt),
          )
        }
        "fm" | "freqmod" -> {
          case string.contains(val_str, ",") {
            True -> {
              let parts = string.split(val_str, ",")
              case parts {
                [osc_str, depth_str, ..] -> {
                  let osc = parse_int(osc_str, voice.freq_mod_osc)
                  let depth = parse_float(depth_str, voice.freq_mod_depth)
                  #(
                    Voice(..voice, freq_mod_osc: osc, freq_mod_depth: depth),
                    envs,
                  )
                }
                _ -> #(voice, envs)
              }
            }
            False -> {
              let tgt = parse_int(val_str, -1)
              #(
                Voice(
                  ..voice,
                  freq_mod_osc: tgt,
                  freq_mod_depth: case tgt >= 0 {
                    True ->
                      case voice.freq_mod_depth == 0.0 {
                        True -> 2.0
                        False -> voice.freq_mod_depth
                      }
                    False -> 0.0
                  },
                ),
                envs,
              )
            }
          }
        }
        "ff" | "fmm" -> #(
          Voice(..voice, freq_mod_mode: parse_int(val_str, voice.freq_mod_mode)),
          envs,
        )
        "fb" | "fmfb" -> #(
          Voice(
            ..voice,
            freq_mod_feedback: parse_float(val_str, voice.freq_mod_feedback),
          ),
          envs,
        )
        "am" | "ampmod" -> {
          let tgt = parse_int(val_str, -1)
          #(
            Voice(..voice, amp_mod_osc: tgt, amp_mod_depth: case tgt >= 0 {
              True ->
                case voice.amp_mod_depth == 0.0 {
                  True -> 0.5
                  False -> voice.amp_mod_depth
                }
              False -> 0.0
            }),
            envs,
          )
        }
        "xm" | "ring" -> {
          let tgt = parse_int(val_str, -1)
          #(
            Voice(..voice, ring_osc: tgt, ring_amount: case tgt >= 0 {
              True ->
                case voice.ring_amount == 0.0 {
                  True -> 0.8
                  False -> voice.ring_amount
                }
              False -> 0.0
            }),
            envs,
          )
        }
        "cmod" | "czmod" -> {
          let tgt = parse_int(val_str, -1)
          #(
            Voice(..voice, cz_mod_osc: tgt, cz_mod_depth: case tgt >= 0 {
              True ->
                case voice.cz_mod_depth == 0.0 {
                  True -> 0.5
                  False -> voice.cz_mod_depth
                }
              False -> 0.0
            }),
            envs,
          )
        }
        "pm" | "panmod" -> {
          let tgt = parse_int(val_str, -1)
          #(
            Voice(..voice, pan_mod_osc: tgt, pan_mod_depth: case tgt >= 0 {
              True ->
                case voice.pan_mod_depth == 0.0 {
                  True -> 0.5
                  False -> voice.pan_mod_depth
                }
              False -> 0.0
            }),
            envs,
          )
        }
        "r" | "rec" -> #(
          Voice(
            ..voice,
            record: int.clamp(parse_int(val_str, voice.record), 0, 15),
          ),
          envs,
        )
        "m" | "mute" | "disc" -> #(
          Voice(..voice, disconnect: parse_int(val_str, voice.disconnect)),
          envs,
        )
        "l" | "gate" -> {
          let vel = parse_float(val_str, 1.0)
          #(
            Voice(..voice, use_amp_envelope: case vel >. 0.0 {
              True -> 1
              False -> 0
            }),
            envs,
          )
        }
        "i" -> {
          case string.starts_with(val_str, "~") {
            True -> {
              let note_str = string.drop_start(val_str, 1)
              #(
                Voice(
                  ..voice,
                  midi_note: param_gen.clamp_midi_note(parse_float(
                    note_str,
                    voice.midi_note,
                  )),
                  pitch_mode: 1,
                  glissando_enable: 1,
                  glissando_time: case voice.glissando_time == 0.0 {
                    True -> 0.05
                    False -> voice.glissando_time
                  },
                ),
                envs,
              )
            }
            False ->
              case val_str {
                "-" -> #(Voice(..voice, user_amp: -96.0), envs)
                "." -> #(Voice(..voice, use_amp_envelope: 1), envs)
                _ -> {
                  let note_val = parse_float(val_str, voice.midi_note)
                  #(
                    Voice(
                      ..voice,
                      midi_note: param_gen.clamp_midi_note(note_val),
                      pitch_mode: 1,
                      use_amp_envelope: 1,
                    ),
                    envs,
                  )
                }
              }
          }
        }
        "g" | "gl" | "gt" | "glide" -> {
          let parts = string.split(val_str, ",")
          case parts {
            [t_str, m_str, ..] -> {
              let t =
                param_gen.clamp_glissando_time(parse_float(
                  t_str,
                  voice.glissando_time,
                ))
              let m = parse_int(m_str, voice.glissando_mode)
              #(
                Voice(
                  ..voice,
                  glissando_time: t,
                  glissando_mode: m,
                  glissando_enable: case t >. 0.0 {
                    True -> 1
                    False -> 0
                  },
                ),
                envs,
              )
            }
            _ -> {
              let t =
                param_gen.clamp_glissando_time(parse_float(
                  val_str,
                  voice.glissando_time,
                ))
              #(
                Voice(
                  ..voice,
                  glissando_time: t,
                  glissando_enable: case t >. 0.0 {
                    True -> 1
                    False -> 0
                  },
                ),
                envs,
              )
            }
          }
        }
        "linkmidi" -> {
          let targets =
            string.split(val_str, ",")
            |> list.filter_map(fn(s) {
              case int.parse(string.trim(s)) {
                Ok(tid) if tid >= 0 && tid <= 255 -> Ok(int.to_float(tid))
                _ -> Error(Nil)
              }
            })
          #(Voice(..voice, link_midi: targets), envs)
        }
        "h" | "linkvelo" -> {
          let targets =
            string.split(val_str, ",")
            |> list.filter_map(fn(s) {
              case int.parse(string.trim(s)) {
                Ok(tid) if tid >= 0 && tid <= 255 -> Ok(int.to_float(tid))
                _ -> Error(Nil)
              }
            })
          #(Voice(..voice, link_velo: targets), envs)
        }
        "c" | "cz" -> {
          let parts = string.split(val_str, ",")
          case parts {
            [m_str, d_str, ..] -> {
              let m = param_gen.clamp_cz_mode(parse_int(m_str, voice.cz_mode))
              let d =
                param_gen.clamp_cz_distortion(parse_float(
                  d_str,
                  voice.cz_distortion,
                ))
              #(Voice(..voice, cz_mode: m, cz_distortion: d), envs)
            }
            [single] -> {
              case string.contains(single, ".") {
                True -> {
                  let d =
                    param_gen.clamp_cz_distortion(parse_float(
                      single,
                      voice.cz_distortion,
                    ))
                  let m = case voice.cz_mode == 0 {
                    True -> 1
                    False -> voice.cz_mode
                  }
                  #(Voice(..voice, cz_mode: m, cz_distortion: d), envs)
                }
                False -> {
                  let m =
                    param_gen.clamp_cz_mode(parse_int(single, voice.cz_mode))
                  let d = case voice.cz_distortion == 0.0 {
                    True -> 0.5
                    False -> voice.cz_distortion
                  }
                  #(Voice(..voice, cz_mode: m, cz_distortion: d), envs)
                }
              }
            }
            _ -> #(voice, envs)
          }
        }
        "czd" -> #(
          Voice(
            ..voice,
            cz_distortion: param_gen.clamp_cz_distortion(parse_float(
              val_str,
              voice.cz_distortion,
            )),
          ),
          envs,
        )
        "bc" | "qnt" -> #(
          Voice(..voice, quantize: parse_int(val_str, voice.quantize)),
          envs,
        )
        "sm" -> #(
          Voice(
            ..voice,
            smoother_smoothing: param_gen.clamp_smoother_smoothing(parse_float(
              val_str,
              voice.smoother_smoothing,
            )),
            smoother_enable: 1,
          ),
          envs,
        )
        "del" | "ds" -> #(
          Voice(
            ..voice,
            delay_send: param_gen.clamp_delay_send(parse_float(
              val_str,
              voice.delay_send,
            )),
          ),
          envs,
        )
        "bp" -> #(
          Voice(
            ..voice,
            freq_bend_range: param_gen.clamp_freq_bend_range(parse_float(
              val_str,
              voice.freq_bend_range,
            )),
          ),
          envs,
        )
        "abp" -> #(
          Voice(
            ..voice,
            amp_bend_range: param_gen.clamp_amp_bend_range(parse_float(
              val_str,
              voice.amp_bend_range,
            )),
          ),
          envs,
        )
        "reset" -> #(voice_gen.default(voice.id), default_voice_envelopes())
        _ -> #(voice, envs)
      }
    }
  }
}

// -----------------------------------------------------------------------------
// Pinned Card Reordering Helper
// -----------------------------------------------------------------------------

fn move_list_item(items: List(a), from: Int, to: Int) -> List(a) {
  let len = list.length(items)
  case from >= 0 && from < len && to >= 0 && to < len && from != to {
    False -> items
    True -> {
      let indexed = list.index_map(items, fn(item, idx) { #(idx, item) })
      case list.find(indexed, fn(p) { p.0 == from }) {
        Error(_) -> items
        Ok(#(_, target_item)) -> {
          let without = list.filter(indexed, fn(p) { p.0 != from })
          let #(before, after) = list.split(without, to)
          let reassembled = list.flatten([before, [#(-1, target_item)], after])
          list.map(reassembled, fn(p) { p.1 })
        }
      }
    }
  }
}

pub type ParsedStep {
  ParsedStep(pattern_id: Int, step_index: Int, code: String)
}

fn extract_step_spec_prefix(
  chars: List(String),
  acc: String,
) -> #(String, List(String)) {
  case chars {
    [ch, ..rest] ->
      case is_digit(ch) || ch == "," {
        True -> extract_step_spec_prefix(rest, acc <> ch)
        False -> #(acc, chars)
      }
    [] -> #(acc, [])
  }
}

fn scan_pattern_steps(
  chars: List(String),
  current_pid: Int,
  acc: List(ParsedStep),
) -> List(ParsedStep) {
  case chars {
    [] -> list.reverse(acc)
    ["y", ..rest] -> {
      let #(digits, rem) = extract_digits_prefix(rest, "")
      case int.parse(digits) {
        Ok(pid) if pid >= 0 && pid <= 127 -> scan_pattern_steps(rem, pid, acc)
        _ -> scan_pattern_steps(rest, current_pid, acc)
      }
    }
    ["[", ..rest] -> {
      let #(bracket_content, rem_after_bracket) =
        extract_until_closing_bracket(rest, "")
      case skip_spaces(rem_after_bracket) {
        ["x", ..after_x] | ["X", ..after_x] -> {
          let #(step_spec, rem_after_step) =
            extract_step_spec_prefix(after_x, "")
          let step_indices =
            string.split(step_spec, ",")
            |> list.filter_map(fn(s) {
              case int.parse(string.trim(s)) {
                Ok(s_idx) if s_idx >= 0 && s_idx <= 255 -> Ok(s_idx)
                _ -> Error(Nil)
              }
            })
          case step_indices {
            [_, ..] -> {
              let new_steps =
                list.map(step_indices, fn(s_idx) {
                  ParsedStep(current_pid, s_idx, string.trim(bracket_content))
                })
              scan_pattern_steps(
                rem_after_step,
                current_pid,
                list.append(new_steps, acc),
              )
            }
            [] -> scan_pattern_steps(rem_after_bracket, current_pid, acc)
          }
        }
        _ -> scan_pattern_steps(rem_after_bracket, current_pid, acc)
      }
    }
    [_, ..rest] -> scan_pattern_steps(rest, current_pid, acc)
  }
}

fn extract_digits_prefix(
  chars: List(String),
  acc: String,
) -> #(String, List(String)) {
  case chars {
    [ch, ..rest] ->
      case is_digit(ch) {
        True -> extract_digits_prefix(rest, acc <> ch)
        False -> #(acc, chars)
      }
    [] -> #(acc, [])
  }
}

fn extract_until_closing_bracket(
  chars: List(String),
  acc: String,
) -> #(String, List(String)) {
  case chars {
    ["]", ..rest] -> #(acc, rest)
    [ch, ..rest] -> extract_until_closing_bracket(rest, acc <> ch)
    [] -> #(acc, [])
  }
}

fn skip_spaces(chars: List(String)) -> List(String) {
  case chars {
    [" ", ..rest] | ["\t", ..rest] | ["\n", ..rest] -> skip_spaces(rest)
    _ -> chars
  }
}

fn parse_skode_steps_string(cmd: String, active_pid: Int) -> List(ParsedStep) {
  scan_pattern_steps(string.to_graphemes(cmd), active_pid, [])
}

fn apply_parsed_steps_to_patterns(
  patterns: List(Pattern),
  steps: List(ParsedStep),
) -> List(Pattern) {
  case steps {
    [] -> patterns
    [step, ..rest] -> {
      let #(target_pat, all_pats) =
        get_or_create_pattern(patterns, step.pattern_id)
      let updated_pat = case step.code {
        "" -> pattern.clear_step(target_pat, step.step_index)
        code -> pattern.set_step(target_pat, step.step_index, code)
      }
      let next_patterns = update_pattern_in_list(all_pats, updated_pat)
      apply_parsed_steps_to_patterns(next_patterns, rest)
    }
  }
}

fn parse_standalone_master_vol(token: String) -> Result(Float, Nil) {
  case string.pop_grapheme(token) {
    Ok(#("V", rest)) -> {
      case float.parse(rest) {
        Ok(db) -> Ok(db)
        Error(_) ->
          case int.parse(rest) {
            Ok(db_i) -> Ok(int.to_float(db_i))
            Error(_) -> Error(Nil)
          }
      }
    }
    _ -> Error(Nil)
  }
}

fn parse_standalone_tempo(token: String) -> Result(Float, Nil) {
  case string.pop_grapheme(token) {
    Ok(#("M", rest)) -> {
      case float.parse(rest) {
        Ok(bpm) -> Ok(bpm)
        Error(_) ->
          case int.parse(rest) {
            Ok(bpm_i) -> Ok(int.to_float(bpm_i))
            Error(_) -> Error(Nil)
          }
      }
    }
    _ -> Error(Nil)
  }
}

fn parse_engine_settings(
  tokens: List(String),
  engine: EngineSettings,
) -> EngineSettings {
  case tokens {
    [] -> engine
    ["V", val_str, ..rest] -> {
      let db = parse_float(val_str, engine.master_volume_db)
      let clamped = param.clamp_db(db)
      parse_engine_settings(rest, global.set_master_volume_db(engine, clamped))
    }
    ["M", bpm_str, sub_str, ..rest] -> {
      let bpm = parse_float(bpm_str, engine.tempo_bpm)
      let clamped_bpm = param.clamp_bpm(bpm)
      case float.parse(normalize_numeric_string(sub_str)) {
        Ok(sub) ->
          parse_engine_settings(
            rest,
            global.set_tempo(engine, clamped_bpm, sub),
          )
        Error(_) ->
          case int.parse(sub_str) {
            Ok(sub_i) ->
              parse_engine_settings(
                rest,
                global.set_tempo(engine, clamped_bpm, int.to_float(sub_i)),
              )
            Error(_) ->
              parse_engine_settings(
                [sub_str, ..rest],
                global.set_tempo(engine, clamped_bpm, engine.subdivision),
              )
          }
      }
    }
    ["M", bpm_str] -> {
      let bpm = parse_float(bpm_str, engine.tempo_bpm)
      let clamped_bpm = param.clamp_bpm(bpm)
      global.set_tempo(engine, clamped_bpm, engine.subdivision)
    }
    // Delay Bus commands: DS, DL, DD, DP, DF, DG
    ["DS", bus_str, bpm_str, div_str, ..rest]
    | ["ds", bus_str, bpm_str, div_str, ..rest] -> {
      let bus_id = parse_int(bus_str, 1)
      let bpm = parse_float(bpm_str, engine.tempo_bpm)
      let div = parse_float(div_str, 0.25)
      let next_engine =
        global.update_delay_bus(engine, bus_id, fn(b) {
          DelayBus(..b, sync: Some(#(bpm, div)))
        })
      parse_engine_settings(rest, next_engine)
    }
    ["DL", bus_str, c_str, f_str, fb_str, mf_str, md_str, lvl_str, ..rest]
    | ["dl", bus_str, c_str, f_str, fb_str, mf_str, md_str, lvl_str, ..rest] -> {
      let bus_id = parse_int(bus_str, 1)
      let next_engine =
        global.update_delay_bus(engine, bus_id, fn(b) {
          let c = case c_str {
            "-" -> b.coarse
            _ -> parse_int(c_str, b.coarse)
          }
          let f = case f_str {
            "-" -> b.fine
            _ -> parse_int(f_str, b.fine)
          }
          let fb = case fb_str {
            "-" -> b.feedback
            _ -> parse_int(fb_str, b.feedback)
          }
          let mf = case mf_str {
            "-" -> b.mod_freq
            _ -> parse_int(mf_str, b.mod_freq)
          }
          let md = case md_str {
            "-" -> b.mod_depth
            _ -> parse_int(md_str, b.mod_depth)
          }
          let lvl = case lvl_str {
            "-" -> b.level
            _ -> parse_int(lvl_str, b.level)
          }
          DelayBus(
            ..b,
            coarse: c,
            fine: f,
            feedback: fb,
            mod_freq: mf,
            mod_depth: md,
            level: lvl,
          )
        })
      parse_engine_settings(rest, next_engine)
    }
    ["DD", bus_str, damp_str, hp_str, ..rest]
    | ["dd", bus_str, damp_str, hp_str, ..rest] -> {
      let bus_id = parse_int(bus_str, 1)
      let next_engine =
        global.update_delay_bus(engine, bus_id, fn(b) {
          let d = case damp_str {
            "-" -> b.damping
            _ -> parse_int(damp_str, b.damping)
          }
          let hp = case hp_str {
            "-" -> b.highpass
            _ -> parse_int(hp_str, b.highpass)
          }
          DelayBus(..b, damping: d, highpass: hp)
        })
      parse_engine_settings(rest, next_engine)
    }
    ["DP", bus_str, pp_str, ..rest] | ["dp", bus_str, pp_str, ..rest] -> {
      let bus_id = parse_int(bus_str, 1)
      let pp = pp_str == "1" || pp_str == "true"
      let next_engine =
        global.update_delay_bus(engine, bus_id, fn(b) {
          DelayBus(..b, pingpong: pp)
        })
      parse_engine_settings(rest, next_engine)
    }
    ["DF", bus_str, fz_str, ..rest] | ["df", bus_str, fz_str, ..rest] -> {
      let bus_id = parse_int(bus_str, 1)
      let fz = fz_str == "1" || fz_str == "true"
      let next_engine =
        global.update_delay_bus(engine, bus_id, fn(b) {
          DelayBus(..b, freeze: fz)
        })
      parse_engine_settings(rest, next_engine)
    }
    ["DG", bus_str, bits_str, flt_str, ..rest]
    | ["dg", bus_str, bits_str, flt_str, ..rest] -> {
      let bus_id = parse_int(bus_str, 1)
      let grit = case flt_str {
        "1" -> NativeFloat
        _ -> Quantized(parse_int(bits_str, 12))
      }
      let next_engine =
        global.update_delay_bus(engine, bus_id, fn(b) {
          DelayBus(..b, grit: grit)
        })
      parse_engine_settings(rest, next_engine)
    }
    [tok, ..rest] -> {
      case parse_standalone_master_vol(tok) {
        Ok(db) -> {
          let clamped = param.clamp_db(db)
          parse_engine_settings(
            rest,
            global.set_master_volume_db(engine, clamped),
          )
        }
        Error(_) -> {
          case parse_standalone_tempo(tok) {
            Ok(bpm) -> {
              let clamped = param.clamp_bpm(bpm)
              parse_engine_settings(
                rest,
                global.set_tempo(engine, clamped, engine.subdivision),
              )
            }
            Error(_) -> parse_engine_settings(rest, engine)
          }
        }
      }
    }
  }
}

fn parse_voice_reset(tokens: List(String), current_vid: Int) -> Option(Int) {
  case tokens {
    [] -> None
    ["S", vid_str, ..] -> {
      case int.parse(vid_str) {
        Ok(vid) if vid >= 0 && vid <= 255 -> Some(vid)
        _ -> Some(current_vid)
      }
    }
    ["S"] -> Some(current_vid)
    [tok, ..rest] -> {
      case string.pop_grapheme(tok) {
        Ok(#("S", id_str)) -> {
          case int.parse(id_str) {
            Ok(vid) if vid >= 0 && vid <= 255 -> Some(vid)
            _ -> parse_voice_reset(rest, current_vid)
          }
        }
        _ -> parse_voice_reset(rest, current_vid)
      }
    }
  }
}

fn parse_pattern_reset(tokens: List(String), current_pid: Int) -> Option(Int) {
  case tokens {
    [] -> None
    ["Y", pid_str, ..] -> {
      case int.parse(pid_str) {
        Ok(pid) if pid >= 0 && pid <= 127 -> Some(pid)
        _ -> Some(current_pid)
      }
    }
    ["Y"] -> Some(current_pid)
    [tok, ..rest] -> {
      case string.pop_grapheme(tok) {
        Ok(#("Y", id_str)) -> {
          case int.parse(id_str) {
            Ok(pid) if pid >= 0 && pid <= 127 -> Some(pid)
            _ -> parse_pattern_reset(rest, current_pid)
          }
        }
        _ -> parse_pattern_reset(rest, current_pid)
      }
    }
  }
}

// -----------------------------------------------------------------------------
// Full Session Serialization for Archive & Project Export
// -----------------------------------------------------------------------------

pub fn generate_full_session_skode(model: Model) -> String {
  let lines = []

  // 1. Header
  let lines =
    list.append(lines, [
      "# -----------------------------------------------------------------------------",
      "# Pulp Studio Session Archive",
      "# -----------------------------------------------------------------------------",
      "",
    ])

  // 2. Engine Settings: Master Volume & Tempo
  let lines =
    list.append(lines, [
      "# --- Master Engine Settings ---",
      "V " <> param.format_float(model.engine_settings.master_volume_db),
      "M "
        <> param.format_float(model.engine_settings.tempo_bpm)
        <> " "
        <> param.format_float(model.engine_settings.subdivision),
      "",
    ])

  // 3. Delay Busses (d0..d3)
  let delay_lines = [
    "# --- 4-Bus Delay Matrix ---",
    delay.to_skode(get_delay_bus(model.engine_settings, 0)),
    delay.to_skode(get_delay_bus(model.engine_settings, 1)),
    delay.to_skode(get_delay_bus(model.engine_settings, 2)),
    delay.to_skode(get_delay_bus(model.engine_settings, 3)),
    "",
  ]
  let lines = list.append(lines, delay_lines)

  // 4. Global Variables ($0..$127)
  let var_entries =
    dict.to_list(model.variables)
    |> list.filter(fn(p) { p.1 != 0.0 })
    |> list.sort(fn(a, b) { int.compare(a.0, b.0) })
    |> list.map(fn(p) {
      "=" <> int.to_string(p.0) <> "," <> param.format_float(p.1)
    })
  let lines = case var_entries {
    [] -> lines
    vs ->
      list.append(
        lines,
        list.flatten([["# --- Global Variables ---"], vs, [""]]),
      )
  }

  // 5. Modulation Streams (&0..&15)
  let stream_entries =
    dict.to_list(model.stream_slots)
    |> list.sort(fn(a, b) { int.compare(a.0, b.0) })
    |> list.filter_map(fn(p) {
      let #(slot, s) = p
      let trimmed = string.trim(s.data)
      case trimmed {
        "" -> Error(Nil)
        data ->
          Ok(
            [
              "( " <> data <> " ) /SS " <> int.to_string(slot),
              case s.mode != 0 {
                True ->
                  "/SM " <> int.to_string(slot) <> " " <> int.to_string(s.mode)
                False -> ""
              },
              case s.pos != 0 {
                True ->
                  "/SP " <> int.to_string(slot) <> " " <> int.to_string(s.pos)
                False -> ""
              },
            ]
            |> list.filter(fn(line) { line != "" }),
          )
      }
    })
    |> list.flatten
  let lines = case stream_entries {
    [] -> lines
    ss ->
      list.append(
        lines,
        list.flatten([["# --- Modulation Streams ---"], ss, [""]]),
      )
  }

  // 6. User Macros (e!0..e!15)
  let macro_entries =
    model.macros
    |> list.sort(fn(a, b) { int.compare(a.0, b.0) })
    |> list.filter_map(fn(p) {
      let #(slot, code_str) = p
      case string.trim(code_str) {
        "" -> Error(Nil)
        c -> Ok("[" <> c <> "] /m " <> int.to_string(slot))
      }
    })
  let lines = case macro_entries {
    [] -> lines
    ms ->
      list.append(lines, list.flatten([["# --- User Macros ---"], ms, [""]]))
  }

  // 7. Synthesizer Voices
  let voice_entries =
    model.all_voices
    |> list.sort(fn(a, b) { int.compare(a.id, b.id) })
    |> list.map(fn(v) {
      let v_skode = voice_gen.to_skode(v)
      let env_skode = case list.key_find(model.all_envelopes, v.id) {
        Ok(e) ->
          "v"
          <> int.to_string(v.id)
          <> " t "
          <> param.format_float(e.amp_env.attack)
          <> ","
          <> param.format_float(e.amp_env.decay)
          <> ","
          <> param.format_float(e.amp_env.sustain)
          <> ","
          <> param.format_float(e.amp_env.release)
        Error(_) -> ""
      }
      [v_skode, env_skode]
    })
    |> list.flatten
    |> list.filter(fn(l) { l != "" })
  let lines =
    list.append(
      lines,
      list.flatten([["# --- Synthesizer Voices ---"], voice_entries, [""]]),
    )

  // 8. Sequencer Patterns
  let pattern_entries =
    model.all_patterns
    |> list.sort(fn(a, b) { int.compare(a.id, b.id) })
    |> list.filter_map(fn(p) {
      case dict.size(p.steps) > 0 || p.speed != 1 || p.mute {
        True -> Ok(pattern.to_skode(p))
        False -> Error(Nil)
      }
    })
  let lines = case pattern_entries {
    [] -> lines
    ps ->
      list.append(
        lines,
        list.flatten([["# --- Sequencer Patterns ---"], ps, [""]]),
      )
  }

  string.join(lines, "\n")
}

fn find_slash_ss(chars: List(String)) -> Result(#(Int, List(String)), Nil) {
  case chars {
    [] -> Error(Nil)
    ["/", "S", "S", ..after_ss] | ["/", "s", "s", ..after_ss] -> {
      let after_spaces = skip_spaces(after_ss)
      let #(slot_digits, rem_after_slot) =
        extract_digits_prefix(after_spaces, "")
      case int.parse(slot_digits) {
        Ok(slot_id) if slot_id >= 0 && slot_id <= 15 ->
          Ok(#(slot_id, rem_after_slot))
        _ -> Error(Nil)
      }
    }
    [_, ..rest] -> find_slash_ss(rest)
  }
}

fn scan_stream_definitions(
  chars: List(String),
  slots: dict.Dict(Int, StreamSlot),
) -> dict.Dict(Int, StreamSlot) {
  case chars {
    [] -> slots
    ["(", ..rest] -> {
      let #(paren_content, rem_after_paren) =
        extract_until_closing_paren(rest, "")
      case find_slash_ss(rem_after_paren) {
        Ok(#(slot_id, rem_after_slot)) -> {
          let cur_slot = case dict.get(slots, slot_id) {
            Ok(s) -> s
            Error(_) -> StreamSlot(slot_id, 0, 0, "")
          }
          let updated = StreamSlot(..cur_slot, data: string.trim(paren_content))
          scan_stream_definitions(
            rem_after_slot,
            dict.insert(slots, slot_id, updated),
          )
        }
        Error(_) -> scan_stream_definitions(rem_after_paren, slots)
      }
    }
    ["[", ..rest] -> {
      let #(bracket_content, rem_after_bracket) =
        extract_until_closing_bracket(rest, "")
      case find_slash_ss(rem_after_bracket) {
        Ok(#(slot_id, rem_after_slot)) -> {
          let cur_slot = case dict.get(slots, slot_id) {
            Ok(s) -> s
            Error(_) -> StreamSlot(slot_id, 0, 0, "")
          }
          let updated =
            StreamSlot(..cur_slot, data: string.trim(bracket_content))
          scan_stream_definitions(
            rem_after_slot,
            dict.insert(slots, slot_id, updated),
          )
        }
        Error(_) -> scan_stream_definitions(rem_after_bracket, slots)
      }
    }
    ["/", "S", "C", ..rest] | ["/", "s", "c", ..rest] -> {
      let after_spaces = skip_spaces(rest)
      let #(dest_digits, rem1) = extract_digits_prefix(after_spaces, "")
      let rem1_spaces = skip_spaces(rem1)
      let #(src_digits, rem2) = extract_digits_prefix(rem1_spaces, "")
      case int.parse(dest_digits), int.parse(src_digits) {
        Ok(dest_id), Ok(src_id)
          if dest_id >= 0 && dest_id <= 15 && src_id >= 0 && src_id <= 15
        -> {
          let src_slot = case dict.get(slots, src_id) {
            Ok(s) -> s
            Error(_) -> StreamSlot(src_id, 0, 0, "")
          }
          let updated =
            StreamSlot(dest_id, src_slot.mode, src_slot.pos, src_slot.data)
          scan_stream_definitions(rem2, dict.insert(slots, dest_id, updated))
        }
        _, _ -> scan_stream_definitions(rest, slots)
      }
    }
    ["/", "S", "M", ..rest] | ["/", "s", "m", ..rest] -> {
      let after_spaces = skip_spaces(rest)
      let #(slot_digits, rem1) = extract_digits_prefix(after_spaces, "")
      let rem1_spaces = skip_spaces(rem1)
      let #(mode_digits, rem2) = extract_digits_prefix(rem1_spaces, "")
      case int.parse(slot_digits), int.parse(mode_digits) {
        Ok(slot_id), Ok(mode) if slot_id >= 0 && slot_id <= 15 -> {
          let cur_slot = case dict.get(slots, slot_id) {
            Ok(s) -> s
            Error(_) -> StreamSlot(slot_id, 0, 0, "")
          }
          let updated = StreamSlot(..cur_slot, mode: mode)
          scan_stream_definitions(rem2, dict.insert(slots, slot_id, updated))
        }
        _, _ -> scan_stream_definitions(rest, slots)
      }
    }
    ["/", "S", "P", ..rest] | ["/", "s", "p", ..rest] -> {
      let after_spaces = skip_spaces(rest)
      let #(slot_digits, rem1) = extract_digits_prefix(after_spaces, "")
      let rem1_spaces = skip_spaces(rem1)
      let #(pos_digits, rem2) = extract_digits_prefix(rem1_spaces, "")
      case int.parse(slot_digits), int.parse(pos_digits) {
        Ok(slot_id), Ok(pos) if slot_id >= 0 && slot_id <= 15 -> {
          let cur_slot = case dict.get(slots, slot_id) {
            Ok(s) -> s
            Error(_) -> StreamSlot(slot_id, 0, 0, "")
          }
          let updated = StreamSlot(..cur_slot, pos: pos)
          scan_stream_definitions(rem2, dict.insert(slots, slot_id, updated))
        }
        _, _ -> scan_stream_definitions(rest, slots)
      }
    }
    [_, ..rest] -> scan_stream_definitions(rest, slots)
  }
}

fn extract_until_closing_paren(
  chars: List(String),
  acc: String,
) -> #(String, List(String)) {
  case chars {
    [")", ..rest] -> #(acc, rest)
    [ch, ..rest] -> extract_until_closing_paren(rest, acc <> ch)
    [] -> #(acc, [])
  }
}

fn parse_variable_command(
  tokens: List(String),
  vars: dict.Dict(Int, Float),
) -> dict.Dict(Int, Float) {
  case tokens {
    [] -> vars
    ["=", var_str, val_str, ..rest] -> {
      let var_id = parse_int(var_str, -1)
      let val = parse_float(val_str, 0.0)
      case var_id >= 0 && var_id <= 127 {
        True -> parse_variable_command(rest, dict.insert(vars, var_id, val))
        False -> parse_variable_command(rest, vars)
      }
    }
    [tok, ..rest] -> {
      case string.starts_with(tok, "=") {
        True -> {
          let after_eq = string.drop_start(tok, 1)
          case string.split(after_eq, ",") {
            [var_str, val_str] -> {
              let var_id = parse_int(var_str, -1)
              let val = parse_float(val_str, 0.0)
              case var_id >= 0 && var_id <= 127 {
                True ->
                  parse_variable_command(rest, dict.insert(vars, var_id, val))
                False -> parse_variable_command(rest, vars)
              }
            }
            _ -> parse_variable_command(rest, vars)
          }
        }
        False -> {
          case string.starts_with(tok, "a=") {
            True -> {
              let after_op = string.drop_start(tok, 2)
              case string.split(after_op, ",") {
                [var_str, val_str] -> {
                  let var_id = parse_int(var_str, -1)
                  let val = parse_float(val_str, 0.0)
                  case var_id >= 0 && var_id <= 127 {
                    True -> {
                      let old_val = case dict.get(vars, var_id) {
                        Ok(v) -> v
                        Error(_) -> 0.0
                      }
                      parse_variable_command(
                        rest,
                        dict.insert(vars, var_id, old_val +. val),
                      )
                    }
                    False -> parse_variable_command(rest, vars)
                  }
                }
                _ -> parse_variable_command(rest, vars)
              }
            }
            False -> parse_variable_command(rest, vars)
          }
        }
      }
    }
  }
}

fn parse_pattern_pointer(tokens: List(String)) -> Option(Int) {
  case tokens {
    [] -> None
    ["y", next_tok, ..] -> {
      case int.parse(next_tok) {
        Ok(id) if id >= 0 && id <= 127 -> Some(id)
        _ -> None
      }
    }
    [tok, ..rest] -> {
      case string.pop_grapheme(tok) {
        Ok(#("y", id_str)) -> {
          case int.parse(id_str) {
            Ok(id) if id >= 0 && id <= 127 -> Some(id)
            _ -> parse_pattern_pointer(rest)
          }
        }
        _ -> parse_pattern_pointer(rest)
      }
    }
  }
}

fn parse_standalone_y(token: String) -> Result(Int, Nil) {
  case string.pop_grapheme(token) {
    Ok(#("y", rest)) -> {
      case int.parse(rest) {
        Ok(id) if id >= 0 && id <= 127 -> Ok(id)
        _ -> Error(Nil)
      }
    }
    _ -> Error(Nil)
  }
}

fn parse_voice_pointer(tokens: List(String)) -> Option(Int) {
  case tokens {
    [] -> None
    ["v", next_tok, ..] -> {
      case int.parse(next_tok) {
        Ok(id) if id >= 0 && id <= 255 -> Some(id)
        _ -> None
      }
    }
    [tok, ..rest] -> {
      case string.pop_grapheme(tok) {
        Ok(#("v", id_str)) -> {
          case int.parse(id_str) {
            Ok(id) if id >= 0 && id <= 255 -> Some(id)
            _ -> parse_voice_pointer(rest)
          }
        }
        _ -> parse_voice_pointer(rest)
      }
    }
  }
}

fn parse_delay_pointer(tokens: List(String)) -> Option(Int) {
  case tokens {
    [] -> None
    ["d", next_tok, ..] | ["D", next_tok, ..] -> {
      case int.parse(next_tok) {
        Ok(id) if id >= 0 && id <= 3 -> Some(id)
        _ -> None
      }
    }
    [tok, ..rest] -> {
      case string.pop_grapheme(tok) {
        Ok(#("d", id_str)) | Ok(#("D", id_str)) -> {
          case int.parse(id_str) {
            Ok(id) if id >= 0 && id <= 3 -> Some(id)
            _ -> parse_delay_pointer(rest)
          }
        }
        _ -> parse_delay_pointer(rest)
      }
    }
  }
}

fn apply_pattern_tokens(
  pat: Pattern,
  tokens: List(String),
  changes: List(String),
) -> #(Pattern, List(String)) {
  case tokens {
    [] -> #(pat, list.reverse(changes))
    ["%", spd_str, ..rest] -> {
      let spd = parse_int(spd_str, pat.speed)
      let clamped = int.clamp(spd, 1, 64)
      apply_pattern_tokens(Pattern(..pat, speed: clamped), rest, [
        "speed " <> int.to_string(clamped),
        ..changes
      ])
    }
    ["z0", ..rest] | ["Z0", ..rest] ->
      apply_pattern_tokens(Pattern(..pat, state: PatternStopped), rest, [
        "stopped",
        ..changes
      ])
    ["z1", ..rest] | ["Z1", ..rest] ->
      apply_pattern_tokens(Pattern(..pat, state: PatternRunning), rest, [
        "running",
        ..changes
      ])
    ["z2", ..rest] | ["Z2", ..rest] ->
      apply_pattern_tokens(Pattern(..pat, state: PatternPaused), rest, [
        "paused",
        ..changes
      ])
    ["zmu0", ..rest] ->
      apply_pattern_tokens(Pattern(..pat, mute: False), rest, [
        "unmuted",
        ..changes
      ])
    ["zmu1", ..rest] ->
      apply_pattern_tokens(Pattern(..pat, mute: True), rest, [
        "muted",
        ..changes
      ])
    ["ce0", ..rest] ->
      apply_pattern_tokens(Pattern(..pat, control_events: False), rest, [
        "ce off",
        ..changes
      ])
    ["ce1", ..rest] ->
      apply_pattern_tokens(Pattern(..pat, control_events: True), rest, [
        "ce on",
        ..changes
      ])
    [tok, ..rest] -> {
      case string.pop_grapheme(tok) {
        Ok(#("%", spd_str)) -> {
          let spd = parse_int(spd_str, pat.speed)
          let clamped = int.clamp(spd, 1, 64)
          apply_pattern_tokens(Pattern(..pat, speed: clamped), rest, [
            "speed " <> int.to_string(clamped),
            ..changes
          ])
        }
        _ -> apply_pattern_tokens(pat, rest, changes)
      }
    }
  }
}

fn parse_pattern_command_line(
  tokens: List(String),
  current_pid: Int,
  patterns: List(Pattern),
) -> #(List(String), Option(Int), List(Pattern)) {
  let maybe_pid = parse_pattern_pointer(tokens)
  let target_pid = case maybe_pid {
    Some(p) -> p
    None -> current_pid
  }
  let #(target_pat, all_pats) = get_or_create_pattern(patterns, target_pid)
  let #(updated_pat, changes) = apply_pattern_tokens(target_pat, tokens, [])
  let final_pats = update_pattern_in_list(all_pats, updated_pat)
  #(changes, maybe_pid, final_pats)
}

fn parse_standalone_v(token: String) -> Result(Int, Nil) {
  case string.pop_grapheme(token) {
    Ok(#("v", rest)) -> {
      case int.parse(rest) {
        Ok(id) if id >= 0 && id <= 255 -> Ok(id)
        _ -> Error(Nil)
      }
    }
    _ -> Error(Nil)
  }
}

fn parse_attached_v_prefix(token: String) -> Result(#(Int, String), Nil) {
  case string.pop_grapheme(token) {
    Ok(#("v", rest)) -> {
      extract_leading_digits(rest, "")
    }
    _ -> Error(Nil)
  }
}

fn extract_leading_digits(
  str: String,
  acc: String,
) -> Result(#(Int, String), Nil) {
  case string.pop_grapheme(str) {
    Ok(#(ch, rest)) -> {
      case is_digit(ch) {
        True -> extract_leading_digits(rest, acc <> ch)
        False -> {
          case acc {
            "" -> Error(Nil)
            digits -> {
              case int.parse(digits) {
                Ok(id) if id >= 0 && id <= 255 -> Ok(#(id, str))
                _ -> Error(Nil)
              }
            }
          }
        }
      }
    }
    Error(_) -> Error(Nil)
  }
}

fn is_value_token(tok: String) -> Bool {
  case string.pop_grapheme(tok) {
    Ok(#(ch, _)) ->
      is_digit(ch) || ch == "-" || ch == "+" || ch == "." || ch == "~"
    Error(_) -> False
  }
}

fn consume_value_tokens(
  tokens: List(String),
  acc: List(String),
) -> #(List(String), List(String)) {
  case tokens {
    [t, ..rest] ->
      case is_value_token(t) {
        True -> consume_value_tokens(rest, [t, ..acc])
        False -> #(list.reverse(acc), tokens)
      }
    [] -> #(list.reverse(acc), [])
  }
}

fn apply_token_to_state(
  voices: List(Voice),
  envelopes: List(#(Int, VoiceEnvelopes)),
  voice_id: Int,
  token: String,
) -> #(List(Voice), List(#(Int, VoiceEnvelopes))) {
  let #(target_v, cur_voices) = get_or_create_voice(voices, voice_id)
  let cur_envs = case list.key_find(envelopes, voice_id) {
    Ok(e) -> e
    Error(_) -> default_voice_envelopes()
  }
  let #(updated_v, updated_envs) = apply_single_token(target_v, cur_envs, token)
  let next_voices = update_voice_in_list(cur_voices, updated_v)
  let next_envs = list.key_set(envelopes, voice_id, updated_envs)
  #(next_voices, next_envs)
}

fn opcode_to_pill_id(op: String) -> Option(PillId) {
  case string.lowercase(op) {
    "w" | "wave" -> Some(PillWave)
    "f" | "freq" -> Some(PillFreq)
    "n" | "note" -> Some(PillNote)
    "pmode" | "pitchmode" -> Some(PillPitchMode)
    "a" | "amp" -> Some(PillAmp)
    "p" | "pan" -> Some(PillPan)
    "j" -> Some(PillFilterMode)
    "k" -> Some(PillFilterFreq)
    "q" -> Some(PillFilterRes)
    "fmd" | "fed" | "fd" -> Some(PillFilterEnvDepth)
    "t" -> Some(PillAmpEnv)
    "kt" | "ft" -> Some(PillFilterEnv)
    "hs" | "linksync" -> Some(PillLinkSync)
    "fm" | "freqmod" -> Some(PillLinkFreqMod)
    "am" | "ampmod" -> Some(PillLinkAmpMod)
    "xm" | "ring" -> Some(PillLinkRingMod)
    "cmod" | "czmod" -> Some(PillLinkCzMod)
    "pm" | "panmod" -> Some(PillLinkPanMod)
    "r" | "rec" -> Some(PillRecordTrack)
    "g" | "gl" | "gt" | "glide" -> Some(PillGlissando)
    "linkmidi" -> Some(PillLinkMidi)
    "h" | "linkvelo" -> Some(PillLinkVelo)
    "sm" -> Some(PillSmoother)
    "c" | "cz" | "czd" -> Some(PillCzDistortion)
    "sh" -> Some(PillSampleHold)
    "qnt" | "bc" -> Some(PillQuantize)
    "del" | "ds" -> Some(PillDelaySend)
    "bp" -> Some(PillFreqBend)
    "abp" -> Some(PillAmpBend)
    _ -> None
  }
}

fn token_to_pill_id(token: String) -> Option(PillId) {
  let #(op, _) = split_op_val(token)
  case op {
    "G" -> Some(PillLinkMidi)
    "H" -> Some(PillLinkVelo)
    _ -> opcode_to_pill_id(op)
  }
}

fn parse_tokens_streaming(
  voices: List(Voice),
  envelopes: List(#(Int, VoiceEnvelopes)),
  current_voice_id: Int,
  tokens: List(String),
  touched_acc: List(#(Int, PillId)),
) -> #(List(Voice), List(#(Int, VoiceEnvelopes)), Int, List(#(Int, PillId))) {
  case tokens {
    [] -> #(voices, envelopes, current_voice_id, list.reverse(touched_acc))
    ["", ..rest] ->
      parse_tokens_streaming(
        voices,
        envelopes,
        current_voice_id,
        rest,
        touched_acc,
      )

    [tok, ..rest] -> {
      // Skip pattern pointer and modifier tokens in voice streaming parser
      case parse_standalone_y(tok) {
        Ok(_) ->
          parse_tokens_streaming(
            voices,
            envelopes,
            current_voice_id,
            rest,
            touched_acc,
          )
        Error(_) -> {
          case tok {
            "y" | "Y" | "%" -> {
              case rest {
                [_, ..after_arg] ->
                  parse_tokens_streaming(
                    voices,
                    envelopes,
                    current_voice_id,
                    after_arg,
                    touched_acc,
                  )
                [] ->
                  parse_tokens_streaming(
                    voices,
                    envelopes,
                    current_voice_id,
                    [],
                    touched_acc,
                  )
              }
            }
            "z0"
            | "Z0"
            | "z1"
            | "Z1"
            | "z2"
            | "Z2"
            | "zmu0"
            | "zmu1"
            | "ce0"
            | "ce1" ->
              parse_tokens_streaming(
                voices,
                envelopes,
                current_voice_id,
                rest,
                touched_acc,
              )
            "V" -> {
              case rest {
                [_, ..after_arg] ->
                  parse_tokens_streaming(
                    voices,
                    envelopes,
                    current_voice_id,
                    after_arg,
                    touched_acc,
                  )
                [] ->
                  parse_tokens_streaming(
                    voices,
                    envelopes,
                    current_voice_id,
                    [],
                    touched_acc,
                  )
              }
            }
            "M" -> {
              let after_m = case rest {
                [_, s, ..rem] -> {
                  case float.parse(normalize_numeric_string(s)) {
                    Ok(_) -> rem
                    Error(_) ->
                      case int.parse(s) {
                        Ok(_) -> rem
                        Error(_) -> [s, ..rem]
                      }
                  }
                }
                [_, ..rem] -> rem
                [] -> []
              }
              parse_tokens_streaming(
                voices,
                envelopes,
                current_voice_id,
                after_m,
                touched_acc,
              )
            }
            "DS" -> {
              case rest {
                [_, _, _, ..after_ds] ->
                  parse_tokens_streaming(
                    voices,
                    envelopes,
                    current_voice_id,
                    after_ds,
                    touched_acc,
                  )
                _ ->
                  parse_tokens_streaming(
                    voices,
                    envelopes,
                    current_voice_id,
                    [],
                    touched_acc,
                  )
              }
            }
            "DL" -> {
              case rest {
                [_, _, _, _, _, _, _, ..after_dl] ->
                  parse_tokens_streaming(
                    voices,
                    envelopes,
                    current_voice_id,
                    after_dl,
                    touched_acc,
                  )
                _ ->
                  parse_tokens_streaming(
                    voices,
                    envelopes,
                    current_voice_id,
                    [],
                    touched_acc,
                  )
              }
            }
            "DD" -> {
              case rest {
                [_, _, ..after_dd] ->
                  parse_tokens_streaming(
                    voices,
                    envelopes,
                    current_voice_id,
                    after_dd,
                    touched_acc,
                  )
                _ ->
                  parse_tokens_streaming(
                    voices,
                    envelopes,
                    current_voice_id,
                    [],
                    touched_acc,
                  )
              }
            }
            "DP" -> {
              case rest {
                [_, ..after_dp] ->
                  parse_tokens_streaming(
                    voices,
                    envelopes,
                    current_voice_id,
                    after_dp,
                    touched_acc,
                  )
                _ ->
                  parse_tokens_streaming(
                    voices,
                    envelopes,
                    current_voice_id,
                    [],
                    touched_acc,
                  )
              }
            }
            "DF" -> {
              case rest {
                [_, ..after_df] ->
                  parse_tokens_streaming(
                    voices,
                    envelopes,
                    current_voice_id,
                    after_df,
                    touched_acc,
                  )
                _ ->
                  parse_tokens_streaming(
                    voices,
                    envelopes,
                    current_voice_id,
                    [],
                    touched_acc,
                  )
              }
            }
            "DG" -> {
              case rest {
                [_, _, ..after_dg] ->
                  parse_tokens_streaming(
                    voices,
                    envelopes,
                    current_voice_id,
                    after_dg,
                    touched_acc,
                  )
                _ ->
                  parse_tokens_streaming(
                    voices,
                    envelopes,
                    current_voice_id,
                    [],
                    touched_acc,
                  )
              }
            }
            "[" <> _ | "/" <> _ | "=" <> _ | "#" <> _ ->
              parse_tokens_streaming(
                voices,
                envelopes,
                current_voice_id,
                rest,
                touched_acc,
              )
            _ -> {
              // 1. Standalone voice pointer: 'v0', 'v12'
              case parse_standalone_v(tok) {
                Ok(new_voice_id) ->
                  parse_tokens_streaming(
                    voices,
                    envelopes,
                    new_voice_id,
                    rest,
                    touched_acc,
                  )
                Error(_) -> {
                  // 2. Attached voice prefix: 'v0G1' or 'v1w2'
                  case parse_attached_v_prefix(tok) {
                    Ok(#(voice_id, sub_token)) -> {
                      let #(updated_voices, updated_envs) =
                        apply_token_to_state(
                          voices,
                          envelopes,
                          voice_id,
                          sub_token,
                        )
                      let next_touched = case token_to_pill_id(sub_token) {
                        Some(pid) -> [#(voice_id, pid), ..touched_acc]
                        None -> touched_acc
                      }
                      parse_tokens_streaming(
                        updated_voices,
                        updated_envs,
                        voice_id,
                        rest,
                        next_touched,
                      )
                    }
                    Error(_) -> {
                      let #(consumed_vals, rem_tokens) =
                        consume_value_tokens(rest, [])
                      case consumed_vals {
                        [_, ..] -> {
                          let combined_val = string.join(consumed_vals, ",")
                          let combined = tok <> combined_val
                          let #(updated_voices, updated_envs) =
                            apply_token_to_state(
                              voices,
                              envelopes,
                              current_voice_id,
                              combined,
                            )
                          let next_touched = case token_to_pill_id(combined) {
                            Some(pid) -> [
                              #(current_voice_id, pid),
                              ..touched_acc
                            ]
                            None -> touched_acc
                          }
                          parse_tokens_streaming(
                            updated_voices,
                            updated_envs,
                            current_voice_id,
                            rem_tokens,
                            next_touched,
                          )
                        }
                        [] -> {
                          let #(updated_voices, updated_envs) =
                            apply_token_to_state(
                              voices,
                              envelopes,
                              current_voice_id,
                              tok,
                            )
                          let next_touched = case token_to_pill_id(tok) {
                            Some(pid) -> [
                              #(current_voice_id, pid),
                              ..touched_acc
                            ]
                            None -> touched_acc
                          }
                          parse_tokens_streaming(
                            updated_voices,
                            updated_envs,
                            current_voice_id,
                            rest,
                            next_touched,
                          )
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}

fn tokenize_skode_string(input: String) -> List(String) {
  tokenize_chars(string.to_graphemes(input), "", False, [])
}

fn tokenize_chars(
  chars: List(String),
  current: String,
  in_val: Bool,
  acc: List(String),
) -> List(String) {
  case chars {
    [] ->
      case string.trim(current) {
        "" -> list.reverse(acc)
        tok -> list.reverse([tok, ..acc])
      }

    [" ", ..rest] | ["\t", ..rest] | ["\n", ..rest] ->
      case string.trim(current) {
        "" -> tokenize_chars(rest, "", False, acc)
        tok -> tokenize_chars(rest, "", False, [tok, ..acc])
      }

    [ch, ..rest] -> {
      let is_letter = is_alpha(ch)
      case is_letter && in_val {
        True -> {
          let next_acc = case string.trim(current) {
            "" -> acc
            tok -> [tok, ..acc]
          }
          tokenize_chars(rest, ch, False, next_acc)
        }
        False -> {
          let next_in_val =
            in_val
            || is_digit(ch)
            || ch == "."
            || ch == "-"
            || ch == "+"
            || ch == ","
          tokenize_chars(rest, current <> ch, next_in_val, acc)
        }
      }
    }
  }
}

fn apply_skode_string_to_state(
  voices: List(Voice),
  envelopes: List(#(Int, VoiceEnvelopes)),
  default_voice_id: Int,
  text: String,
) -> #(List(Voice), List(#(Int, VoiceEnvelopes)), Int, List(#(Int, PillId))) {
  let tokens = tokenize_skode_string(text)
  parse_tokens_streaming(voices, envelopes, default_voice_id, tokens, [])
}

fn count_bracket_depth(chars: List(String), depth: Int) -> Int {
  case chars {
    [] -> depth
    ["[", ..rest] -> count_bracket_depth(rest, depth + 1)
    ["]", ..rest] -> count_bracket_depth(rest, int.max(0, depth - 1))
    [_, ..rest] -> count_bracket_depth(rest, depth)
  }
}

fn chunk_script_commands(
  lines: List(String),
  current: String,
  depth: Int,
  acc: List(String),
) -> List(String) {
  case lines {
    [] -> {
      case string.trim(current) {
        "" -> list.reverse(acc)
        c -> list.reverse([c, ..acc])
      }
    }
    [line, ..rest] -> {
      let trimmed = string.trim(line)
      case depth == 0 {
        True -> {
          case
            trimmed == ""
            || string.starts_with(trimmed, "#")
            || string.starts_with(trimmed, "//")
          {
            True -> chunk_script_commands(rest, "", 0, acc)
            False -> {
              let line_depth =
                count_bracket_depth(string.to_graphemes(trimmed), 0)
              case line_depth {
                0 -> chunk_script_commands(rest, "", 0, [trimmed, ..acc])
                d -> chunk_script_commands(rest, trimmed, d, acc)
              }
            }
          }
        }
        False -> {
          let joined = current <> "\n" <> trimmed
          let new_depth =
            count_bracket_depth(string.to_graphemes(trimmed), depth)
          case new_depth {
            0 -> chunk_script_commands(rest, "", 0, [joined, ..acc])
            d -> chunk_script_commands(rest, joined, d, acc)
          }
        }
      }
    }
  }
}

pub fn apply_skode_command_to_model(model: Model, cmd: String) -> Model {
  let trimmed = string.trim(cmd)
  case trimmed {
    "" -> model
    "#" <> _ -> model
    "//" <> _ -> model
    _ -> {
      let parsed_toks = tokenize_skode_string(trimmed)

      // 1. Pattern pointer or modifications (y<N>, %, z, zmu, etc.)
      let #(_pattern_changes, maybe_new_pid, updated_patterns_base) =
        parse_pattern_command_line(
          parsed_toks,
          model.active_pattern_id,
          model.all_patterns,
        )

      let active_p_target = case maybe_new_pid {
        Some(pid) -> pid
        None -> model.active_pattern_id
      }
      let updated_patterns_reset = case
        parse_pattern_reset(parsed_toks, active_p_target)
      {
        Some(r_pid) -> {
          let #(_p, all_p) = get_or_create_pattern(updated_patterns_base, r_pid)
          update_pattern_in_list(all_p, pattern.default(r_pid))
        }
        None -> updated_patterns_base
      }

      // 1b. Pattern steps: [code] x<steps>
      let parsed_steps = parse_skode_steps_string(trimmed, active_p_target)
      let updated_patterns =
        apply_parsed_steps_to_patterns(updated_patterns_reset, parsed_steps)

      // 2. Delay pointer (d0..d3)
      let maybe_new_did = parse_delay_pointer(parsed_toks)

      // 3. Voice pointer (v0..v255)
      let maybe_new_vid = parse_voice_pointer(parsed_toks)

      // 3b. Master Volume, Tempo BPM, and Delay buses
      let next_engine =
        parse_engine_settings(parsed_toks, model.engine_settings)

      // 3c. Variables
      let next_vars = parse_variable_command(parsed_toks, model.variables)

      // 3d. Stream definitions
      let next_stream_slots =
        scan_stream_definitions(
          string.to_graphemes(trimmed),
          model.stream_slots,
        )

      // 4. Voice parameters
      let target_vid = case maybe_new_vid {
        Some(v) -> v
        None -> model.voice.id
      }
      let #(new_all_raw, new_envs_raw, final_vid_raw, _touched) =
        apply_skode_string_to_state(
          model.all_voices,
          model.all_envelopes,
          target_vid,
          trimmed,
        )

      let #(new_all, new_envs, final_vid) = case
        parse_voice_reset(parsed_toks, target_vid)
      {
        Some(r_vid) -> {
          let #(_v, all_v) = get_or_create_voice(new_all_raw, r_vid)
          let cleared_v = voice_gen.default(r_vid)
          let updated_v_list = update_voice_in_list(all_v, cleared_v)
          let updated_envs =
            list.key_set(new_envs_raw, r_vid, default_voice_envelopes())
          #(updated_v_list, updated_envs, r_vid)
        }
        None -> #(new_all_raw, new_envs_raw, final_vid_raw)
      }
      let #(cur_voice, _) = get_or_create_voice(new_all, final_vid)

      // Dispatch to underlying engine (WASM/WebAudio)
      let _ = send_skode_command(trimmed)

      let next_pid = case maybe_new_pid {
        Some(pid) -> pid
        None -> model.active_pattern_id
      }
      let next_did = case maybe_new_did {
        Some(did) -> did
        None -> model.active_delay_id
      }

      Model(
        ..model,
        all_patterns: updated_patterns,
        active_pattern_id: next_pid,
        pattern_pointer: next_pid,
        active_delay_id: next_did,
        engine_settings: next_engine,
        variables: next_vars,
        stream_slots: next_stream_slots,
        all_voices: new_all,
        all_envelopes: new_envs,
        voice: cur_voice,
        last_dispatched: cur_voice,
      )
    }
  }
}

pub fn apply_skode_script_to_model(model: Model, script: String) -> Model {
  let lines = string.split(script, "\n")
  let commands = chunk_script_commands(lines, "", 0, [])
  let updated_model = list.fold(commands, model, apply_skode_command_to_model)
  let #(v0, _) = get_or_create_voice(updated_model.all_voices, 0)
  Model(..updated_model, voice: v0, last_dispatched: v0, pinned_pills: [
    #(0, PillWave),
    #(0, PillFreq),
    #(0, PillAmp),
  ])
}

// -----------------------------------------------------------------------------
// View Helpers & Layout Elements
// -----------------------------------------------------------------------------

fn normalize_numeric_string(str: String) -> String {
  let trimmed = string.trim(str)
  case trimmed {
    "." <> rest -> "0." <> rest
    "-." <> rest -> "-0." <> rest
    "+." <> rest -> "0." <> rest
    _ -> trimmed
  }
}

fn parse_float(val: String, default: Float) -> Float {
  let normalized = normalize_numeric_string(val)
  case float.parse(normalized) {
    Ok(f) -> f
    Error(_) ->
      case int.parse(normalized) {
        Ok(i) -> int.to_float(i)
        Error(_) -> default
      }
  }
}

fn parse_int(val: String, default: Int) -> Int {
  let normalized = normalize_numeric_string(val)
  case int.parse(normalized) {
    Ok(i) -> i
    Error(_) ->
      case float.parse(normalized) {
        Ok(f) -> float.round(f)
        Error(_) -> default
      }
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
          #("align-items", "center"),
          #("font-size", "13px"),
          #("margin-bottom", "4px"),
        ]),
      ],
      [
        span(
          [
            styles([
              #("color", "var(--text-muted, #8b949e)"),
              #("font-weight", "500"),
            ]),
          ],
          [
            text(label_text),
          ],
        ),
        div(
          [
            styles([
              #("display", "flex"),
              #("align-items", "center"),
              #("gap", "6px"),
            ]),
          ],
          [
            input([
              type_("number"),
              min(float.to_string(min_val)),
              max(float.to_string(max_val)),
              step(float.to_string(step_val)),
              value(float.to_string(current_val)),
              on_input(fn(s) { on_change(parse_float(s, current_val)) }),
              styles([
                #("width", "76px"),
                #("padding", "2px 6px"),
                #("font-family", "monospace"),
                #("font-size", "12px"),
                #("color", "#58a6ff"),
                #("background", "var(--bg-card-subtle, #21262d)"),
                #("border", "1px solid var(--border-subtle, #30363d)"),
                #("border-radius", "4px"),
                #("text-align", "right"),
              ]),
            ]),
            span(
              [
                styles([
                  #("font-family", "monospace"),
                  #("font-size", "11px"),
                  #("color", "var(--text-muted, #8b949e)"),
                  #("min-width", "18px"),
                ]),
              ],
              [text(unit_text)],
            ),
          ],
        ),
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
        #("cursor", "pointer"),
        #("accent-color", "#1f6feb"),
      ]),
    ]),
  ])
}

// -----------------------------------------------------------------------------
// Voice Cards & Non-Default Pills Rendering
// -----------------------------------------------------------------------------

fn render_primary_voice_card(
  voice: Voice,
  envs: VoiceEnvelopes,
  linked_partner_ids: List(Int),
  model: Model,
) -> Element(Msg) {
  let pills = get_voice_pills(voice, envs)

  div(
    [
      styles([
        #(
          "background",
          "linear-gradient(180deg, var(--bg-card, #161b22) 0%, var(--bg-app, #0d1117) 100%)",
        ),
        #("border", "2px solid #1f6feb"),
        #("border-radius", "8px"),
        #("padding", "18px"),
        #("display", "flex"),
        #("flex-direction", "column"),
        #("gap", "14px"),
        #("box-shadow", "0 0 16px rgba(31, 111, 235, 0.25)"),
      ]),
    ],
    [
      // Card Header
      div(
        [
          styles([
            #("display", "flex"),
            #("justify-content", "space-between"),
            #("align-items", "center"),
            #("flex-wrap", "wrap"),
            #("gap", "10px"),
          ]),
        ],
        [
          div(
            [
              styles([
                #("display", "flex"),
                #("align-items", "center"),
                #("gap", "10px"),
              ]),
            ],
            [
              span(
                [
                  styles([
                    #("font-family", "monospace"),
                    #("font-size", "18px"),
                    #("font-weight", "bold"),
                    #("color", "#58a6ff"),
                  ]),
                ],
                [text("v" <> int.to_string(voice.id))],
              ),
              span(
                [
                  styles([
                    #("background", "#1f6feb"),
                    #("color", "#ffffff"),
                    #("font-size", "11px"),
                    #("font-weight", "bold"),
                    #("padding", "3px 10px"),
                    #("border-radius", "10px"),
                    #("letter-spacing", "0.5px"),
                  ]),
                ],
                [text("★ PRIMARY FOCUSED SYNTH")],
              ),
              span(
                [
                  styles([
                    #("background", case voice.record > 0 {
                      True -> "#d2992222"
                      False -> "var(--bg-card-subtle, #21262d)"
                    }),
                    #("color", case voice.record > 0 {
                      True -> "#d29922"
                      False -> "var(--text-muted, #8b949e)"
                    }),
                    #("border", case voice.record > 0 {
                      True -> "1px solid #d2992266"
                      False -> "1px solid #30363d"
                    }),
                    #("font-size", "11px"),
                    #("font-weight", "bold"),
                    #("font-family", "monospace"),
                    #("padding", "2px 8px"),
                    #("border-radius", "6px"),
                  ]),
                ],
                [
                  text(case voice.record > 0 {
                    True ->
                      "● r"
                      <> int.to_string(voice.record)
                      <> " (Track "
                      <> int.to_string(voice.record)
                      <> ")"
                    False -> "● r0 (Main Master)"
                  }),
                ],
              ),
              case voice.glissando_enable != 0 || voice.glissando_time >. 0.0 {
                True ->
                  span(
                    [
                      styles([
                        #("background", "#d2992222"),
                        #("color", "#d29922"),
                        #("border", "1px solid #d2992266"),
                        #("font-size", "11px"),
                        #("font-weight", "bold"),
                        #("font-family", "monospace"),
                        #("padding", "2px 8px"),
                        #("border-radius", "6px"),
                      ]),
                    ],
                    [
                      text(
                        "⚡ Glide: "
                        <> param.format_float(voice.glissando_time)
                        <> "s",
                      ),
                    ],
                  )
                False -> element.none()
              },
              case voice.cz_mode != 0 || voice.cz_distortion != 0.0 {
                True ->
                  span(
                    [
                      styles([
                        #("background", "#bc8cff22"),
                        #("color", "#bc8cff"),
                        #("border", "1px solid #bc8cff66"),
                        #("font-size", "11px"),
                        #("font-weight", "bold"),
                        #("font-family", "monospace"),
                        #("padding", "2px 8px"),
                        #("border-radius", "6px"),
                      ]),
                    ],
                    [
                      text(
                        "📐 CZ: M"
                        <> int.to_string(voice.cz_mode)
                        <> " ("
                        <> param.format_float(voice.cz_distortion)
                        <> ")",
                      ),
                    ],
                  )
                False -> element.none()
              },
              span(
                [
                  styles([
                    #("font-size", "12px"),
                    #("color", "var(--text-muted, #8b949e)"),
                    #("font-family", "monospace"),
                  ]),
                ],
                [
                  text(
                    wave_name(voice.wave_table_index)
                    <> " • "
                    <> case voice.pitch_mode {
                      0 -> int.to_string(float.round(voice.freq)) <> " Hz"
                      _ ->
                        "MIDI " <> int.to_string(float.round(voice.midi_note))
                    }
                    <> " • "
                    <> param.format_float(voice.user_amp)
                    <> " dB",
                  ),
                ],
              ),
            ],
          ),
          div([styles([#("display", "flex"), #("gap", "8px")])], [
            button(
              [
                on_click(TriggerVoiceId(voice.id)),
                styles([
                  #("padding", "4px 12px"),
                  #("background", "#238636"),
                  #("color", "#ffffff"),
                  #("border", "none"),
                  #("border-radius", "4px"),
                  #("font-size", "12px"),
                  #("font-weight", "600"),
                  #("cursor", "pointer"),
                ]),
              ],
              [text("▶ Play v" <> int.to_string(voice.id))],
            ),
            case list.any(model.pinned_pills, fn(pair) { pair.0 == voice.id }) {
              True ->
                button(
                  [
                    on_click(CloseVoicePinnedPills(voice.id)),
                    styles([
                      #("padding", "4px 8px"),
                      #("background", "var(--bg-card-subtle, #21262d)"),
                      #("color", "#d29922"),
                      #("border", "1px solid #d2992266"),
                      #("border-radius", "4px"),
                      #("font-size", "11px"),
                      #("cursor", "pointer"),
                    ]),
                  ],
                  [text("✕ Close Pins (v" <> int.to_string(voice.id) <> ")")],
                )
              False -> element.none()
            },
            button(
              [
                on_click(ResetVoiceId(voice.id)),
                styles([
                  #("padding", "4px 10px"),
                  #("background", "var(--bg-card-subtle, #21262d)"),
                  #("color", "#f85149"),
                  #("border", "1px solid #30363d"),
                  #("border-radius", "4px"),
                  #("font-size", "12px"),
                  #("cursor", "pointer"),
                ]),
              ],
              [text("↺ Reset")],
            ),
          ]),
        ],
      ),
      // Connection Topology Route Strip (if linked)
      case linked_partner_ids {
        [] -> element.none()
        partners ->
          div(
            [
              styles([
                #("display", "flex"),
                #("align-items", "center"),
                #("gap", "8px"),
                #("padding", "6px 12px"),
                #("background", "var(--bg-app, #0d1117)"),
                #("border", "1px solid #30363d"),
                #("border-radius", "6px"),
                #("flex-wrap", "wrap"),
              ]),
            ],
            [
              span(
                [
                  styles([
                    #("color", "var(--text-muted, #8b949e)"),
                    #("font-size", "11px"),
                    #("font-weight", "600"),
                  ]),
                ],
                [
                  text(
                    "🔗 Connected Topology ("
                    <> int.to_string(list.length(partners))
                    <> " voices):",
                  ),
                ],
              ),
              ..list.map(partners, fn(pid) {
                let #(bg, fg, label) =
                  get_relationship_badge(pid, voice, model.all_voices)
                button(
                  [
                    on_click(SetVoiceId(pid)),
                    type_("button"),
                    styles([
                      #("display", "inline-flex"),
                      #("align-items", "center"),
                      #("gap", "4px"),
                      #("padding", "2px 8px"),
                      #("background", bg),
                      #("color", fg),
                      #("border", "1px solid " <> fg <> "66"),
                      #("border-radius", "10px"),
                      #("font-size", "11px"),
                      #("font-weight", "600"),
                      #("cursor", "pointer"),
                    ]),
                  ],
                  [text(label <> " ➔")],
                )
              })
            ],
          )
      },
      // Interactive Parameter Pills Deck
      div(
        [
          styles([
            #("display", "flex"),
            #("flex-wrap", "wrap"),
            #("gap", "6px"),
            #("align-items", "center"),
            #("min-height", "32px"),
          ]),
        ],
        case pills {
          [] -> [
            span(
              [
                styles([
                  #("font-size", "11px"),
                  #("color", "#484f58"),
                  #("font-style", "italic"),
                ]),
              ],
              [
                text(
                  "Default voice settings. Tap swatches in Palette below to customize.",
                ),
              ],
            ),
          ]
          _ ->
            list.map(pills, fn(p) {
              let is_pill_pinned =
                list.contains(model.pinned_pills, #(voice.id, p.id))
              span(
                [
                  on_click(ToggleVoicePill(voice.id, p.id)),
                  styles([
                    #("display", "inline-flex"),
                    #("align-items", "center"),
                    #("gap", "4px"),
                    #("padding", "3px 8px"),
                    #("border-radius", "12px"),
                    #("font-size", "11px"),
                    #("cursor", "pointer"),
                    #("background", p.bg_color),
                    #("color", p.fg_color),
                    #("border", case is_pill_pinned {
                      True -> "2px solid " <> p.fg_color
                      False -> "1px solid " <> p.fg_color <> "55"
                    }),
                    #("box-shadow", case is_pill_pinned {
                      True -> "0 0 8px " <> p.fg_color <> "77"
                      False -> "none"
                    }),
                    #("transition", "all 0.15s ease"),
                  ]),
                ],
                [
                  span([styles([#("font-weight", "600")])], [
                    text(
                      case is_pill_pinned {
                        True -> "📌 " <> p.label
                        False -> p.label
                      }
                      <> ":",
                    ),
                  ]),
                  span([], [text(p.value_summary)]),
                ],
              )
            })
        },
      ),
      // Card Footer summary
      div(
        [
          styles([
            #("display", "flex"),
            #("justify-content", "space-between"),
            #("align-items", "center"),
            #("border-top", "1px solid #21262d"),
            #("padding-top", "8px"),
          ]),
        ],
        [
          span(
            [
              styles([
                #("font-size", "11px"),
                #("color", "var(--text-muted, #8b949e)"),
              ]),
            ],
            [
              text(int.to_string(list.length(pills)) <> " active pills"),
            ],
          ),
          span([styles([#("font-size", "10px"), #("color", "#58a6ff")])], [
            text(
              "Click any pill to pin it side-by-side in Inspector below • Tap swatch in palette to tweak",
            ),
          ]),
        ],
      ),
    ],
  )
}

fn render_satellite_voice_card(
  voice: Voice,
  envs: VoiceEnvelopes,
  badge: #(String, String, String),
  model: Model,
) -> Element(Msg) {
  let pills = get_voice_pills(voice, envs)
  let #(bg_color, fg_color, role_label) = badge

  div(
    [
      styles([
        #("background", "var(--bg-card, #161b22)"),
        #("border", "1px solid " <> fg_color <> "77"),
        #("border-radius", "8px"),
        #("padding", "14px"),
        #("display", "flex"),
        #("flex-direction", "column"),
        #("gap", "10px"),
        #("box-shadow", "0 0 10px " <> fg_color <> "1a"),
      ]),
    ],
    [
      // Card Header
      div(
        [
          styles([
            #("display", "flex"),
            #("justify-content", "space-between"),
            #("align-items", "center"),
            #("flex-wrap", "wrap"),
            #("gap", "8px"),
          ]),
        ],
        [
          div(
            [
              styles([
                #("display", "flex"),
                #("align-items", "center"),
                #("gap", "8px"),
              ]),
            ],
            [
              span(
                [
                  styles([
                    #("font-family", "monospace"),
                    #("font-size", "15px"),
                    #("font-weight", "bold"),
                    #("color", "var(--text-primary, #f0f6fc)"),
                  ]),
                ],
                [text("v" <> int.to_string(voice.id))],
              ),
              span(
                [
                  styles([
                    #("background", bg_color),
                    #("color", fg_color),
                    #("font-size", "10px"),
                    #("font-weight", "600"),
                    #("padding", "2px 8px"),
                    #("border-radius", "10px"),
                    #("border", "1px solid " <> fg_color <> "55"),
                  ]),
                ],
                [text(role_label)],
              ),
            ],
          ),
          div([styles([#("display", "flex"), #("gap", "6px")])], [
            button(
              [
                on_click(SetVoiceId(voice.id)),
                styles([
                  #("padding", "3px 8px"),
                  #("background", "#1f6feb"),
                  #("color", "#ffffff"),
                  #("border", "none"),
                  #("border-radius", "4px"),
                  #("font-size", "11px"),
                  #("font-weight", "600"),
                  #("cursor", "pointer"),
                ]),
              ],
              [text("🎯 Switch Primary Focus to v" <> int.to_string(voice.id))],
            ),
            button(
              [
                on_click(TriggerVoiceId(voice.id)),
                styles([
                  #("padding", "3px 8px"),
                  #("background", "#238636"),
                  #("color", "#ffffff"),
                  #("border", "none"),
                  #("border-radius", "4px"),
                  #("font-size", "11px"),
                  #("font-weight", "600"),
                  #("cursor", "pointer"),
                ]),
              ],
              [text("▶")],
            ),
            button(
              [
                on_click(ResetVoiceId(voice.id)),
                styles([
                  #("padding", "3px 8px"),
                  #("background", "var(--bg-card-subtle, #21262d)"),
                  #("color", "#f85149"),
                  #("border", "1px solid #30363d"),
                  #("border-radius", "4px"),
                  #("font-size", "11px"),
                  #("cursor", "pointer"),
                ]),
              ],
              [text("↺")],
            ),
          ]),
        ],
      ),
      // Summary line
      div(
        [
          styles([
            #("font-size", "11px"),
            #("color", "var(--text-muted, #8b949e)"),
          ]),
        ],
        [
          text(
            wave_name(voice.wave_table_index)
            <> " • "
            <> case voice.pitch_mode {
              0 -> int.to_string(float.round(voice.freq)) <> " Hz"
              _ -> "MIDI " <> int.to_string(float.round(voice.midi_note))
            }
            <> " • "
            <> param.format_float(voice.user_amp)
            <> " dB",
          ),
        ],
      ),
      // Interactive Parameter Pills Deck
      div(
        [
          styles([
            #("display", "flex"),
            #("flex-wrap", "wrap"),
            #("gap", "4px"),
            #("align-items", "center"),
          ]),
        ],
        case pills {
          [] -> [
            span(
              [
                styles([
                  #("font-size", "10px"),
                  #("color", "#484f58"),
                  #("font-style", "italic"),
                ]),
              ],
              [text("Default voice parameters.")],
            ),
          ]
          _ ->
            list.map(pills, fn(p) {
              let is_pill_pinned =
                list.contains(model.pinned_pills, #(voice.id, p.id))
              span(
                [
                  on_click(ToggleVoicePill(voice.id, p.id)),
                  styles([
                    #("display", "inline-flex"),
                    #("align-items", "center"),
                    #("gap", "3px"),
                    #("padding", "2px 6px"),
                    #("border-radius", "10px"),
                    #("font-size", "10px"),
                    #("cursor", "pointer"),
                    #("background", p.bg_color),
                    #("color", p.fg_color),
                    #("border", case is_pill_pinned {
                      True -> "2px solid " <> p.fg_color
                      False -> "1px solid " <> p.fg_color <> "55"
                    }),
                  ]),
                ],
                [
                  span([styles([#("font-weight", "600")])], [
                    text(
                      case is_pill_pinned {
                        True -> "📌 " <> p.label
                        False -> p.label
                      }
                      <> ":",
                    ),
                  ]),
                  span([], [text(p.value_summary)]),
                ],
              )
            })
        },
      ),
      // Card Footer summary
      div(
        [
          styles([
            #("display", "flex"),
            #("justify-content", "space-between"),
            #("align-items", "center"),
            #("border-top", "1px solid #21262d"),
            #("padding-top", "6px"),
          ]),
        ],
        [
          span(
            [
              styles([
                #("font-size", "10px"),
                #("color", "var(--text-muted, #8b949e)"),
              ]),
            ],
            [
              text(
                int.to_string(list.length(pills))
                <> " pills • Linked with v"
                <> int.to_string(model.voice.id),
              ),
            ],
          ),
          span([styles([#("font-size", "10px"), #("color", fg_color)])], [
            text("Click pill to pin to inspector"),
          ]),
        ],
      ),
    ],
  )
}

// -----------------------------------------------------------------------------
// Focused Parameter Inspector Panel
// -----------------------------------------------------------------------------

fn render_parameter_inspector(
  model: Model,
  voice_id: Int,
  pill_id: PillId,
  card_index: Int,
  total_cards: Int,
) -> Element(Msg) {
  let #(voice, _) = get_or_create_voice(model.all_voices, voice_id)
  let envs = get_voice_envelopes(model, voice_id)

  let is_being_dragged = model.dragged_pill_index == Some(card_index)
  div(
    [
      prevent_default(event.on(
        "dragover",
        decode.success(DragOverPill(card_index)),
      )),
      event.on("drop", decode.success(DropPill(card_index))),
      styles([
        #("background", "var(--bg-card, #161b22)"),
        #("border", case is_being_dragged {
          True -> "2px dashed #58a6ff"
          False -> "1px solid #30363d"
        }),
        #("opacity", case is_being_dragged {
          True -> "0.5"
          False -> "1.0"
        }),
        #("border-radius", "8px"),
        #("padding", "18px"),
        #("margin-bottom", "20px"),
        #("transition", "border-color 0.15s ease, opacity 0.15s ease"),
      ]),
    ],
    [
      // Inspector Header
      div(
        [
          styles([
            #("display", "flex"),
            #("justify-content", "space-between"),
            #("align-items", "center"),
            #("margin-bottom", "14px"),
            #("border-bottom", "1px solid #21262d"),
            #("padding-bottom", "10px"),
          ]),
        ],
        [
          div(
            [
              styles([
                #("display", "flex"),
                #("align-items", "center"),
                #("gap", "8px"),
              ]),
            ],
            [
              span(
                [
                  attribute.attribute(
                    "title",
                    "Drag handle (⠿) to reorder card",
                  ),
                  attribute.attribute("draggable", "true"),
                  event.on(
                    "dragstart",
                    decode.success(StartDragPill(card_index)),
                  ),
                  styles([
                    #("cursor", "grab"),
                    #("font-size", "16px"),
                    #("user-select", "none"),
                    #("color", "var(--text-muted, #8b949e)"),
                    #("padding", "2px 6px"),
                    #("background", "rgba(255, 255, 255, 0.05)"),
                    #("border-radius", "4px"),
                    #("border", "1px solid rgba(255, 255, 255, 0.1)"),
                  ]),
                ],
                [text("⠿")],
              ),
              span(
                [
                  styles([
                    #("background", "#1f6feb22"),
                    #("color", "#58a6ff"),
                    #("padding", "2px 8px"),
                    #("border-radius", "4px"),
                    #("font-weight", "bold"),
                    #("font-size", "12px"),
                  ]),
                ],
                [text("v" <> int.to_string(voice_id))],
              ),
              span(
                [
                  styles([
                    #("font-weight", "600"),
                    #("font-size", "14px"),
                    #("color", "var(--text-primary, #f0f6fc)"),
                  ]),
                ],
                [text(get_pill_inspector_title(pill_id))],
              ),
            ],
          ),
          div(
            [
              styles([
                #("display", "flex"),
                #("gap", "6px"),
                #("align-items", "center"),
              ]),
            ],
            [
              button(
                [
                  on_click(ShiftPinnedPill(card_index, -1)),
                  attribute.attribute("disabled", case card_index == 0 {
                    True -> "true"
                    False -> "false"
                  }),
                  attribute.attribute("title", "Move card earlier / left"),
                  styles([
                    #("padding", "4px 8px"),
                    #("background", "var(--bg-card-subtle, #21262d)"),
                    #("color", case card_index == 0 {
                      True -> "var(--text-muted, #484f58)"
                      False -> "var(--text-primary, #c9d1d9)"
                    }),
                    #("border", "1px solid #30363d"),
                    #("border-radius", "6px"),
                    #("cursor", case card_index == 0 {
                      True -> "not-allowed"
                      False -> "pointer"
                    }),
                    #("font-size", "12px"),
                  ]),
                ],
                [text("◀")],
              ),
              button(
                [
                  on_click(ShiftPinnedPill(card_index, 1)),
                  attribute.attribute(
                    "disabled",
                    case card_index == total_cards - 1 {
                      True -> "true"
                      False -> "false"
                    },
                  ),
                  attribute.attribute("title", "Move card later / right"),
                  styles([
                    #("padding", "4px 8px"),
                    #("background", "var(--bg-card-subtle, #21262d)"),
                    #("color", case card_index == total_cards - 1 {
                      True -> "var(--text-muted, #484f58)"
                      False -> "var(--text-primary, #c9d1d9)"
                    }),
                    #("border", "1px solid #30363d"),
                    #("border-radius", "6px"),
                    #("cursor", case card_index == total_cards - 1 {
                      True -> "not-allowed"
                      False -> "pointer"
                    }),
                    #("font-size", "12px"),
                  ]),
                ],
                [text("▶")],
              ),
              button(
                [
                  on_click(ResetVoiceParam(voice_id, pill_id)),
                  styles([
                    #("padding", "4px 10px"),
                    #("background", "var(--bg-card-subtle, #21262d)"),
                    #("color", "#f85149"),
                    #("border", "1px solid #30363d"),
                    #("border-radius", "6px"),
                    #("font-size", "12px"),
                    #("cursor", "pointer"),
                  ]),
                ],
                [text("↺ Reset ×")],
              ),
              button(
                [
                  on_click(CloseSinglePill(voice_id, pill_id)),
                  styles([
                    #("padding", "4px 10px"),
                    #("background", "var(--bg-card-subtle, #21262d)"),
                    #("color", "var(--text-muted, #8b949e)"),
                    #("border", "1px solid #30363d"),
                    #("border-radius", "6px"),
                    #("font-size", "12px"),
                    #("cursor", "pointer"),
                  ]),
                ],
                [text("✕ Close")],
              ),
            ],
          ),
        ],
      ),
      // Inspector Body Controls
      render_pill_specific_controls(voice, envs, pill_id, model),
    ],
  )
}

fn render_pinned_inspectors(model: Model) -> Element(Msg) {
  case model.pinned_pills {
    [] -> element.none()
    pills ->
      div(
        [
          styles([
            #("background", "var(--bg-card, #161b22)"),
            #("border", "1px solid #30363d"),
            #("border-radius", "8px"),
            #("padding", "16px"),
            #("margin-bottom", "20px"),
          ]),
        ],
        [
          div(
            [
              styles([
                #("display", "flex"),
                #("justify-content", "space-between"),
                #("align-items", "center"),
                #("margin-bottom", "14px"),
                #("padding-bottom", "8px"),
                #("border-bottom", "1px solid #21262d"),
              ]),
            ],
            [
              div(
                [
                  styles([
                    #("display", "flex"),
                    #("align-items", "center"),
                    #("gap", "8px"),
                  ]),
                ],
                [
                  span(
                    [
                      styles([
                        #("font-weight", "600"),
                        #("font-size", "14px"),
                        #("color", "var(--text-primary, #f0f6fc)"),
                      ]),
                    ],
                    [
                      text(
                        "📌 Pinned Parameter Inspectors ("
                        <> int.to_string(list.length(pills))
                        <> ")",
                      ),
                    ],
                  ),
                  span(
                    [
                      styles([
                        #("font-size", "12px"),
                        #("color", "var(--text-muted, #8b949e)"),
                      ]),
                    ],
                    [text("Slide related parameters side-by-side")],
                  ),
                ],
              ),
              div([styles([#("display", "flex"), #("gap", "8px")])], [
                button(
                  [
                    on_click(CloseVoicePinnedPills(model.voice.id)),
                    styles([
                      #("padding", "4px 10px"),
                      #("background", "var(--bg-card-subtle, #21262d)"),
                      #("color", "#58a6ff"),
                      #("border", "1px solid #58a6ff66"),
                      #("border-radius", "6px"),
                      #("font-size", "12px"),
                      #("cursor", "pointer"),
                    ]),
                  ],
                  [
                    text(
                      "✕ Close Voice v"
                      <> int.to_string(model.voice.id)
                      <> " Pins",
                    ),
                  ],
                ),
                button(
                  [
                    on_click(ClearAllPinnedPills),
                    styles([
                      #("padding", "4px 10px"),
                      #("background", "var(--bg-card-subtle, #21262d)"),
                      #("color", "var(--text-muted, #8b949e)"),
                      #("border", "1px solid #30363d"),
                      #("border-radius", "6px"),
                      #("font-size", "12px"),
                      #("cursor", "pointer"),
                    ]),
                  ],
                  [text("✕ Close All Pinned")],
                ),
              ]),
            ],
          ),
          div(
            [
              styles([
                #("display", "grid"),
                #(
                  "grid-template-columns",
                  "repeat(auto-fit, minmax(360px, 1fr))",
                ),
                #("gap", "16px"),
              ]),
            ],
            list.index_map(pills, fn(pair, idx) {
              let #(vid, pid) = pair
              render_parameter_inspector(
                model,
                vid,
                pid,
                idx,
                list.length(pills),
              )
            }),
          ),
        ],
      )
  }
}

fn get_pill_inspector_title(pill_id: PillId) -> String {
  case pill_id {
    PillWave -> "Waveform & Timbre (w)"
    PillFreq -> "Frequency (f)"
    PillNote -> "MIDI Pitch (n)"
    PillPitchMode -> "Pitch Mode"
    PillAmp -> "Voice Amplitude Level (a)"
    PillPan -> "Stereo Panning (p)"
    PillFilterMode -> "Filter Type & Routing (j)"
    PillFilterFreq -> "Filter Cutoff Frequency (k)"
    PillFilterRes -> "Filter Resonance / Q (q)"
    PillFilterEnvDepth -> "Filter Envelope Depth (kd)"
    PillAmpEnv -> "Amplitude ADSR Envelope (t)"
    PillFilterEnv -> "Filter ADSR Envelope (kt)"
    PillLinkSync -> "⚡ Oscillator Hard Sync (HS)"
    PillLinkFreqMod -> "🌊 Frequency Modulation (FM)"
    PillLinkAmpMod -> "📶 Amplitude Modulation (AM)"
    PillLinkRingMod -> "🔔 Ring Modulation (XM)"
    PillLinkCzMod -> "📐 CZ Phase Modulation (cmod)"
    PillLinkPanMod -> "↔ Pan Modulation (pm)"
    PillLinkMidi -> "🎹 MIDI Gate Follower (G)"
    PillLinkVelo -> "💥 Velocity Follower (H)"
    PillGlissando -> "Glissando / Portamento (gl, gt)"
    PillSmoother -> "Parameter Smoother (sm)"
    PillCzDistortion -> "Phase Distortion (czd)"
    PillRingAmount -> "Ring Mod Amount (xm)"
    PillSampleHold -> "Sample & Hold Decimator (sh)"
    PillQuantize -> "Frequency Quantizer (qnt)"
    PillDelaySend -> "Master Delay Send (del)"
    PillFreqBend -> "Pitch Bend Wheel Range (bp)"
    PillAmpBend -> "Amplitude Bend Wheel Range (abp)"
    PillRecordTrack -> "Record Stem Track Output (r) / Audio Bus"
  }
}

fn mode_chip(
  voice_id: Int,
  mode_val: Int,
  chip_label: String,
  is_selected: Bool,
) -> Element(Msg) {
  button(
    [
      on_click(UpdateVoiceFilterMode(voice_id, mode_val)),
      styles([
        #("padding", "6px 12px"),
        #("border-radius", "6px"),
        #("font-size", "12px"),
        #("font-weight", case is_selected {
          True -> "bold"
          False -> "normal"
        }),
        #("cursor", "pointer"),
        #("background", case is_selected {
          True -> "#1f6feb"
          False -> "var(--bg-card-subtle, #21262d)"
        }),
        #("color", case is_selected {
          True -> "#ffffff"
          False -> "var(--text-secondary, #c9d1d9)"
        }),
        #("border", case is_selected {
          True -> "1px solid #58a6ff"
          False -> "1px solid #30363d"
        }),
        #("box-shadow", case is_selected {
          True -> "0 0 6px #1f6feb88"
          False -> "none"
        }),
        #("transition", "all 0.15s ease"),
      ]),
    ],
    [text(chip_label)],
  )
}

fn render_pill_specific_controls(
  voice: Voice,
  envs: VoiceEnvelopes,
  pill_id: PillId,
  model: Model,
) -> Element(Msg) {
  case pill_id {
    PillWave -> {
      let all_waves = get_all_wavetables()
      let voice_query = case dict.get(model.voice_wave_search, voice.id) {
        Ok(q) -> q
        Error(_) -> ""
      }
      let search_term = string.trim(string.lowercase(voice_query))
      let matching_waves = case search_term {
        "" -> all_waves
        q ->
          list.filter(all_waves, fn(w) {
            string.contains(string.lowercase(w.name), q)
            || string.contains(string.lowercase(w.category), q)
            || string.contains(int.to_string(w.index), q)
          })
      }

      div([], [
        // Native DW8000 / Float32 PCM Waveform Buffer Canvas
        div(
          [
            styles([
              #("display", "flex"),
              #("flex-direction", "column"),
              #("align-items", "center"),
              #("margin-bottom", "14px"),
              #("background", "var(--bg-app, #0d1117)"),
              #("padding", "12px"),
              #("border-radius", "6px"),
              #("border", "1px solid var(--border, #30363d)"),
            ]),
          ],
          [
            div(
              [
                styles([
                  #("display", "flex"),
                  #("justify-content", "space-between"),
                  #("align-items", "center"),
                  #("width", "100%"),
                  #("margin-bottom", "8px"),
                  #("font-size", "11px"),
                  #("font-family", "monospace"),
                ]),
              ],
              [
                span(
                  [styles([#("color", "#58a6ff"), #("font-weight", "600")])],
                  [
                    text(
                      "Waveform Buffer Canvas (w"
                      <> int.to_string(voice.wave_table_index)
                      <> ": "
                      <> wave_name(voice.wave_table_index)
                      <> ")",
                    ),
                  ],
                ),
                button(
                  [
                    on_click(InspectVoiceWaveformBuffer(
                      voice.id,
                      voice.wave_table_index,
                    )),
                    type_("button"),
                    styles([
                      #("padding", "2px 8px"),
                      #("background", "var(--bg-card-subtle, #21262d)"),
                      #("color", "#58a6ff"),
                      #("border", "1px solid #30363d"),
                      #("border-radius", "4px"),
                      #("cursor", "pointer"),
                      #("font-size", "11px"),
                    ]),
                  ],
                  [text("↺ Refresh Trace")],
                ),
              ],
            ),
            element.element(
              "canvas",
              [
                attribute.id("voice-wave-" <> int.to_string(voice.id)),
                attribute.attribute("width", "400"),
                attribute.attribute("height", "90"),
                styles([
                  #("width", "100%"),
                  #("max-width", "400px"),
                  #("height", "90px"),
                  #("background", "var(--bg-card, #161b22)"),
                  #("border-radius", "4px"),
                  #("border", "1px solid var(--border-muted, #21262d)"),
                ]),
              ],
              [],
            ),
          ],
        ),
        // 1. Direct Stepper Bar
        div(
          [
            styles([
              #("display", "flex"),
              #("gap", "8px"),
              #("align-items", "center"),
              #("margin-bottom", "14px"),
              #("background", "var(--bg-card, #161b22)"),
              #("padding", "10px"),
              #("border-radius", "6px"),
              #("border", "1px solid #30363d"),
            ]),
          ],
          [
            button(
              [
                on_click(StepVoiceWave(voice.id, -1)),
                styles([
                  #("padding", "6px 12px"),
                  #("background", "var(--bg-card-subtle, #21262d)"),
                  #("color", "var(--text-primary, #f0f6fc)"),
                  #("border", "1px solid #30363d"),
                  #("border-radius", "6px"),
                  #("cursor", "pointer"),
                  #("font-weight", "600"),
                ]),
              ],
              [text("◀ Prev Wave")],
            ),
            div(
              [
                styles([
                  #("flex", "1"),
                  #("text-align", "center"),
                  #("font-family", "monospace"),
                  #("font-size", "14px"),
                  #("color", "#58a6ff"),
                  #("font-weight", "700"),
                ]),
              ],
              [
                text(
                  "w"
                  <> int.to_string(voice.wave_table_index)
                  <> ": "
                  <> wave_name(voice.wave_table_index),
                ),
              ],
            ),
            button(
              [
                on_click(StepVoiceWave(voice.id, 1)),
                styles([
                  #("padding", "6px 12px"),
                  #("background", "var(--bg-card-subtle, #21262d)"),
                  #("color", "var(--text-primary, #f0f6fc)"),
                  #("border", "1px solid #30363d"),
                  #("border-radius", "6px"),
                  #("cursor", "pointer"),
                  #("font-weight", "600"),
                ]),
              ],
              [text("Next Wave ▶")],
            ),
          ],
        ),
        // 2. Search & Category Filter
        div(
          [
            styles([
              #("display", "flex"),
              #("gap", "6px"),
              #("margin-bottom", "10px"),
              #("flex-wrap", "wrap"),
              #("align-items", "center"),
            ]),
          ],
          [
            input([
              type_("text"),
              placeholder(
                "Filter 70+ waveforms (e.g. bell, bass, 808, brass, piano)...",
              ),
              value(voice_query),
              on_input(fn(q) { SetVoiceWaveSearch(voice.id, q) }),
              styles([
                #("flex", "1"),
                #("min-width", "180px"),
                #("padding", "6px 10px"),
                #("background", "var(--bg-app, #0d1117)"),
                #("color", "var(--text-primary, #f0f6fc)"),
                #("border", "1px solid #30363d"),
                #("border-radius", "6px"),
                #("font-size", "12px"),
              ]),
            ]),
            button(
              [
                type_("button"),
                on_click(SetVoiceWaveSearch(voice.id, "")),
                styles([
                  #("padding", "4px 8px"),
                  #("background", case voice_query == "" {
                    True -> "#1f6feb"
                    False -> "var(--bg-card-subtle, #21262d)"
                  }),
                  #("color", case voice_query == "" {
                    True -> "#ffffff"
                    False -> "var(--text-muted, #8b949e)"
                  }),
                  #("border", "1px solid #30363d"),
                  #("border-radius", "4px"),
                  #("cursor", "pointer"),
                  #("font-size", "11px"),
                  #("font-weight", case voice_query == "" {
                    True -> "bold"
                    False -> "normal"
                  }),
                ]),
              ],
              [text("All (70+)")],
            ),
            button(
              [
                type_("button"),
                on_click(SetVoiceWaveSearch(voice.id, "Classic")),
                styles([
                  #("padding", "4px 8px"),
                  #("background", case voice_query == "Classic" {
                    True -> "#1f6feb"
                    False -> "var(--bg-card-subtle, #21262d)"
                  }),
                  #("color", case voice_query == "Classic" {
                    True -> "#ffffff"
                    False -> "var(--text-muted, #8b949e)"
                  }),
                  #("border", "1px solid #30363d"),
                  #("border-radius", "4px"),
                  #("cursor", "pointer"),
                  #("font-size", "11px"),
                  #("font-weight", case voice_query == "Classic" {
                    True -> "bold"
                    False -> "normal"
                  }),
                ]),
              ],
              [text("Classic")],
            ),
            button(
              [
                type_("button"),
                on_click(SetVoiceWaveSearch(voice.id, "DW-8000")),
                styles([
                  #("padding", "4px 8px"),
                  #("background", case voice_query == "DW-8000" {
                    True -> "#1f6feb"
                    False -> "var(--bg-card-subtle, #21262d)"
                  }),
                  #("color", case voice_query == "DW-8000" {
                    True -> "#ffffff"
                    False -> "var(--text-muted, #8b949e)"
                  }),
                  #("border", "1px solid #30363d"),
                  #("border-radius", "4px"),
                  #("cursor", "pointer"),
                  #("font-size", "11px"),
                  #("font-weight", case voice_query == "DW-8000" {
                    True -> "bold"
                    False -> "normal"
                  }),
                ]),
              ],
              [text("DW-8000")],
            ),
            button(
              [
                type_("button"),
                on_click(SetVoiceWaveSearch(voice.id, "ESQ-1")),
                styles([
                  #("padding", "4px 8px"),
                  #("background", case voice_query == "ESQ-1" {
                    True -> "#1f6feb"
                    False -> "var(--bg-card-subtle, #21262d)"
                  }),
                  #("color", case voice_query == "ESQ-1" {
                    True -> "#ffffff"
                    False -> "var(--text-muted, #8b949e)"
                  }),
                  #("border", "1px solid #30363d"),
                  #("border-radius", "4px"),
                  #("cursor", "pointer"),
                  #("font-size", "11px"),
                  #("font-weight", case voice_query == "ESQ-1" {
                    True -> "bold"
                    False -> "normal"
                  }),
                ]),
              ],
              [text("ESQ-1")],
            ),
            button(
              [
                type_("button"),
                on_click(SetVoiceWaveSearch(voice.id, "808")),
                styles([
                  #("padding", "4px 8px"),
                  #(
                    "background",
                    case voice_query == "808" || voice_query == "Drums" {
                      True -> "#1f6feb"
                      False -> "var(--bg-card-subtle, #21262d)"
                    },
                  ),
                  #(
                    "color",
                    case voice_query == "808" || voice_query == "Drums" {
                      True -> "#ffffff"
                      False -> "var(--text-muted, #8b949e)"
                    },
                  ),
                  #("border", "1px solid #30363d"),
                  #("border-radius", "4px"),
                  #("cursor", "pointer"),
                  #("font-size", "11px"),
                  #(
                    "font-weight",
                    case voice_query == "808" || voice_query == "Drums" {
                      True -> "bold"
                      False -> "normal"
                    },
                  ),
                ]),
              ],
              [text("808 Drums")],
            ),
            button(
              [
                type_("button"),
                on_click(SetVoiceWaveSearch(voice.id, "Live")),
                styles([
                  #("padding", "4px 8px"),
                  #("background", case voice_query == "Live" {
                    True -> "#1f6feb"
                    False -> "var(--bg-card-subtle, #21262d)"
                  }),
                  #("color", case voice_query == "Live" {
                    True -> "#ffffff"
                    False -> "var(--text-muted, #8b949e)"
                  }),
                  #("border", "1px solid #30363d"),
                  #("border-radius", "4px"),
                  #("cursor", "pointer"),
                  #("font-size", "11px"),
                  #("font-weight", case voice_query == "Live" {
                    True -> "bold"
                    False -> "normal"
                  }),
                ]),
              ],
              [text("Live In")],
            ),
          ],
        ),
        // 3. Scrollable Visual Waveform Quick-Picker Grid
        div(
          [
            styles([
              #("display", "grid"),
              #(
                "grid-template-columns",
                "repeat(auto-fill, minmax(130px, 1fr))",
              ),
              #("gap", "6px"),
              #("max-height", "160px"),
              #("overflow-y", "auto"),
              #("padding", "8px"),
              #("background", "var(--bg-app, #0d1117)"),
              #("border", "1px solid #30363d"),
              #("border-radius", "6px"),
              #("margin-bottom", "14px"),
            ]),
          ],
          list.map(matching_waves, fn(w) {
            let is_selected = voice.wave_table_index == w.index
            button(
              [
                on_click(UpdateVoiceWave(voice.id, w.index)),
                styles([
                  #("padding", "5px 8px"),
                  #("font-size", "11px"),
                  #("border-radius", "4px"),
                  #("cursor", "pointer"),
                  #("text-align", "left"),
                  #("white-space", "nowrap"),
                  #("overflow", "hidden"),
                  #("text-overflow", "ellipsis"),
                  #("background", case is_selected {
                    True -> "#1f6feb33"
                    False -> "var(--bg-card-subtle, #21262d)"
                  }),
                  #("color", case is_selected {
                    True -> "#58a6ff"
                    False -> "var(--text-secondary, #c9d1d9)"
                  }),
                  #("border", case is_selected {
                    True -> "1px solid #58a6ff"
                    False -> "1px solid #30363d"
                  }),
                  #("font-weight", case is_selected {
                    True -> "700"
                    False -> "400"
                  }),
                ]),
              ],
              [text(int.to_string(w.index) <> ": " <> w.name)],
            )
          }),
        ),
        // 4. Grouped Native Select Dropdown
        label(
          [
            styles([
              #("font-size", "12px"),
              #("color", "var(--text-muted, #8b949e)"),
              #("display", "block"),
              #("margin-bottom", "4px"),
            ]),
          ],
          [text("Or choose from categorized dropdown:")],
        ),
        select(
          [
            value(int.to_string(voice.wave_table_index)),
            on_change(fn(s) {
              UpdateVoiceWave(voice.id, parse_int(s, voice.wave_table_index))
            }),
            on_input(fn(s) {
              UpdateVoiceWave(voice.id, parse_int(s, voice.wave_table_index))
            }),
            styles([
              #("width", "100%"),
              #("padding", "8px 12px"),
              #("background", "var(--bg-card-subtle, #21262d)"),
              #("color", "var(--text-primary, #f0f6fc)"),
              #("border", "1px solid #30363d"),
              #("border-radius", "6px"),
            ]),
          ],
          [
            optgroup(
              [attribute.attribute("label", "🌟 Classic Analog & Noise (0-6)")],
              list.map(
                list.filter(all_waves, fn(w) { w.category == "Classic" }),
                fn(w) {
                  option(
                    [
                      value(int.to_string(w.index)),
                      attribute.selected(voice.wave_table_index == w.index),
                    ],
                    int.to_string(w.index) <> ": " <> w.name,
                  )
                },
              ),
            ),
            optgroup(
              [
                attribute.attribute(
                  "label",
                  "🎻 Korg DW-8000 Digital Acoustic (15-30)",
                ),
              ],
              list.map(
                list.filter(all_waves, fn(w) { w.category == "DW-8000" }),
                fn(w) {
                  option(
                    [
                      value(int.to_string(w.index)),
                      attribute.selected(voice.wave_table_index == w.index),
                    ],
                    int.to_string(w.index) <> ": " <> w.name,
                  )
                },
              ),
            ),
            optgroup(
              [
                attribute.attribute(
                  "label",
                  "🎹 Ensoniq ESQ-1 Vintage Digital (50-81)",
                ),
              ],
              list.map(
                list.filter(all_waves, fn(w) { w.category == "ESQ-1" }),
                fn(w) {
                  option(
                    [
                      value(int.to_string(w.index)),
                      attribute.selected(voice.wave_table_index == w.index),
                    ],
                    int.to_string(w.index) <> ": " <> w.name,
                  )
                },
              ),
            ),
            optgroup(
              [
                attribute.attribute(
                  "label",
                  "🥁 Roland TR-808 Single-Cycle Drums (82-99)",
                ),
              ],
              list.map(
                list.filter(all_waves, fn(w) { w.category == "808 Drums" }),
                fn(w) {
                  option(
                    [
                      value(int.to_string(w.index)),
                      attribute.selected(voice.wave_table_index == w.index),
                    ],
                    int.to_string(w.index) <> ": " <> w.name,
                  )
                },
              ),
            ),
            optgroup(
              [attribute.attribute("label", "🎙 Live Audio Line-In (7-14)")],
              list.map(
                list.filter(all_waves, fn(w) { w.category == "Live In" }),
                fn(w) {
                  option(
                    [
                      value(int.to_string(w.index)),
                      attribute.selected(voice.wave_table_index == w.index),
                    ],
                    int.to_string(w.index) <> ": " <> w.name,
                  )
                },
              ),
            ),
          ],
        ),
      ])
    }

    PillFreq ->
      div([], [
        slider_row("Frequency (f)", voice.freq, 20.0, 4000.0, 0.05, "Hz", fn(f) {
          UpdateVoiceFreq(voice.id, f)
        }),
        div(
          [
            styles([
              #("display", "flex"),
              #("gap", "4px"),
              #("flex-wrap", "wrap"),
              #("margin-top", "6px"),
            ]),
          ],
          [
            button(
              [
                on_click(UpdateVoiceFreq(
                  voice.id,
                  param_gen.clamp_freq(voice.freq /. 2.0),
                )),
                styles([
                  #("background", "var(--bg-card-subtle, #21262d)"),
                  #("color", "var(--text-primary, #f0f6fc)"),
                  #("border", "1px solid var(--border-subtle, #30363d)"),
                  #("border-radius", "4px"),
                  #("padding", "2px 8px"),
                  #("font-size", "11px"),
                  #("cursor", "pointer"),
                ]),
              ],
              [text("÷2")],
            ),
            button(
              [
                on_click(UpdateVoiceFreq(
                  voice.id,
                  param_gen.clamp_freq(voice.freq /. 1.0594630943592953),
                )),
                styles([
                  #("background", "var(--bg-card-subtle, #21262d)"),
                  #("color", "var(--text-primary, #f0f6fc)"),
                  #("border", "1px solid var(--border-subtle, #30363d)"),
                  #("border-radius", "4px"),
                  #("padding", "2px 8px"),
                  #("font-size", "11px"),
                  #("cursor", "pointer"),
                ]),
              ],
              [text("-1 st")],
            ),
            button(
              [
                on_click(UpdateVoiceFreq(voice.id, 110.0)),
                styles([
                  #("background", "var(--bg-card-subtle, #21262d)"),
                  #("color", "var(--text-primary, #f0f6fc)"),
                  #("border", "1px solid var(--border-subtle, #30363d)"),
                  #("border-radius", "4px"),
                  #("padding", "2px 8px"),
                  #("font-size", "11px"),
                  #("cursor", "pointer"),
                ]),
              ],
              [text("110 Hz")],
            ),
            button(
              [
                on_click(UpdateVoiceFreq(voice.id, 220.0)),
                styles([
                  #("background", "var(--bg-card-subtle, #21262d)"),
                  #("color", "var(--text-primary, #f0f6fc)"),
                  #("border", "1px solid var(--border-subtle, #30363d)"),
                  #("border-radius", "4px"),
                  #("padding", "2px 8px"),
                  #("font-size", "11px"),
                  #("cursor", "pointer"),
                ]),
              ],
              [text("220 Hz")],
            ),
            button(
              [
                on_click(UpdateVoiceFreq(voice.id, 440.0)),
                styles([
                  #("background", "var(--bg-card-subtle, #21262d)"),
                  #("color", "var(--text-primary, #f0f6fc)"),
                  #("border", "1px solid var(--border-subtle, #30363d)"),
                  #("border-radius", "4px"),
                  #("padding", "2px 8px"),
                  #("font-size", "11px"),
                  #("cursor", "pointer"),
                ]),
              ],
              [text("440 Hz")],
            ),
            button(
              [
                on_click(UpdateVoiceFreq(voice.id, 880.0)),
                styles([
                  #("background", "var(--bg-card-subtle, #21262d)"),
                  #("color", "var(--text-primary, #f0f6fc)"),
                  #("border", "1px solid var(--border-subtle, #30363d)"),
                  #("border-radius", "4px"),
                  #("padding", "2px 8px"),
                  #("font-size", "11px"),
                  #("cursor", "pointer"),
                ]),
              ],
              [text("880 Hz")],
            ),
            button(
              [
                on_click(UpdateVoiceFreq(
                  voice.id,
                  param_gen.clamp_freq(voice.freq *. 1.0594630943592953),
                )),
                styles([
                  #("background", "var(--bg-card-subtle, #21262d)"),
                  #("color", "var(--text-primary, #f0f6fc)"),
                  #("border", "1px solid var(--border-subtle, #30363d)"),
                  #("border-radius", "4px"),
                  #("padding", "2px 8px"),
                  #("font-size", "11px"),
                  #("cursor", "pointer"),
                ]),
              ],
              [text("+1 st")],
            ),
            button(
              [
                on_click(UpdateVoiceFreq(
                  voice.id,
                  param_gen.clamp_freq(voice.freq *. 2.0),
                )),
                styles([
                  #("background", "var(--bg-card-subtle, #21262d)"),
                  #("color", "var(--text-primary, #f0f6fc)"),
                  #("border", "1px solid var(--border-subtle, #30363d)"),
                  #("border-radius", "4px"),
                  #("padding", "2px 8px"),
                  #("font-size", "11px"),
                  #("cursor", "pointer"),
                ]),
              ],
              [text("×2")],
            ),
          ],
        ),
      ])

    PillNote ->
      slider_row("MIDI Note (n)", voice.midi_note, 0.0, 127.0, 1.0, "st", fn(n) {
        UpdateVoiceNote(voice.id, n)
      })

    PillPitchMode ->
      div([], [
        select(
          [
            on_input(fn(s) { UpdateVoicePitchMode(voice.id, parse_int(s, 1)) }),
            styles([
              #("width", "100%"),
              #("padding", "8px"),
              #("background", "var(--bg-card-subtle, #21262d)"),
              #("color", "var(--text-primary, #f0f6fc)"),
            ]),
          ],
          [
            option(
              [value("0"), attribute.selected(voice.pitch_mode == 0)],
              "0: Frequency Mode (Hz)",
            ),
            option(
              [value("1"), attribute.selected(voice.pitch_mode == 1)],
              "1: MIDI Note Mode (Equal Temp)",
            ),
          ],
        ),
      ])

    PillAmp ->
      slider_row(
        "User Amplitude (a)",
        voice.user_amp,
        -48.0,
        12.0,
        0.5,
        "dB",
        fn(a) { UpdateVoiceAmp(voice.id, a) },
      )

    PillPan ->
      slider_row("Stereo Pan (p)", voice.pan, -1.0, 1.0, 0.05, "", fn(p) {
        UpdateVoicePan(voice.id, p)
      })

    PillFilterMode ->
      div(
        [
          styles([
            #("display", "flex"),
            #("flex-direction", "column"),
            #("gap", "12px"),
          ]),
        ],
        [
          // 1-Click Filter Mode Chips
          div(
            [
              styles([
                #("display", "flex"),
                #("gap", "8px"),
                #("flex-wrap", "wrap"),
              ]),
            ],
            [
              mode_chip(voice.id, 0, "0: Bypass (Off)", voice.filter_mode == 0),
              mode_chip(
                voice.id,
                1,
                "1: Low-Pass (12dB)",
                voice.filter_mode == 1,
              ),
              mode_chip(
                voice.id,
                2,
                "2: High-Pass (12dB)",
                voice.filter_mode == 2,
              ),
              mode_chip(
                voice.id,
                3,
                "3: Band-Pass (12dB)",
                voice.filter_mode == 3,
              ),
            ],
          ),
          // Dropdown selector with both on_change and on_input
          select(
            [
              on_change(fn(s) {
                UpdateVoiceFilterMode(voice.id, parse_int(s, 1))
              }),
              on_input(fn(s) {
                UpdateVoiceFilterMode(voice.id, parse_int(s, 1))
              }),
              styles([
                #("width", "100%"),
                #("padding", "8px"),
                #("background", "var(--bg-card-subtle, #21262d)"),
                #("color", "var(--text-primary, #f0f6fc)"),
                #("border", "1px solid #30363d"),
                #("border-radius", "6px"),
              ]),
            ],
            [
              option(
                [value("0"), attribute.selected(voice.filter_mode == 0)],
                "0: Filter Off (Bypass)",
              ),
              option(
                [value("1"), attribute.selected(voice.filter_mode == 1)],
                "1: Low-Pass (Standard 12dB)",
              ),
              option(
                [value("2"), attribute.selected(voice.filter_mode == 2)],
                "2: High-Pass (12dB)",
              ),
              option(
                [value("3"), attribute.selected(voice.filter_mode == 3)],
                "3: Band-Pass (12dB)",
              ),
            ],
          ),
          // Integrated Cutoff, Resonance, and Env Depth sliders
          slider_row(
            "Filter Cutoff (k)",
            voice.filter_freq,
            20.0,
            20_000.0,
            0.1,
            "Hz",
            fn(k) { UpdateVoiceFilterFreq(voice.id, k) },
          ),
          slider_row(
            "Filter Resonance / Q (q)",
            voice.filter_res,
            0.1,
            20.0,
            0.01,
            "",
            fn(q) { UpdateVoiceFilterRes(voice.id, q) },
          ),
          slider_row(
            "Filter Env Depth (kd)",
            voice.filter_env_depth,
            -10_000.0,
            10_000.0,
            10.0,
            "Hz",
            fn(d) { UpdateVoiceFilterEnvDepth(voice.id, d) },
          ),
        ],
      )

    PillFilterFreq ->
      slider_row(
        "Filter Cutoff (k)",
        voice.filter_freq,
        20.0,
        20_000.0,
        0.1,
        "Hz",
        fn(k) { UpdateVoiceFilterFreq(voice.id, k) },
      )

    PillFilterRes ->
      slider_row(
        "Filter Resonance / Q (q)",
        voice.filter_res,
        0.1,
        20.0,
        0.01,
        "",
        fn(q) { UpdateVoiceFilterRes(voice.id, q) },
      )

    PillFilterEnvDepth ->
      slider_row(
        "Filter Env Depth (kd)",
        voice.filter_env_depth,
        -10.0,
        10.0,
        0.1,
        "octaves",
        fn(kd) { UpdateVoiceFilterEnvDepth(voice.id, kd) },
      )

    PillAmpEnv ->
      div([], [
        slider_row(
          "Attack (t.a)",
          envs.amp_env.attack,
          0.001,
          5.0,
          0.005,
          "s",
          fn(a) { UpdateVoiceAmpAttack(voice.id, a) },
        ),
        slider_row(
          "Decay (t.d)",
          envs.amp_env.decay,
          0.001,
          5.0,
          0.005,
          "s",
          fn(d) { UpdateVoiceAmpDecay(voice.id, d) },
        ),
        slider_row(
          "Sustain (t.s)",
          envs.amp_env.sustain,
          0.0,
          1.0,
          0.01,
          "",
          fn(s) { UpdateVoiceAmpSustain(voice.id, s) },
        ),
        slider_row(
          "Release (t.r)",
          envs.amp_env.release,
          0.0,
          8.0,
          0.01,
          "s",
          fn(r) { UpdateVoiceAmpRelease(voice.id, r) },
        ),
      ])

    PillFilterEnv ->
      div([], [
        slider_row(
          "Filter Attack (kt.a)",
          envs.filter_env.attack,
          0.001,
          5.0,
          0.005,
          "s",
          fn(a) { UpdateVoiceFilterAttack(voice.id, a) },
        ),
        slider_row(
          "Filter Decay (kt.d)",
          envs.filter_env.decay,
          0.001,
          5.0,
          0.005,
          "s",
          fn(d) { UpdateVoiceFilterDecay(voice.id, d) },
        ),
        slider_row(
          "Filter Sustain (kt.s)",
          envs.filter_env.sustain,
          0.0,
          1.0,
          0.01,
          "",
          fn(s) { UpdateVoiceFilterSustain(voice.id, s) },
        ),
        slider_row(
          "Filter Release (kt.r)",
          envs.filter_env.release,
          0.0,
          8.0,
          0.01,
          "s",
          fn(r) { UpdateVoiceFilterRelease(voice.id, r) },
        ),
      ])

    PillLinkSync -> {
      let current_sync = case voice.link_sync {
        [t, ..] -> float.round(t)
        _ -> -1
      }
      sparse_voice_link_selector(
        "Hard Sync Target Voice (0..255)",
        current_sync,
        voice.id,
        "#d29922",
        model.all_voices,
        fn(tgt) { UpdateVoiceLinkSync(voice.id, tgt) },
      )
    }

    PillLinkFreqMod ->
      div([], [
        sparse_voice_link_selector(
          "FM Modulator Target Voice (0..255)",
          voice.freq_mod_osc,
          voice.id,
          "#58a6ff",
          model.all_voices,
          fn(tgt) { UpdateVoiceLinkFreqMod(voice.id, tgt) },
        ),
        slider_row(
          "FM Modulation Depth (F)",
          voice.freq_mod_depth,
          0.0,
          10.0,
          0.05,
          "index",
          fn(d) { UpdateVoiceFreqModDepth(voice.id, d) },
        ),
      ])

    PillLinkAmpMod ->
      sparse_voice_link_selector(
        "AM Modulator Target Voice (0..255)",
        voice.amp_mod_osc,
        voice.id,
        "#a371f7",
        model.all_voices,
        fn(tgt) { UpdateVoiceLinkAmpMod(voice.id, tgt) },
      )

    PillLinkRingMod ->
      sparse_voice_link_selector(
        "Ring Mod Target Voice (0..255)",
        voice.ring_osc,
        voice.id,
        "#f0883e",
        model.all_voices,
        fn(tgt) { UpdateVoiceLinkRingMod(voice.id, tgt) },
      )

    PillLinkCzMod ->
      sparse_voice_link_selector(
        "CZ Phase Mod Target Voice (0..255)",
        voice.cz_mod_osc,
        voice.id,
        "#bc8cff",
        model.all_voices,
        fn(tgt) { UpdateVoiceLinkCzMod(voice.id, tgt) },
      )

    PillLinkPanMod ->
      sparse_voice_link_selector(
        "Pan Mod Target Voice (0..255)",
        voice.pan_mod_osc,
        voice.id,
        "#3fb950",
        model.all_voices,
        fn(tgt) { UpdateVoiceLinkPanMod(voice.id, tgt) },
      )

    PillLinkMidi -> {
      let current_midi = case voice.link_midi {
        [t, ..] -> float.round(t)
        _ -> -1
      }
      sparse_voice_link_selector(
        "MIDI Gate Follower Target (0..255)",
        current_midi,
        voice.id,
        "#3fb950",
        model.all_voices,
        fn(tgt) { UpdateVoiceLinkMidi(voice.id, tgt) },
      )
    }

    PillLinkVelo -> {
      let current_velo = case voice.link_velo {
        [t, ..] -> float.round(t)
        _ -> -1
      }
      sparse_voice_link_selector(
        "Velocity Follower Target (0..255)",
        current_velo,
        voice.id,
        "#f85149",
        model.all_voices,
        fn(tgt) { UpdateVoiceLinkVelo(voice.id, tgt) },
      )
    }

    PillRecordTrack ->
      div([], [
        slider_row(
          "Record Stem Track (r)",
          int.to_float(voice.record),
          0.0,
          15.0,
          1.0,
          case voice.record {
            0 -> "Master"
            t -> "Track " <> int.to_string(t)
          },
          fn(r) { UpdateVoiceRecord(voice.id, float.round(r)) },
        ),
        div(
          [
            styles([
              #("display", "flex"),
              #("gap", "6px"),
              #("flex-wrap", "wrap"),
              #("margin-top", "6px"),
            ]),
          ],
          [
            button(
              [
                on_click(UpdateVoiceRecord(voice.id, 0)),
                styles([
                  #("background", "var(--bg-card-subtle, #21262d)"),
                  #("color", case voice.record == 0 {
                    True -> "#58a6ff"
                    False -> "var(--text-secondary, #c9d1d9)"
                  }),
                  #("border", "1px solid var(--border-subtle, #30363d)"),
                  #("border-radius", "4px"),
                  #("padding", "3px 8px"),
                  #("font-size", "11px"),
                  #("cursor", "pointer"),
                ]),
              ],
              [text("r0: Main Master")],
            ),
            button(
              [
                on_click(UpdateVoiceRecord(voice.id, 1)),
                styles([
                  #("background", "var(--bg-card-subtle, #21262d)"),
                  #("color", case voice.record == 1 {
                    True -> "#d29922"
                    False -> "var(--text-secondary, #c9d1d9)"
                  }),
                  #("border", "1px solid var(--border-subtle, #30363d)"),
                  #("border-radius", "4px"),
                  #("padding", "3px 8px"),
                  #("font-size", "11px"),
                  #("cursor", "pointer"),
                ]),
              ],
              [text("r1: Track 1")],
            ),
            button(
              [
                on_click(UpdateVoiceRecord(voice.id, 2)),
                styles([
                  #("background", "var(--bg-card-subtle, #21262d)"),
                  #("color", case voice.record == 2 {
                    True -> "#d29922"
                    False -> "var(--text-secondary, #c9d1d9)"
                  }),
                  #("border", "1px solid var(--border-subtle, #30363d)"),
                  #("border-radius", "4px"),
                  #("padding", "3px 8px"),
                  #("font-size", "11px"),
                  #("cursor", "pointer"),
                ]),
              ],
              [text("r2: Track 2")],
            ),
            button(
              [
                on_click(UpdateVoiceRecord(voice.id, 3)),
                styles([
                  #("background", "var(--bg-card-subtle, #21262d)"),
                  #("color", case voice.record == 3 {
                    True -> "#d29922"
                    False -> "var(--text-secondary, #c9d1d9)"
                  }),
                  #("border", "1px solid var(--border-subtle, #30363d)"),
                  #("border-radius", "4px"),
                  #("padding", "3px 8px"),
                  #("font-size", "11px"),
                  #("cursor", "pointer"),
                ]),
              ],
              [text("r3: Track 3")],
            ),
          ],
        ),
      ])

    PillGlissando ->
      div([], [
        div(
          [
            styles([
              #("display", "flex"),
              #("align-items", "center"),
              #("justify-content", "space-between"),
              #("margin-bottom", "10px"),
            ]),
          ],
          [
            span(
              [
                styles([
                  #("font-size", "12px"),
                  #("color", "var(--text-secondary, #c9d1d9)"),
                ]),
              ],
              [text("Glide Enable State")],
            ),
            button(
              [
                on_click(
                  UpdateVoiceGlissandoEnable(
                    voice.id,
                    case voice.glissando_enable {
                      0 -> 1
                      _ -> 0
                    },
                  ),
                ),
                styles([
                  #("padding", "4px 10px"),
                  #("border-radius", "6px"),
                  #("font-size", "11px"),
                  #("font-weight", "bold"),
                  #("cursor", "pointer"),
                  #("background", case voice.glissando_enable != 0 {
                    True -> "#238636"
                    False -> "var(--bg-card-subtle, #21262d)"
                  }),
                  #("color", case voice.glissando_enable != 0 {
                    True -> "#ffffff"
                    False -> "var(--text-muted, #8b949e)"
                  }),
                  #("border", "1px solid #30363d"),
                ]),
              ],
              [
                text(case voice.glissando_enable != 0 {
                  True -> "✓ Glide Active"
                  False -> "✕ Glide Off"
                }),
              ],
            ),
          ],
        ),
        slider_row(
          "Glide Portamento Time (g)",
          voice.glissando_time,
          0.0,
          2.0,
          0.01,
          "s",
          fn(gt) { UpdateVoiceGlissandoTime(voice.id, gt) },
        ),
        div(
          [
            styles([
              #("display", "flex"),
              #("gap", "4px"),
              #("flex-wrap", "wrap"),
              #("margin-top", "6px"),
            ]),
          ],
          [
            button(
              [
                on_click(UpdateVoiceGlissandoTime(voice.id, 0.0)),
                styles([
                  #("background", "var(--bg-card-subtle, #21262d)"),
                  #("color", "var(--text-primary, #f0f6fc)"),
                  #("border", "1px solid var(--border-subtle, #30363d)"),
                  #("border-radius", "4px"),
                  #("padding", "2px 8px"),
                  #("font-size", "11px"),
                  #("cursor", "pointer"),
                ]),
              ],
              [text("0ms (Off)")],
            ),
            button(
              [
                on_click(UpdateVoiceGlissandoTime(voice.id, 0.02)),
                styles([
                  #("background", "var(--bg-card-subtle, #21262d)"),
                  #("color", "var(--text-primary, #f0f6fc)"),
                  #("border", "1px solid var(--border-subtle, #30363d)"),
                  #("border-radius", "4px"),
                  #("padding", "2px 8px"),
                  #("font-size", "11px"),
                  #("cursor", "pointer"),
                ]),
              ],
              [text("20ms")],
            ),
            button(
              [
                on_click(UpdateVoiceGlissandoTime(voice.id, 0.05)),
                styles([
                  #("background", "var(--bg-card-subtle, #21262d)"),
                  #("color", "var(--text-primary, #f0f6fc)"),
                  #("border", "1px solid var(--border-subtle, #30363d)"),
                  #("border-radius", "4px"),
                  #("padding", "2px 8px"),
                  #("font-size", "11px"),
                  #("cursor", "pointer"),
                ]),
              ],
              [text("50ms")],
            ),
            button(
              [
                on_click(UpdateVoiceGlissandoTime(voice.id, 0.1)),
                styles([
                  #("background", "var(--bg-card-subtle, #21262d)"),
                  #("color", "var(--text-primary, #f0f6fc)"),
                  #("border", "1px solid var(--border-subtle, #30363d)"),
                  #("border-radius", "4px"),
                  #("padding", "2px 8px"),
                  #("font-size", "11px"),
                  #("cursor", "pointer"),
                ]),
              ],
              [text("100ms")],
            ),
            button(
              [
                on_click(UpdateVoiceGlissandoTime(voice.id, 0.25)),
                styles([
                  #("background", "var(--bg-card-subtle, #21262d)"),
                  #("color", "var(--text-primary, #f0f6fc)"),
                  #("border", "1px solid var(--border-subtle, #30363d)"),
                  #("border-radius", "4px"),
                  #("padding", "2px 8px"),
                  #("font-size", "11px"),
                  #("cursor", "pointer"),
                ]),
              ],
              [text("250ms")],
            ),
          ],
        ),
      ])

    PillSmoother ->
      slider_row(
        "Smoothing Coefficient (sm)",
        voice.smoother_smoothing,
        0.0,
        0.99,
        0.02,
        "",
        fn(sm) { UpdateVoiceSmoother(voice.id, sm) },
      )

    PillCzDistortion ->
      div([], [
        div([styles([#("margin-bottom", "12px")])], [
          div(
            [
              styles([
                #("font-size", "12px"),
                #("color", "var(--text-muted, #8b949e)"),
                #("margin-bottom", "6px"),
              ]),
            ],
            [text("Casio CZ Phase Distortion Mode (c / cz)")],
          ),
          select(
            [
              on_input(fn(s) { UpdateVoiceCzMode(voice.id, parse_int(s, 0)) }),
              styles([
                #("width", "100%"),
                #("padding", "6px 8px"),
                #("background", "var(--bg-card-subtle, #21262d)"),
                #("color", "var(--text-primary, #f0f6fc)"),
                #("border", "1px solid #30363d"),
                #("border-radius", "6px"),
                #("font-size", "12px"),
              ]),
            ],
            [
              option(
                [value("0"), attribute.selected(voice.cz_mode == 0)],
                "0: Bypass (Off)",
              ),
              option(
                [value("1"), attribute.selected(voice.cz_mode == 1)],
                "1: Sawtooth Waveform",
              ),
              option(
                [value("2"), attribute.selected(voice.cz_mode == 2)],
                "2: Square / Pulse Waveform",
              ),
              option(
                [value("3"), attribute.selected(voice.cz_mode == 3)],
                "3: Double Sine / Pulse",
              ),
              option(
                [value("4"), attribute.selected(voice.cz_mode == 4)],
                "4: Half-Sine / Resonant Saw",
              ),
              option(
                [value("5"), attribute.selected(voice.cz_mode == 5)],
                "5: Resonant Triangle",
              ),
              option(
                [value("6"), attribute.selected(voice.cz_mode == 6)],
                "6: Resonant Trapezoid / Brass",
              ),
            ],
          ),
        ]),
        slider_row(
          "CZ Phase Distortion Amount (czd)",
          voice.cz_distortion,
          0.0,
          1.0,
          0.02,
          "",
          fn(czd) { UpdateVoiceCzDistortion(voice.id, czd) },
        ),
      ])

    PillRingAmount ->
      slider_row(
        "Ring Mod Amount (xm)",
        voice.ring_amount,
        0.0,
        1.0,
        0.02,
        "",
        fn(ra) { UpdateVoiceRingAmount(voice.id, ra) },
      )

    PillSampleHold ->
      slider_row(
        "Sample & Hold Ratio (sh)",
        voice.sample_hold_ratio,
        0.0,
        1.0,
        0.02,
        "",
        fn(sh) { UpdateVoiceSampleHold(voice.id, sh) },
      )

    PillQuantize ->
      div([], [
        select(
          [
            on_input(fn(s) { UpdateVoiceQuantize(voice.id, parse_int(s, 0)) }),
            styles([
              #("width", "100%"),
              #("padding", "8px"),
              #("background", "var(--bg-card-subtle, #21262d)"),
              #("color", "var(--text-primary, #f0f6fc)"),
            ]),
          ],
          [
            option(
              [value("0"), attribute.selected(voice.quantize == 0)],
              "0: Off / Continuous",
            ),
            option(
              [value("1"), attribute.selected(voice.quantize == 1)],
              "1: Chromatic Semitones (12-EDO)",
            ),
            option(
              [value("2"), attribute.selected(voice.quantize == 2)],
              "2: Quarter-Tones (24-EDO)",
            ),
          ],
        ),
      ])

    PillDelaySend ->
      slider_row(
        "Delay Send Level (del)",
        voice.delay_send,
        0.0,
        1.0,
        0.02,
        "",
        fn(d) { UpdateVoiceDelaySend(voice.id, d) },
      )

    PillFreqBend ->
      slider_row(
        "Pitch Bend Range (bp)",
        voice.freq_bend_range,
        0.0,
        48.0,
        1.0,
        "st",
        fn(bp) { UpdateVoiceFreqBend(voice.id, bp) },
      )

    PillAmpBend ->
      slider_row(
        "Amp Bend Range (abp)",
        voice.amp_bend_range,
        0.0,
        48.0,
        1.0,
        "dB",
        fn(abp) { UpdateVoiceAmpBend(voice.id, abp) },
      )
  }
}

// -----------------------------------------------------------------------------
// Sparse Voice Link Selector (Without 256 monster pulldown)
// -----------------------------------------------------------------------------

fn sparse_voice_link_selector(
  title: String,
  current_target: Int,
  self_id: Int,
  accent_color: String,
  all_voices: List(Voice),
  on_change: fn(Int) -> Msg,
) -> Element(Msg) {
  let other_configured =
    all_voices
    |> list.filter(fn(v) { v.id != self_id })
    |> list.map(fn(v) { v.id })
    |> list.unique
    |> list.sort(int.compare)

  div([styles([#("margin-bottom", "14px")])], [
    div(
      [
        styles([
          #("display", "flex"),
          #("justify-content", "space-between"),
          #("font-size", "13px"),
          #("margin-bottom", "6px"),
        ]),
      ],
      [
        span([styles([#("color", "var(--text-muted, #8b949e)")])], [text(title)]),
        case current_target >= 0 {
          True ->
            span(
              [
                styles([
                  #("background", accent_color <> "22"),
                  #("color", accent_color),
                  #("padding", "2px 8px"),
                  #("border-radius", "4px"),
                  #("font-size", "11px"),
                  #("font-weight", "600"),
                ]),
              ],
              [text("Target: v" <> int.to_string(current_target))],
            )
          False ->
            span([styles([#("color", "#484f58"), #("font-size", "11px")])], [
              text("Disabled (-1)"),
            ])
        },
      ],
    ),
    div(
      [
        styles([
          #("display", "flex"),
          #("gap", "8px"),
          #("align-items", "center"),
        ]),
      ],
      [
        button(
          [
            on_click(on_change(-1)),
            styles([
              #("padding", "6px 12px"),
              #("background", case current_target < 0 {
                True -> "#da3633"
                False -> "var(--bg-card-subtle, #21262d)"
              }),
              #("color", "#ffffff"),
              #("border", "1px solid #30363d"),
              #("border-radius", "6px"),
              #("font-size", "12px"),
              #("cursor", "pointer"),
            ]),
          ],
          [text("Off (-1)")],
        ),
        input([
          type_("number"),
          min("0"),
          max("255"),
          placeholder("Voice 0..255"),
          value(case current_target >= 0 {
            True -> int.to_string(current_target)
            False -> ""
          }),
          on_input(fn(s) {
            case int.parse(s) {
              Ok(tgt) if tgt >= 0 && tgt <= 255 -> on_change(tgt)
              _ -> on_change(-1)
            }
          }),
          styles([
            #("width", "110px"),
            #("padding", "6px 10px"),
            #("background", "var(--bg-card-subtle, #21262d)"),
            #("color", "var(--text-primary, #f0f6fc)"),
            #("border", "1px solid #30363d"),
            #("border-radius", "6px"),
            #("font-size", "13px"),
            #("text-align", "center"),
          ]),
        ]),
        case other_configured {
          [] -> element.none()
          _ ->
            div(
              [
                styles([
                  #("display", "flex"),
                  #("gap", "4px"),
                  #("flex-wrap", "wrap"),
                ]),
              ],
              [
                span(
                  [
                    styles([
                      #("font-size", "11px"),
                      #("color", "var(--text-muted, #8b949e)"),
                      #("margin", "0 4px"),
                    ]),
                  ],
                  [text("Quick:")],
                ),
                ..list.map(other_configured, fn(id) {
                  button(
                    [
                      on_click(on_change(id)),
                      styles([
                        #("padding", "3px 8px"),
                        #("background", case current_target == id {
                          True -> accent_color <> "33"
                          False -> "var(--bg-card-subtle, #21262d)"
                        }),
                        #("color", case current_target == id {
                          True -> accent_color
                          False -> "var(--text-muted, #8b949e)"
                        }),
                        #("border", "1px solid #30363d"),
                        #("border-radius", "4px"),
                        #("font-size", "11px"),
                        #("cursor", "pointer"),
                      ]),
                    ],
                    [text("v" <> int.to_string(id))],
                  )
                })
              ],
            )
        },
      ],
    ),
  ])
}

// -----------------------------------------------------------------------------
// Top Navigation: Sparse 256 Voices Selector
// -----------------------------------------------------------------------------

fn render_sparse_voice_bar(model: Model) -> Element(Msg) {
  let configured_voices =
    get_configured_voices(model.all_voices, model.voice.id)

  div(
    [
      styles([
        #("background", "var(--bg-card, #161b22)"),
        #("border", "1px solid #30363d"),
        #("border-radius", "8px"),
        #("padding", "12px 16px"),
        #("margin-bottom", "18px"),
        #("display", "flex"),
        #("flex-wrap", "wrap"),
        #("justify-content", "space-between"),
        #("align-items", "center"),
        #("gap", "12px"),
      ]),
    ],
    [
      // Configured Voices Chips
      div(
        [
          styles([
            #("display", "flex"),
            #("align-items", "center"),
            #("gap", "6px"),
            #("flex-wrap", "wrap"),
          ]),
        ],
        [
          span(
            [
              styles([
                #("font-size", "12px"),
                #("color", "var(--text-muted, #8b949e)"),
                #("font-weight", "600"),
                #("margin-right", "4px"),
              ]),
            ],
            [text("Configured Voices:")],
          ),
          ..list.map(configured_voices, fn(v) {
            let is_active = v.id == model.voice.id
            button(
              [
                on_click(SetVoiceId(v.id)),
                styles([
                  #("padding", "4px 10px"),
                  #("border-radius", "14px"),
                  #("font-size", "12px"),
                  #("font-family", "monospace"),
                  #("font-weight", "bold"),
                  #("cursor", "pointer"),
                  #("background", case is_active {
                    True -> "#1f6feb"
                    False -> "var(--bg-card-subtle, #21262d)"
                  }),
                  #("color", case is_active {
                    True -> "#ffffff"
                    False -> "var(--text-secondary, #c9d1d9)"
                  }),
                  #("border", case is_active {
                    True -> "1px solid #58a6ff"
                    False -> "1px solid #30363d"
                  }),
                ]),
              ],
              [
                text(
                  "v"
                  <> int.to_string(v.id)
                  <> case is_active {
                    True -> " ★"
                    False -> ""
                  },
                ),
              ],
            )
          })
        ],
      ),
      // 256-Voice Stepper & Numeric Jump Input
      div(
        [
          styles([
            #("display", "flex"),
            #("align-items", "center"),
            #("gap", "6px"),
          ]),
        ],
        [
          button(
            [
              on_click(JumpPrevConfigured),
              styles([
                #("padding", "4px 8px"),
                #("background", "var(--bg-card-subtle, #21262d)"),
                #("color", "var(--text-muted, #8b949e)"),
                #("border", "1px solid #30363d"),
                #("border-radius", "4px"),
                #("font-size", "11px"),
                #("cursor", "pointer"),
              ]),
            ],
            [text("⏮ Prev")],
          ),
          button(
            [
              on_click(StepVoice(-1)),
              styles([
                #("padding", "4px 10px"),
                #("background", "var(--bg-card-subtle, #21262d)"),
                #("color", "var(--text-primary, #f0f6fc)"),
                #("border", "1px solid #30363d"),
                #("border-radius", "4px"),
                #("font-weight", "bold"),
                #("cursor", "pointer"),
              ]),
            ],
            [text("◀")],
          ),
          span(
            [
              styles([
                #("font-family", "monospace"),
                #("font-weight", "bold"),
                #("color", "#58a6ff"),
              ]),
            ],
            [text("v")],
          ),
          form(
            [
              on_submit(fn(_) { SubmitVoiceJump }),
              styles([#("display", "inline-flex"), #("align-items", "center")]),
            ],
            [
              input([
                type_("number"),
                min("0"),
                max("255"),
                value(model.voice_jump_input),
                on_input(SetVoiceJumpInput),
                styles([
                  #("width", "56px"),
                  #("padding", "4px 6px"),
                  #("background", "var(--bg-app, #0d1117)"),
                  #("color", "#58a6ff"),
                  #("border", "1px solid #30363d"),
                  #("border-radius", "4px"),
                  #("font-size", "13px"),
                  #("font-family", "monospace"),
                  #("font-weight", "bold"),
                  #("text-align", "center"),
                ]),
              ]),
            ],
          ),
          span([styles([#("font-size", "11px"), #("color", "#484f58")])], [
            text("/ 255"),
          ]),
          button(
            [
              on_click(StepVoice(1)),
              styles([
                #("padding", "4px 10px"),
                #("background", "var(--bg-card-subtle, #21262d)"),
                #("color", "var(--text-primary, #f0f6fc)"),
                #("border", "1px solid #30363d"),
                #("border-radius", "4px"),
                #("font-weight", "bold"),
                #("cursor", "pointer"),
              ]),
            ],
            [text("▶")],
          ),
          button(
            [
              on_click(JumpNextConfigured),
              styles([
                #("padding", "4px 8px"),
                #("background", "var(--bg-card-subtle, #21262d)"),
                #("color", "var(--text-muted, #8b949e)"),
                #("border", "1px solid #30363d"),
                #("border-radius", "4px"),
                #("font-size", "11px"),
                #("cursor", "pointer"),
              ]),
            ],
            [text("Next ⏭")],
          ),
        ],
      ),
    ],
  )
}

// -----------------------------------------------------------------------------
// Side-by-Side Voice Cards Deck (Active + Linked Partner Cards)
// -----------------------------------------------------------------------------

fn render_voice_deck(model: Model) -> Element(Msg) {
  let active_v = model.voice
  let active_envs = get_voice_envelopes(model, active_v.id)
  let linked_partner_ids = find_linked_partner_ids(active_v, model.all_voices)

  div(
    [
      styles([
        #("display", "flex"),
        #("flex-direction", "column"),
        #("gap", "16px"),
        #("margin-bottom", "20px"),
      ]),
    ],
    [
      // 1. Primary Active Focused Voice Card
      render_primary_voice_card(
        active_v,
        active_envs,
        linked_partner_ids,
        model,
      ),
      // 2. Referenced & Linked Satellite Voices Section
      case linked_partner_ids {
        [] ->
          div(
            [
              styles([
                #("background", "var(--bg-card, #161b22)"),
                #("border", "1px dashed #30363d"),
                #("border-radius", "8px"),
                #("padding", "16px 20px"),
                #("display", "flex"),
                #("justify-content", "space-between"),
                #("align-items", "center"),
                #("flex-wrap", "wrap"),
                #("gap", "12px"),
              ]),
            ],
            [
              div(
                [
                  styles([
                    #("display", "flex"),
                    #("flex-direction", "column"),
                    #("gap", "4px"),
                  ]),
                ],
                [
                  span(
                    [
                      styles([
                        #("font-size", "13px"),
                        #("color", "var(--text-muted, #8b949e)"),
                        #("font-weight", "600"),
                      ]),
                    ],
                    [
                      text(
                        "No Satellite Voices Currently Linked to v"
                        <> int.to_string(active_v.id),
                      ),
                    ],
                  ),
                  p(
                    [
                      styles([
                        #("font-size", "12px"),
                        #("color", "#484f58"),
                        #("margin", "0"),
                      ]),
                    ],
                    [
                      text(
                        "Connect another voice to set up Hard Sync, Frequency Modulation (FM), or Gate following:",
                      ),
                    ],
                  ),
                ],
              ),
              div(
                [
                  styles([
                    #("display", "flex"),
                    #("gap", "8px"),
                    #("flex-wrap", "wrap"),
                  ]),
                ],
                [
                  button(
                    [
                      on_click(AddVoiceParam(active_v.id, PillLinkSync)),
                      styles([
                        #("padding", "6px 12px"),
                        #("background", "var(--bg-card-subtle, #21262d)"),
                        #("color", "#d29922"),
                        #("border", "1px solid #30363d"),
                        #("border-radius", "6px"),
                        #("font-size", "12px"),
                        #("cursor", "pointer"),
                      ]),
                    ],
                    [text("⚡ Hard Sync (HS)")],
                  ),
                  button(
                    [
                      on_click(AddVoiceParam(active_v.id, PillLinkFreqMod)),
                      styles([
                        #("padding", "6px 12px"),
                        #("background", "var(--bg-card-subtle, #21262d)"),
                        #("color", "#58a6ff"),
                        #("border", "1px solid #30363d"),
                        #("border-radius", "6px"),
                        #("font-size", "12px"),
                        #("cursor", "pointer"),
                      ]),
                    ],
                    [text("🌊 FM Mod (FM)")],
                  ),
                  button(
                    [
                      on_click(AddVoiceParam(active_v.id, PillLinkAmpMod)),
                      styles([
                        #("padding", "6px 12px"),
                        #("background", "var(--bg-card-subtle, #21262d)"),
                        #("color", "#a371f7"),
                        #("border", "1px solid #30363d"),
                        #("border-radius", "6px"),
                        #("font-size", "12px"),
                        #("cursor", "pointer"),
                      ]),
                    ],
                    [text("📶 AM Mod (AM)")],
                  ),
                  button(
                    [
                      on_click(AddVoiceParam(active_v.id, PillLinkMidi)),
                      styles([
                        #("padding", "6px 12px"),
                        #("background", "var(--bg-card-subtle, #21262d)"),
                        #("color", "#3fb950"),
                        #("border", "1px solid #30363d"),
                        #("border-radius", "6px"),
                        #("font-size", "12px"),
                        #("cursor", "pointer"),
                      ]),
                    ],
                    [text("🎹 Gate (G)")],
                  ),
                ],
              ),
            ],
          )
        partners ->
          div(
            [
              styles([
                #("background", "var(--bg-card, #161b22)"),
                #("border", "1px solid #30363d"),
                #("border-radius", "8px"),
                #("padding", "16px"),
                #("display", "flex"),
                #("flex-direction", "column"),
                #("gap", "12px"),
              ]),
            ],
            [
              // Section Header
              div(
                [
                  styles([
                    #("display", "flex"),
                    #("justify-content", "space-between"),
                    #("align-items", "center"),
                    #("flex-wrap", "wrap"),
                    #("gap", "8px"),
                    #("padding-bottom", "8px"),
                    #("border-bottom", "1px solid #21262d"),
                  ]),
                ],
                [
                  div(
                    [
                      styles([
                        #("display", "flex"),
                        #("align-items", "center"),
                        #("gap", "10px"),
                      ]),
                    ],
                    [
                      span(
                        [
                          styles([
                            #("font-size", "13px"),
                            #("font-weight", "700"),
                            #("color", "var(--text-primary, #f0f6fc)"),
                          ]),
                        ],
                        [
                          text(
                            "📡 REFERENCED & LINKED VOICES ("
                            <> int.to_string(list.length(partners))
                            <> " Connected to Primary v"
                            <> int.to_string(active_v.id)
                            <> ")",
                          ),
                        ],
                      ),
                      span(
                        [
                          styles([
                            #("font-size", "11px"),
                            #("color", "var(--text-muted, #8b949e)"),
                          ]),
                        ],
                        [
                          text(
                            "• Modulator & sync partners wired to this voice",
                          ),
                        ],
                      ),
                    ],
                  ),
                  span(
                    [
                      styles([
                        #("font-size", "11px"),
                        #("color", "#58a6ff"),
                      ]),
                    ],
                    [
                      text(
                        "Click '🎯 Switch Primary Focus' on any card to promote it to active focus",
                      ),
                    ],
                  ),
                ],
              ),
              // Responsive grid of satellite cards
              div(
                [
                  styles([
                    #("display", "grid"),
                    #(
                      "grid-template-columns",
                      "repeat(auto-fit, minmax(320px, 1fr))",
                    ),
                    #("gap", "12px"),
                  ]),
                ],
                list.map(partners, fn(partner_id) {
                  let #(partner_v, _) =
                    get_or_create_voice(model.all_voices, partner_id)
                  let partner_envs = get_voice_envelopes(model, partner_id)
                  let badge =
                    get_relationship_badge(
                      partner_id,
                      active_v,
                      model.all_voices,
                    )
                  render_satellite_voice_card(
                    partner_v,
                    partner_envs,
                    badge,
                    model,
                  )
                }),
              ),
            ],
          )
      },
    ],
  )
}

// -----------------------------------------------------------------------------
// Responsive Parameter Palette Dock
// -----------------------------------------------------------------------------

fn render_parameter_palette(model: Model) -> Element(Msg) {
  let master_palette = get_master_palette()
  let active_envs = get_voice_envelopes(model, model.voice.id)
  let active_pills = get_voice_pills(model.voice, active_envs)
  let active_ids = list.map(active_pills, fn(p) { p.id })

  let query = string.trim(string.lowercase(model.palette_search))
  let filtered_items = case query {
    "" -> master_palette
    q ->
      list.filter(master_palette, fn(item) {
        string.contains(string.lowercase(item.name), q)
        || string.contains(string.lowercase(item.opcode), q)
        || string.contains(string.lowercase(item.description), q)
      })
  }

  div(
    [
      styles([
        #("background", "var(--bg-card, #161b22)"),
        #("border", "1px solid #30363d"),
        #("border-radius", "8px"),
        #("padding", "16px"),
        #("margin-bottom", "20px"),
      ]),
    ],
    [
      // Palette Dock Header
      div(
        [
          styles([
            #("display", "flex"),
            #("justify-content", "space-between"),
            #("align-items", "center"),
            #("margin-bottom", case model.palette_open {
              True -> "14px"
              False -> "0"
            }),
          ]),
        ],
        [
          div(
            [
              styles([
                #("display", "flex"),
                #("align-items", "center"),
                #("gap", "10px"),
              ]),
            ],
            [
              span(
                [
                  styles([
                    #("font-weight", "700"),
                    #("font-size", "14px"),
                    #("color", "var(--text-primary, #f0f6fc)"),
                  ]),
                ],
                [text("🎨 Synthesizer Parameter Palette (89 Schema Parameters)")],
              ),
              span(
                [
                  styles([
                    #("font-size", "12px"),
                    #("color", "var(--text-muted, #8b949e)"),
                  ]),
                ],
                [
                  text(
                    "Tap swatch to attach & tweak on v"
                    <> int.to_string(model.voice.id),
                  ),
                ],
              ),
            ],
          ),
          button(
            [
              on_click(TogglePalette),
              styles([
                #("padding", "4px 10px"),
                #("background", "var(--bg-card-subtle, #21262d)"),
                #("color", "var(--text-muted, #8b949e)"),
                #("border", "1px solid #30363d"),
                #("border-radius", "6px"),
                #("font-size", "12px"),
                #("cursor", "pointer"),
              ]),
            ],
            [
              text(case model.palette_open {
                True -> "▲ Collapse Dock"
                False -> "▼ Expand Dock"
              }),
            ],
          ),
        ],
      ),
      // Palette Body
      case model.palette_open {
        False -> element.none()
        True ->
          div([], [
            // Filter / Search Bar
            div([styles([#("margin-bottom", "14px")])], [
              input([
                type_("text"),
                placeholder(
                  "Search 89 parameters / opcodes... (e.g. sync, cutoff, adsr, fm, cz, delay)",
                ),
                value(model.palette_search),
                on_input(SetPaletteSearch),
                styles([
                  #("width", "100%"),
                  #("padding", "8px 12px"),
                  #("background", "var(--bg-app, #0d1117)"),
                  #("color", "var(--text-primary, #f0f6fc)"),
                  #("border", "1px solid #30363d"),
                  #("border-radius", "6px"),
                  #("font-size", "13px"),
                  #("box-sizing", "border-box"),
                ]),
              ]),
            ]),
            // Swatches Grid
            div(
              [
                styles([
                  #("display", "grid"),
                  #(
                    "grid-template-columns",
                    "repeat(auto-fill, minmax(210px, 1fr))",
                  ),
                  #("gap", "8px"),
                ]),
              ],
              list.map(filtered_items, fn(item) {
                let is_attached = list.contains(active_ids, item.id)
                button(
                  [
                    on_click(case is_attached {
                      True -> SelectVoicePill(model.voice.id, item.id)
                      False -> AddVoiceParam(model.voice.id, item.id)
                    }),
                    styles([
                      #("padding", "8px 10px"),
                      #("display", "flex"),
                      #("flex-direction", "column"),
                      #("align-items", "flex-start"),
                      #("gap", "2px"),
                      #("border-radius", "6px"),
                      #("cursor", "pointer"),
                      #("text-align", "left"),
                      #("background", case is_attached {
                        True -> item.bg_color
                        False -> "var(--bg-card-subtle, #21262d)"
                      }),
                      #("color", case is_attached {
                        True -> item.fg_color
                        False -> "var(--text-secondary, #c9d1d9)"
                      }),
                      #("border", case is_attached {
                        True -> "1px solid " <> item.fg_color
                        False -> "1px solid #30363d"
                      }),
                      #("box-shadow", case is_attached {
                        True -> "0 0 6px " <> item.fg_color <> "33"
                        False -> "none"
                      }),
                      #("transition", "all 0.15s ease"),
                    ]),
                  ],
                  [
                    div(
                      [
                        styles([
                          #("display", "flex"),
                          #("justify-content", "space-between"),
                          #("width", "100%"),
                          #("align-items", "center"),
                        ]),
                      ],
                      [
                        span(
                          [
                            styles([
                              #("font-weight", "600"),
                              #("font-size", "12px"),
                            ]),
                          ],
                          [
                            text(case is_attached {
                              True -> "✓ " <> item.name
                              False -> "＋ " <> item.name
                            }),
                          ],
                        ),
                        span(
                          [
                            styles([
                              #("font-family", "monospace"),
                              #("font-size", "10px"),
                              #("padding", "1px 4px"),
                              #("border-radius", "3px"),
                              #("background", case is_attached {
                                True -> item.fg_color <> "33"
                                False -> "var(--bg-card, #161b22)"
                              }),
                              #("color", case is_attached {
                                True -> item.fg_color
                                False -> "var(--text-muted, #8b949e)"
                              }),
                            ]),
                          ],
                          [text(item.opcode)],
                        ),
                      ],
                    ),
                    span(
                      [
                        styles([
                          #("font-size", "10px"),
                          #("color", case is_attached {
                            True -> item.fg_color <> "cc"
                            False -> "var(--text-muted, #8b949e)"
                          }),
                          #("line-height", "1.2"),
                        ]),
                      ],
                      [text(item.description)],
                    ),
                  ],
                )
              }),
            ),
          ])
      },
    ],
  )
}

fn render_skode_command_entry(model: Model, skode_cmd: String) -> Element(Msg) {
  div(
    [
      styles([
        #("background", "var(--bg-card, #161b22)"),
        #("border", "1px solid #30363d"),
        #("border-radius", "8px"),
        #("padding", "16px"),
        #("margin-bottom", "20px"),
      ]),
    ],
    [
      div(
        [
          styles([
            #("display", "flex"),
            #("justify-content", "space-between"),
            #("align-items", "center"),
            #("margin-bottom", "12px"),
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
                  #("color", "var(--text-muted, #8b949e)"),
                  #("display", "block"),
                  #("margin-bottom", "4px"),
                ]),
              ],
              [text("Active Voice Skode Command")],
            ),
            pre(
              [
                styles([
                  #("font-family", "monospace"),
                  #("font-size", "14px"),
                  #("color", "#7ee787"),
                  #("margin", "0"),
                ]),
              ],
              [text(skode_cmd)],
            ),
          ]),
          div(
            [
              styles([
                #("display", "flex"),
                #("gap", "8px"),
                #("align-items", "center"),
              ]),
            ],
            [
              button(
                [
                  on_click(ToggleConsole),
                  type_("button"),
                  styles([
                    #("padding", "6px 12px"),
                    #("background", case model.show_console {
                      True -> "#1f6feb"
                      False -> "var(--bg-card-subtle, #21262d)"
                    }),
                    #("color", case model.show_console {
                      True -> "#ffffff"
                      False -> "var(--text-secondary, #c9d1d9)"
                    }),
                    #("border", case model.show_console {
                      True -> "1px solid #58a6ff"
                      False -> "1px solid #30363d"
                    }),
                    #("border-radius", "6px"),
                    #("cursor", "pointer"),
                    #("font-size", "12px"),
                    #("display", "flex"),
                    #("align-items", "center"),
                    #("gap", "6px"),
                  ]),
                ],
                [
                  text(
                    "📟 Output Log ("
                    <> int.to_string(list.length(model.command_logs))
                    <> ")",
                  ),
                ],
              ),
              button(
                [
                  on_click(CopySkodeText),
                  styles([
                    #("padding", "6px 14px"),
                    #("background", "var(--border, #30363d)"),
                    #("color", "var(--text-primary, #f0f6fc)"),
                    #("border", "1px solid #484f58"),
                    #("border-radius", "6px"),
                    #("cursor", "pointer"),
                    #("font-size", "12px"),
                  ]),
                ],
                [text("Copy Skode")],
              ),
            ],
          ),
        ],
      ),
      // Skode Command Line Box
      form(
        [
          on_submit(fn(_) { SubmitInputCommand }),
          styles([
            #("display", "flex"),
            #("gap", "8px"),
            #("align-items", "center"),
          ]),
        ],
        [
          input([
            type_("text"),
            placeholder(
              "Live Skode input: e.g. v0 w 2 f 880 a -3 HS 1 (Press Enter)",
            ),
            value(model.input_command),
            on_input(SetInputCommand),
            on_keydown(CommandKeyDown),
            styles([
              #("flex", "1"),
              #("padding", "8px 12px"),
              #("background", "var(--bg-app, #0d1117)"),
              #("color", "var(--text-primary, #f0f6fc)"),
              #("border", "1px solid #30363d"),
              #("border-radius", "6px"),
              #("font-family", "monospace"),
              #("font-size", "13px"),
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
              ]),
            ],
            [text("Execute")],
          ),
        ],
      ),
      // Recent History Chips
      div(
        [
          styles([
            #("display", "flex"),
            #("gap", "6px"),
            #("align-items", "center"),
            #("flex-wrap", "wrap"),
            #("margin-top", "8px"),
          ]),
        ],
        [
          span(
            [
              styles([
                #("font-size", "11px"),
                #("color", "var(--text-muted, #8b949e)"),
              ]),
            ],
            [
              text("Recent:"),
            ],
          ),
          ..list.map(list.take(model.history, 8), fn(hist_cmd) {
            button(
              [
                on_click(RecallHistoryItem(hist_cmd)),
                type_("button"),
                styles([
                  #("padding", "2px 8px"),
                  #("background", "var(--bg-card, #161b22)"),
                  #("color", "#79c0ff"),
                  #("border", "1px solid #30363d"),
                  #("border-radius", "4px"),
                  #("font-family", "monospace"),
                  #("font-size", "11px"),
                  #("cursor", "pointer"),
                ]),
              ],
              [text(hist_cmd)],
            )
          })
        ],
      ),
      // Collapsible Console Output Log
      case model.show_console {
        False -> element.none()
        True ->
          div(
            [
              styles([
                #("margin-top", "12px"),
                #("background", "var(--bg-app, #0d1117)"),
                #("border", "1px solid #30363d"),
                #("border-radius", "6px"),
                #("padding", "12px"),
              ]),
            ],
            [
              div(
                [
                  styles([
                    #("display", "flex"),
                    #("justify-content", "space-between"),
                    #("align-items", "center"),
                    #("margin-bottom", "8px"),
                    #("border-bottom", "1px solid #21262d"),
                    #("padding-bottom", "6px"),
                  ]),
                ],
                [
                  span(
                    [
                      styles([
                        #("font-family", "monospace"),
                        #("font-size", "12px"),
                        #("color", "var(--text-muted, #8b949e)"),
                      ]),
                    ],
                    [text("Terminal Output Log & Skode Command History")],
                  ),
                  button(
                    [
                      on_click(ClearConsoleLogs),
                      type_("button"),
                      styles([
                        #("padding", "2px 8px"),
                        #("background", "var(--bg-card-subtle, #21262d)"),
                        #("color", "#f85149"),
                        #("border", "1px solid #30363d"),
                        #("border-radius", "4px"),
                        #("font-size", "11px"),
                        #("cursor", "pointer"),
                      ]),
                    ],
                    [text("Clear Console")],
                  ),
                ],
              ),
              div(
                [
                  styles([
                    #("max-height", "200px"),
                    #("overflow-y", "auto"),
                    #("display", "flex"),
                    #("flex-direction", "column"),
                    #("gap", "6px"),
                    #("font-family", "monospace"),
                    #("font-size", "12px"),
                  ]),
                ],
                list.map(model.command_logs, fn(log) {
                  let is_err =
                    string.starts_with(log.output, "Error")
                    || string.contains(log.output, "syntax error")
                  div(
                    [
                      styles([
                        #("display", "flex"),
                        #("flex-direction", "column"),
                        #("gap", "4px"),
                        #("padding", "6px 10px"),
                        #("background", "var(--bg-card, #161b22)"),
                        #("border-radius", "6px"),
                        #("border", "1px solid #30363d"),
                        #("border-left", case is_err {
                          True -> "3px solid #f85149"
                          False -> "3px solid #3fb950"
                        }),
                      ]),
                    ],
                    [
                      div(
                        [
                          styles([
                            #("display", "flex"),
                            #("justify-content", "space-between"),
                            #("align-items", "center"),
                            #("gap", "10px"),
                          ]),
                        ],
                        [
                          div(
                            [
                              styles([
                                #("display", "flex"),
                                #("gap", "8px"),
                                #("align-items", "center"),
                                #("flex-wrap", "wrap"),
                              ]),
                            ],
                            [
                              span(
                                [
                                  styles([
                                    #("color", "var(--text-muted, #8b949e)"),
                                    #("font-size", "11px"),
                                  ]),
                                ],
                                [text("#" <> int.to_string(log.id))],
                              ),
                              span(
                                [
                                  styles([
                                    #("color", "#7ee787"),
                                    #("font-weight", "600"),
                                  ]),
                                ],
                                [text(log.raw_cmd)],
                              ),
                              span(
                                [
                                  styles([
                                    #("color", "var(--text-muted, #8b949e)"),
                                    #("font-size", "11px"),
                                  ]),
                                ],
                                [text("→ " <> log.summary)],
                              ),
                            ],
                          ),
                          button(
                            [
                              on_click(RecallHistoryItem(log.raw_cmd)),
                              type_("button"),
                              styles([
                                #("padding", "2px 8px"),
                                #(
                                  "background",
                                  "var(--bg-card-subtle, #21262d)",
                                ),
                                #("color", "#58a6ff"),
                                #("border", "1px solid #30363d"),
                                #("border-radius", "4px"),
                                #("font-size", "11px"),
                                #("cursor", "pointer"),
                                #("flex-shrink", "0"),
                              ]),
                            ],
                            [text("Load ↩")],
                          ),
                        ],
                      ),
                      case log.output != "" {
                        True ->
                          div(
                            [
                              styles([
                                #("margin-top", "2px"),
                                #("padding", "6px 10px"),
                                #("background", "var(--bg-app, #0d1117)"),
                                #("border", "1px solid #21262d"),
                                #("border-radius", "4px"),
                                #("color", case is_err {
                                  True -> "#f85149"
                                  False -> "#58a6ff"
                                }),
                                #("font-family", "monospace"),
                                #("font-size", "11px"),
                                #("line-height", "1.4"),
                                #("white-space", "pre-wrap"),
                                #("word-break", "break-all"),
                              ]),
                            ],
                            [text(log.output)],
                          )
                        False -> element.none()
                      },
                    ],
                  )
                }),
              ),
            ],
          )
      },
    ],
  )
}

// -----------------------------------------------------------------------------
// Main View
// -----------------------------------------------------------------------------

fn int_slider_row(
  label_text: String,
  current_val: Int,
  min_val: Int,
  max_val: Int,
  unit_text: String,
  on_change: fn(Int) -> Msg,
) -> Element(Msg) {
  slider_row(
    label_text,
    int.to_float(current_val),
    int.to_float(min_val),
    int.to_float(max_val),
    1.0,
    unit_text,
    fn(f) { on_change(float.round(f)) },
  )
}

fn render_studio_header(model: Model) -> Element(Msg) {
  header(
    [
      styles([
        #("display", "flex"),
        #("justify-content", "space-between"),
        #("align-items", "center"),
        #("margin-bottom", "16px"),
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
              #("color", "var(--text-primary, #f0f6fc)"),
              #("margin", "0 0 4px 0"),
            ]),
          ],
          [text("Pulp Audio Studio Workbench")],
        ),
        p(
          [
            styles([
              #("font-size", "13px"),
              #("color", "var(--text-muted, #8b949e)"),
              #("margin", "0"),
            ]),
          ],
          [
            text(
              "256-Voice Synth • 128-Pattern Sequencer • 4-Bus Delay Matrix • KSynth Studio",
            ),
          ],
        ),
      ]),
      div(
        [
          styles([
            #("display", "flex"),
            #("align-items", "center"),
            #("gap", "8px"),
          ]),
        ],
        [
          button(
            [
              on_click(ExportSessionZip),
              type_("button"),
              styles([
                #("padding", "7px 12px"),
                #("background", "var(--bg-card-subtle, #21262d)"),
                #("color", "#58a6ff"),
                #("border", "1px solid var(--border, #30363d)"),
                #("border-radius", "6px"),
                #("font-size", "12px"),
                #("font-weight", "600"),
                #("cursor", "pointer"),
              ]),
            ],
            [text("💾 Export .zip")],
          ),
          button(
            [
              on_click(ImportSessionZip),
              type_("button"),
              styles([
                #("padding", "7px 12px"),
                #("background", "var(--bg-card-subtle, #21262d)"),
                #("color", "#bc8cff"),
                #("border", "1px solid var(--border, #30363d)"),
                #("border-radius", "6px"),
                #("font-size", "12px"),
                #("font-weight", "600"),
                #("cursor", "pointer"),
              ]),
            ],
            [text("📂 Import .zip")],
          ),
          button(
            [
              on_click(ToggleTheme),
              type_("button"),
              styles([
                #("padding", "7px 12px"),
                #("background", case model.theme {
                  ThemeDark -> "var(--bg-card-subtle, #21262d)"
                  ThemeLight -> "#eaeef2"
                }),
                #("color", case model.theme {
                  ThemeDark -> "var(--text-primary, #f0f6fc)"
                  ThemeLight -> "#24292f"
                }),
                #("border", case model.theme {
                  ThemeDark -> "1px solid #30363d"
                  ThemeLight -> "1px solid #d0d7de"
                }),
                #("border-radius", "6px"),
                #("font-size", "13px"),
                #("font-weight", "600"),
                #("cursor", "pointer"),
              ]),
            ],
            [
              text(case model.theme {
                ThemeDark -> "☀️ Light (Erasmus)"
                ThemeLight -> "🌙 Dark (Atari)"
              }),
            ],
          ),
        ],
      ),
    ],
  )
}

fn render_master_bar(model: Model) -> Element(Msg) {
  div(
    [
      styles([
        #("display", "flex"),
        #("flex-wrap", "wrap"),
        #("gap", "16px"),
        #("align-items", "center"),
        #("justify-content", "space-between"),
        #("background", "var(--bg-card, #161b22)"),
        #("border", "1px solid #30363d"),
        #("border-radius", "8px"),
        #("padding", "12px 16px"),
        #("margin-bottom", "16px"),
      ]),
    ],
    [
      // Context Pointer Badges (v0 and y0 context variables)
      div(
        [
          styles([
            #("display", "flex"),
            #("gap", "10px"),
            #("align-items", "center"),
          ]),
        ],
        [
          div(
            [
              styles([
                #("display", "flex"),
                #("align-items", "center"),
                #("gap", "6px"),
                #("padding", "4px 10px"),
                #("background", "var(--bg-app, #0d1117)"),
                #("border", "1px solid #30363d"),
                #("border-radius", "6px"),
              ]),
            ],
            [
              span(
                [
                  styles([
                    #("font-size", "11px"),
                    #("color", "var(--text-muted, #8b949e)"),
                    #("text-transform", "uppercase"),
                    #("letter-spacing", "0.5px"),
                  ]),
                ],
                [text("Voice Pointer:")],
              ),
              span(
                [
                  styles([
                    #("font-family", "monospace"),
                    #("font-weight", "700"),
                    #("font-size", "13px"),
                    #("color", "#58a6ff"),
                  ]),
                ],
                [text("v" <> int.to_string(model.voice.id))],
              ),
            ],
          ),
          div(
            [
              styles([
                #("display", "flex"),
                #("align-items", "center"),
                #("gap", "6px"),
                #("padding", "4px 10px"),
                #("background", "var(--bg-app, #0d1117)"),
                #("border", "1px solid #30363d"),
                #("border-radius", "6px"),
              ]),
            ],
            [
              span(
                [
                  styles([
                    #("font-size", "11px"),
                    #("color", "var(--text-muted, #8b949e)"),
                    #("text-transform", "uppercase"),
                    #("letter-spacing", "0.5px"),
                  ]),
                ],
                [text("Pattern Pointer:")],
              ),
              span(
                [
                  styles([
                    #("font-family", "monospace"),
                    #("font-weight", "700"),
                    #("font-size", "13px"),
                    #("color", "#39c5bb"),
                  ]),
                ],
                [text("y" <> int.to_string(model.pattern_pointer))],
              ),
            ],
          ),
        ],
      ),
      // Master Sliders: Volume (V) and Tempo (M)
      div(
        [
          styles([
            #("display", "flex"),
            #("gap", "20px"),
            #("align-items", "center"),
            #("flex", "1"),
            #("max-width", "520px"),
            #("justify-content", "flex-end"),
          ]),
        ],
        [
          // Master Volume
          div(
            [
              styles([
                #("display", "flex"),
                #("align-items", "center"),
                #("gap", "8px"),
                #("flex", "1"),
              ]),
            ],
            [
              span(
                [
                  styles([
                    #("font-size", "12px"),
                    #("color", "var(--text-muted, #8b949e)"),
                    #("white-space", "nowrap"),
                  ]),
                ],
                [
                  text(
                    "Vol (V): "
                    <> param.format_float(
                      model.engine_settings.master_volume_db,
                    )
                    <> "dB",
                  ),
                ],
              ),
              input([
                type_("range"),
                min("-60.0"),
                max("12.0"),
                step("0.5"),
                value(float.to_string(model.engine_settings.master_volume_db)),
                on_input(fn(s) {
                  UpdateMasterVolume(parse_float(
                    s,
                    model.engine_settings.master_volume_db,
                  ))
                }),
                styles([
                  #("flex", "1"),
                  #("cursor", "pointer"),
                  #("accent-color", "#238636"),
                ]),
              ]),
            ],
          ),
          // Master BPM
          div(
            [
              styles([
                #("display", "flex"),
                #("align-items", "center"),
                #("gap", "8px"),
                #("flex", "1"),
              ]),
            ],
            [
              span(
                [
                  styles([
                    #("font-size", "12px"),
                    #("color", "var(--text-muted, #8b949e)"),
                    #("white-space", "nowrap"),
                  ]),
                ],
                [
                  text(
                    "Tempo (M): "
                    <> int.to_string(float.round(
                      model.engine_settings.tempo_bpm,
                    ))
                    <> " BPM",
                  ),
                ],
              ),
              input([
                type_("range"),
                min("20.0"),
                max("300.0"),
                step("1.0"),
                value(float.to_string(model.engine_settings.tempo_bpm)),
                on_input(fn(s) {
                  UpdateMasterTempo(parse_float(
                    s,
                    model.engine_settings.tempo_bpm,
                  ))
                }),
                styles([
                  #("flex", "1"),
                  #("cursor", "pointer"),
                  #("accent-color", "#1f6feb"),
                ]),
              ]),
            ],
          ),
        ],
      ),
      // Auto-dispatch toggle
      button(
        [
          on_click(ToggleAutoDispatch),
          type_("button"),
          styles([
            #("padding", "6px 12px"),
            #("font-size", "12px"),
            #("border-radius", "6px"),
            #("cursor", "pointer"),
            #("background", case model.auto_dispatch {
              True -> "#23863622"
              False -> "var(--bg-card-subtle, #21262d)"
            }),
            #("color", case model.auto_dispatch {
              True -> "#3fb950"
              False -> "var(--text-muted, #8b949e)"
            }),
            #("border", case model.auto_dispatch {
              True -> "1px solid #238636"
              False -> "1px solid #30363d"
            }),
          ]),
        ],
        [
          text(case model.auto_dispatch {
            True -> "⚡ Live Sync: Active"
            False -> "⏸ Live Sync: Paused"
          }),
        ],
      ),
    ],
  )
}

fn render_mode_switcher(model: Model) -> Element(Msg) {
  let modes = [
    #(ModeVoices, "🎛 Voices"),
    #(ModePatterns, "🎼 Patterns"),
    #(ModeDelays, "⏱ Delays"),
    #(ModeMacros, "🔴 Macros"),
    #(ModeKSynth, "🧪 k/synth"),
    #(ModeAudioMidi, "🎧 Audio/MIDI"),
    #(ModeFiles, "📁 Files & VFS"),
    #(ModeStreams, "🌊 Streams & Vars"),
  ]

  div(
    [
      styles([
        #("display", "flex"),
        #("flex-wrap", "wrap"),
        #("gap", "6px"),
        #("margin-bottom", "16px"),
        #("border-bottom", "1px solid var(--border, #30363d)"),
        #("padding-bottom", "12px"),
      ]),
    ],
    list.map(modes, fn(entry) {
      let #(mode, label_str) = entry
      let is_active = model.editor_mode == mode
      button(
        [
          on_click(SetEditorMode(mode)),
          type_("button"),
          styles([
            #("padding", "7px 14px"),
            #("border-radius", "6px"),
            #("font-size", "12px"),
            #("font-weight", case is_active {
              True -> "700"
              False -> "500"
            }),
            #("cursor", "pointer"),
            #("transition", "all 0.15s ease"),
            #("white-space", "nowrap"),
            #("background", case is_active {
              True -> "#1f6feb"
              False -> "var(--bg-card-subtle, #21262d)"
            }),
            #("color", case is_active {
              True -> "#ffffff"
              False -> "var(--text-secondary, #c9d1d9)"
            }),
            #("border", case is_active {
              True -> "1px solid #58a6ff"
              False -> "1px solid var(--border, #30363d)"
            }),
          ]),
        ],
        [text(label_str)],
      )
    }),
  )
}

fn render_notification_banner(model: Model) -> Element(Msg) {
  case model.notification {
    Some(note) ->
      div(
        [
          styles([
            #("margin-bottom", "16px"),
            #("padding", "10px 16px"),
            #("background", "#1f6feb22"),
            #("border", "1px solid #1f6feb88"),
            #("border-radius", "6px"),
            #("color", "#58a6ff"),
            #("font-size", "13px"),
            #("display", "flex"),
            #("justify-content", "space-between"),
            #("align-items", "center"),
          ]),
        ],
        [
          span([], [text(note)]),
          button(
            [
              on_click(DismissNotification),
              type_("button"),
              styles([
                #("background", "transparent"),
                #("border", "none"),
                #("color", "var(--text-muted, #8b949e)"),
                #("cursor", "pointer"),
                #("font-size", "16px"),
              ]),
            ],
            [text("×")],
          ),
        ],
      )
    None -> element.none()
  }
}

fn render_voice_studio(model: Model) -> Element(Msg) {
  div([], [
    // 1. Sparse 256-Voice Navigation Bar
    render_sparse_voice_bar(model),
    // 2. Side-by-Side Voice Cards Deck (Primary + Linked Voices Aside It)
    render_voice_deck(model),
    // 3. Pinned Parameter Inspectors (Side-by-Side Deck)
    render_pinned_inspectors(model),
    // 4. Parameter Palette Dock (89 Parameters & Swatches)
    render_parameter_palette(model),
    // 5. Sound Presets
    div(
      [
        styles([
          #("display", "flex"),
          #("gap", "8px"),
          #("flex-wrap", "wrap"),
          #("margin-bottom", "20px"),
          #("align-items", "center"),
        ]),
      ],
      [
        span(
          [
            styles([
              #("font-size", "12px"),
              #("color", "var(--text-muted, #8b949e)"),
            ]),
          ],
          [
            text("Voice Presets:"),
          ],
        ),
        preset_pill("Acid Lead"),
        preset_pill("Hard-Sync Lead"),
        preset_pill("FM 2-Op Lead"),
        preset_pill("Table Noise"),
        preset_pill("PRNG White Noise"),
        preset_pill("CZ Phase Crunch"),
      ],
    ),
  ])
}

fn render_pattern_sequencer(model: Model) -> Element(Msg) {
  let #(p, _) =
    get_or_create_pattern(model.all_patterns, model.active_pattern_id)
  let pat_skode = pattern.to_skode(p)

  div(
    [
      styles([
        #("display", "flex"),
        #("flex-direction", "column"),
        #("gap", "18px"),
      ]),
    ],
    [
      // Pattern Selector Bar
      div(
        [
          styles([
            #("display", "flex"),
            #("justify-content", "space-between"),
            #("align-items", "center"),
            #("background", "var(--bg-card, #161b22)"),
            #("border", "1px solid #30363d"),
            #("border-radius", "8px"),
            #("padding", "12px 16px"),
          ]),
        ],
        [
          div(
            [
              styles([
                #("display", "flex"),
                #("align-items", "center"),
                #("gap", "8px"),
              ]),
            ],
            [
              button(
                [
                  on_click(StepPattern(-1)),
                  type_("button"),
                  styles([
                    #("padding", "6px 12px"),
                    #("background", "var(--bg-card-subtle, #21262d)"),
                    #("color", "var(--text-secondary, #c9d1d9)"),
                    #("border", "1px solid #30363d"),
                    #("border-radius", "6px"),
                    #("cursor", "pointer"),
                  ]),
                ],
                [text("◀ Prev")],
              ),
              span(
                [
                  styles([
                    #("font-size", "16px"),
                    #("font-weight", "700"),
                    #("color", "#39c5bb"),
                    #("font-family", "monospace"),
                    #("padding", "0 8px"),
                  ]),
                ],
                [text("Pattern y" <> int.to_string(p.id))],
              ),
              button(
                [
                  on_click(StepPattern(1)),
                  type_("button"),
                  styles([
                    #("padding", "6px 12px"),
                    #("background", "var(--bg-card-subtle, #21262d)"),
                    #("color", "var(--text-secondary, #c9d1d9)"),
                    #("border", "1px solid #30363d"),
                    #("border-radius", "6px"),
                    #("cursor", "pointer"),
                  ]),
                ],
                [text("Next ▶")],
              ),
            ],
          ),
          // Pattern Direct Quick Select Chips (y0..y7)
          div(
            [
              styles([
                #("display", "flex"),
                #("gap", "6px"),
                #("align-items", "center"),
                #("overflow-x", "auto"),
              ]),
            ],
            list.map([0, 1, 2, 3, 4, 5, 6, 7], fn(pid) {
              let is_sel = pid == p.id
              button(
                [
                  on_click(SetPatternId(pid)),
                  type_("button"),
                  styles([
                    #("padding", "4px 8px"),
                    #("font-family", "monospace"),
                    #("font-size", "12px"),
                    #("border-radius", "4px"),
                    #("cursor", "pointer"),
                    #("background", case is_sel {
                      True -> "#39c5bb"
                      False -> "var(--bg-card-subtle, #21262d)"
                    }),
                    #("color", case is_sel {
                      True -> "var(--bg-app, #0d1117)"
                      False -> "var(--text-secondary, #c9d1d9)"
                    }),
                    #("border", case is_sel {
                      True -> "1px solid #39c5bb"
                      False -> "1px solid #30363d"
                    }),
                    #("font-weight", "600"),
                  ]),
                ],
                [text("y" <> int.to_string(pid))],
              )
            }),
          ),
        ],
      ),
      // Transport & Engine Timing Controls
      div(
        [
          styles([
            #("display", "flex"),
            #("flex-wrap", "wrap"),
            #("gap", "12px"),
            #("align-items", "center"),
            #("justify-content", "space-between"),
            #("background", "var(--bg-card, #161b22)"),
            #("border", "1px solid #30363d"),
            #("border-radius", "8px"),
            #("padding", "14px 16px"),
          ]),
        ],
        [
          // Playback state buttons: z1, z2, z0, zmu
          div(
            [
              styles([
                #("display", "flex"),
                #("gap", "8px"),
                #("align-items", "center"),
              ]),
            ],
            [
              button(
                [
                  on_click(SetPatternState(p.id, PatternRunning)),
                  type_("button"),
                  styles([
                    #("padding", "6px 14px"),
                    #("border-radius", "6px"),
                    #("cursor", "pointer"),
                    #("font-weight", "600"),
                    #("font-size", "13px"),
                    #("background", case p.state == PatternRunning {
                      True -> "#238636"
                      False -> "var(--bg-card-subtle, #21262d)"
                    }),
                    #("color", case p.state == PatternRunning {
                      True -> "#ffffff"
                      False -> "#3fb950"
                    }),
                    #("border", "1px solid #238636"),
                  ]),
                ],
                [text("▶ Run (z1)")],
              ),
              button(
                [
                  on_click(SetPatternState(p.id, PatternPaused)),
                  type_("button"),
                  styles([
                    #("padding", "6px 14px"),
                    #("border-radius", "6px"),
                    #("cursor", "pointer"),
                    #("font-weight", "600"),
                    #("font-size", "13px"),
                    #("background", case p.state == PatternPaused {
                      True -> "#d29922"
                      False -> "var(--bg-card-subtle, #21262d)"
                    }),
                    #("color", case p.state == PatternPaused {
                      True -> "#ffffff"
                      False -> "#d29922"
                    }),
                    #("border", "1px solid #d29922"),
                  ]),
                ],
                [text("⏸ Pause (z2)")],
              ),
              button(
                [
                  on_click(SetPatternState(p.id, PatternStopped)),
                  type_("button"),
                  styles([
                    #("padding", "6px 14px"),
                    #("border-radius", "6px"),
                    #("cursor", "pointer"),
                    #("font-weight", "600"),
                    #("font-size", "13px"),
                    #("background", case p.state == PatternStopped {
                      True -> "#f85149"
                      False -> "var(--bg-card-subtle, #21262d)"
                    }),
                    #("color", case p.state == PatternStopped {
                      True -> "#ffffff"
                      False -> "#f85149"
                    }),
                    #("border", "1px solid #f85149"),
                  ]),
                ],
                [text("⏹ Stop (z0)")],
              ),
              button(
                [
                  on_click(TogglePatternMute(p.id)),
                  type_("button"),
                  styles([
                    #("padding", "6px 12px"),
                    #("border-radius", "6px"),
                    #("cursor", "pointer"),
                    #("font-size", "13px"),
                    #("background", case p.mute {
                      True -> "#f8514922"
                      False -> "var(--bg-card-subtle, #21262d)"
                    }),
                    #("color", case p.mute {
                      True -> "#f85149"
                      False -> "var(--text-muted, #8b949e)"
                    }),
                    #("border", case p.mute {
                      True -> "1px solid #f85149"
                      False -> "1px solid #30363d"
                    }),
                  ]),
                ],
                [
                  text(case p.mute {
                    True -> "🔇 Muted (zmu1)"
                    False -> "🔊 Active (zmu0)"
                  }),
                ],
              ),
            ],
          ),
          // Clock speed divider & length
          div(
            [
              styles([
                #("display", "flex"),
                #("gap", "12px"),
                #("align-items", "center"),
              ]),
            ],
            [
              span(
                [
                  styles([
                    #("font-size", "12px"),
                    #("color", "var(--text-muted, #8b949e)"),
                  ]),
                ],
                [
                  text("Clock Div (%):"),
                ],
              ),
              div(
                [styles([#("display", "flex"), #("gap", "4px")])],
                list.map([1, 2, 4, 8, 16], fn(spd) {
                  let is_cur = p.speed == spd
                  button(
                    [
                      on_click(SetPatternSpeed(p.id, spd)),
                      type_("button"),
                      styles([
                        #("padding", "3px 8px"),
                        #("font-size", "11px"),
                        #("border-radius", "4px"),
                        #("cursor", "pointer"),
                        #("background", case is_cur {
                          True -> "#1f6feb"
                          False -> "var(--bg-card-subtle, #21262d)"
                        }),
                        #("color", case is_cur {
                          True -> "#ffffff"
                          False -> "var(--text-muted, #8b949e)"
                        }),
                        #("border", "1px solid #30363d"),
                      ]),
                    ],
                    [text("%" <> int.to_string(spd))],
                  )
                }),
              ),
              span(
                [
                  styles([
                    #("font-size", "12px"),
                    #("color", "var(--text-muted, #8b949e)"),
                    #("margin-left", "8px"),
                  ]),
                ],
                [text("Length: " <> int.to_string(p.length) <> " steps")],
              ),
            ],
          ),
        ],
      ),
      // 16-Step Visual Matrix Grid
      div(
        [
          styles([
            #("background", "var(--bg-card, #161b22)"),
            #("border", "1px solid #30363d"),
            #("border-radius", "8px"),
            #("padding", "16px"),
          ]),
        ],
        [
          div(
            [
              styles([
                #("display", "flex"),
                #("justify-content", "space-between"),
                #("align-items", "center"),
                #("margin-bottom", "12px"),
              ]),
            ],
            [
              div([], [
                div(
                  [
                    styles([
                      #("font-size", "13px"),
                      #("font-weight", "600"),
                      #("color", "var(--text-primary, #f0f6fc)"),
                      #("margin-bottom", "4px"),
                    ]),
                  ],
                  [
                    text(
                      "16-Step Trigger Matrix (Click step to edit / program)",
                    ),
                  ],
                ),
                div(
                  [
                    styles([
                      #("font-size", "11px"),
                      #("color", "var(--text-muted, #8b949e)"),
                      #("display", "flex"),
                      #("gap", "12px"),
                      #("flex-wrap", "wrap"),
                    ]),
                  ],
                  [
                    span([], [text("Highlights:")]),
                    span([styles([#("color", "#39c5bb")])], [
                      text("● Teal border = Programmed Step"),
                    ]),
                    span([styles([#("color", "#58a6ff")])], [
                      text("● Blue border = Selected / Editing"),
                    ]),
                    span([styles([#("color", "#8b949e")])], [
                      text(
                        "● Thick boundary = Quarter-Note Downbeat (1, 5, 9, 13)",
                      ),
                    ]),
                  ],
                ),
              ]),
              span(
                [
                  styles([
                    #("font-size", "12px"),
                    #("color", "var(--text-muted, #8b949e)"),
                  ]),
                ],
                [
                  text(int.to_string(dict.size(p.steps)) <> " steps programmed"),
                ],
              ),
            ],
          ),
          div(
            [
              styles([
                #("display", "grid"),
                #(
                  "grid-template-columns",
                  "repeat(auto-fill, minmax(105px, 1fr))",
                ),
                #("gap", "8px"),
              ]),
            ],
            list.map(
              [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
              fn(step_idx) {
                let is_downbeat = step_idx % 4 == 0
                let is_editing = model.step_edit_index == Some(step_idx)
                let maybe_code = dict.get(p.steps, step_idx)
                let has_code = case maybe_code {
                  Ok(_) -> True
                  Error(_) -> False
                }
                let code_str = case maybe_code {
                  Ok(c) -> c
                  Error(_) -> "—"
                }

                div(
                  [
                    styles([
                      #("display", "flex"),
                      #("flex-direction", "column"),
                      #("background", case is_editing {
                        True -> "#1f6feb22"
                        False ->
                          case has_code {
                            True -> "var(--bg-app, #0d1117)"
                            False -> "var(--bg-card, #161b22)"
                          }
                      }),
                      #("border", case is_editing {
                        True -> "2px solid #58a6ff"
                        False ->
                          case has_code {
                            True -> "1px solid #39c5bb88"
                            False ->
                              case is_downbeat {
                                True -> "1px solid #484f58"
                                False -> "1px solid #21262d"
                              }
                          }
                      }),
                      #("border-radius", "6px"),
                      #("padding", "8px"),
                      #("cursor", "pointer"),
                      #("transition", "all 0.15s ease"),
                    ]),
                    on_click(ToggleStepEdit(step_idx)),
                  ],
                  [
                    div(
                      [
                        styles([
                          #("display", "flex"),
                          #("justify-content", "space-between"),
                          #("align-items", "center"),
                          #("margin-bottom", "4px"),
                        ]),
                      ],
                      [
                        span(
                          [
                            styles([
                              #("font-family", "monospace"),
                              #("font-size", "11px"),
                              #("font-weight", "700"),
                              #("color", case is_downbeat {
                                True -> "var(--text-primary, #f0f6fc)"
                                False -> "var(--text-muted, #8b949e)"
                              }),
                            ]),
                          ],
                          [text("x" <> int.to_string(step_idx))],
                        ),
                        case has_code {
                          True ->
                            button(
                              [
                                on_click(ClearPatternStep(p.id, step_idx)),
                                type_("button"),
                                styles([
                                  #("background", "transparent"),
                                  #("border", "none"),
                                  #("color", "#f85149"),
                                  #("cursor", "pointer"),
                                  #("font-size", "12px"),
                                  #("padding", "0 2px"),
                                ]),
                              ],
                              [text("×")],
                            )
                          False -> element.none()
                        },
                      ],
                    ),
                    span(
                      [
                        styles([
                          #("font-family", "monospace"),
                          #("font-size", "11px"),
                          #("white-space", "nowrap"),
                          #("overflow", "hidden"),
                          #("text-overflow", "ellipsis"),
                          #("color", case has_code {
                            True -> "#7ee787"
                            False -> "#484f58"
                          }),
                        ]),
                      ],
                      [text(code_str)],
                    ),
                  ],
                )
              },
            ),
          ),
        ],
      ),
      // Step Edit Drawer (Modal-like card when editing a step)
      case model.step_edit_index {
        Some(step_idx) ->
          div(
            [
              styles([
                #("background", "var(--bg-app, #0d1117)"),
                #("border", "1px solid #1f6feb"),
                #("border-radius", "8px"),
                #("padding", "16px"),
              ]),
            ],
            [
              div(
                [
                  styles([
                    #("display", "flex"),
                    #("justify-content", "space-between"),
                    #("align-items", "center"),
                    #("margin-bottom", "10px"),
                  ]),
                ],
                [
                  span(
                    [
                      styles([
                        #("font-weight", "600"),
                        #("font-size", "14px"),
                        #("color", "#58a6ff"),
                      ]),
                    ],
                    [
                      text("Editing Step Payload: x" <> int.to_string(step_idx)),
                    ],
                  ),
                  button(
                    [
                      on_click(ToggleStepEdit(step_idx)),
                      type_("button"),
                      styles([
                        #("background", "transparent"),
                        #("border", "none"),
                        #("color", "var(--text-muted, #8b949e)"),
                        #("cursor", "pointer"),
                        #("font-size", "16px"),
                      ]),
                    ],
                    [text("×")],
                  ),
                ],
              ),
              // Step Code Input & Save
              form(
                [
                  on_submit(fn(_) { SubmitStepEdit(p.id) }),
                  styles([
                    #("display", "flex"),
                    #("gap", "8px"),
                    #("margin-bottom", "10px"),
                  ]),
                ],
                [
                  input([
                    type_("text"),
                    placeholder("e.g. v0 n60 T or v0 n48 a-3 T"),
                    value(model.step_edit_code),
                    on_input(SetStepEditCode),
                    styles([
                      #("flex", "1"),
                      #("padding", "8px 12px"),
                      #("background", "var(--bg-card, #161b22)"),
                      #("color", "var(--text-primary, #f0f6fc)"),
                      #("border", "1px solid #30363d"),
                      #("border-radius", "6px"),
                      #("font-family", "monospace"),
                      #("font-size", "13px"),
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
                      ]),
                    ],
                    [text("Save Step")],
                  ),
                ],
              ),
              // Quick payload templates
              div(
                [
                  styles([
                    #("display", "flex"),
                    #("gap", "6px"),
                    #("align-items", "center"),
                    #("flex-wrap", "wrap"),
                  ]),
                ],
                [
                  span(
                    [
                      styles([
                        #("font-size", "11px"),
                        #("color", "var(--text-muted, #8b949e)"),
                      ]),
                    ],
                    [text("Quick Snippets:")],
                  ),
                  ..list.map(
                    [
                      "v0 n36 T",
                      "v1 n42 T",
                      "v2 n38 T",
                      "v0 n60 T",
                      "v0 n63 T",
                      "v0 n67 T",
                      "v0 n72 T",
                      "d1 4 8",
                    ],
                    fn(snip) {
                      button(
                        [
                          on_click(SetStepEditCode(snip)),
                          type_("button"),
                          styles([
                            #("padding", "2px 8px"),
                            #("background", "var(--bg-card-subtle, #21262d)"),
                            #("color", "#79c0ff"),
                            #("border", "1px solid #30363d"),
                            #("border-radius", "4px"),
                            #("font-family", "monospace"),
                            #("font-size", "11px"),
                            #("cursor", "pointer"),
                          ]),
                        ],
                        [text(snip)],
                      )
                    },
                  )
                ],
              ),
            ],
          )
        None -> element.none()
      },
      // Pattern Presets & Canonical Skode Code
      div(
        [
          styles([
            #("display", "flex"),
            #("justify-content", "space-between"),
            #("align-items", "center"),
            #("flex-wrap", "wrap"),
            #("gap", "10px"),
          ]),
        ],
        [
          div(
            [
              styles([
                #("display", "flex"),
                #("gap", "8px"),
                #("align-items", "center"),
                #("flex-wrap", "wrap"),
              ]),
            ],
            [
              span(
                [
                  styles([
                    #("font-size", "12px"),
                    #("color", "var(--text-muted, #8b949e)"),
                  ]),
                ],
                [
                  text("Pattern Presets:"),
                ],
              ),
              button(
                [
                  on_click(ApplyPatternPreset(p.id, "4-on-the-Floor")),
                  styles([
                    #("padding", "4px 10px"),
                    #("background", "var(--bg-card-subtle, #21262d)"),
                    #("color", "var(--text-secondary, #c9d1d9)"),
                    #("border", "1px solid #30363d"),
                    #("border-radius", "14px"),
                    #("font-size", "12px"),
                    #("cursor", "pointer"),
                  ]),
                ],
                [text("4-on-the-Floor")],
              ),
              button(
                [
                  on_click(ApplyPatternPreset(p.id, "Acid Bassline")),
                  styles([
                    #("padding", "4px 10px"),
                    #("background", "var(--bg-card-subtle, #21262d)"),
                    #("color", "var(--text-secondary, #c9d1d9)"),
                    #("border", "1px solid #30363d"),
                    #("border-radius", "14px"),
                    #("font-size", "12px"),
                    #("cursor", "pointer"),
                  ]),
                ],
                [text("Acid Bassline")],
              ),
              button(
                [
                  on_click(ApplyPatternPreset(p.id, "Polyrhythm")),
                  styles([
                    #("padding", "4px 10px"),
                    #("background", "var(--bg-card-subtle, #21262d)"),
                    #("color", "var(--text-secondary, #c9d1d9)"),
                    #("border", "1px solid #30363d"),
                    #("border-radius", "14px"),
                    #("font-size", "12px"),
                    #("cursor", "pointer"),
                  ]),
                ],
                [text("Polyrhythm")],
              ),
            ],
          ),
          button(
            [
              on_click(CopyCustomText(pat_skode)),
              type_("button"),
              styles([
                #("padding", "6px 14px"),
                #("background", "var(--border, #30363d)"),
                #("color", "var(--text-primary, #f0f6fc)"),
                #("border", "1px solid #484f58"),
                #("border-radius", "6px"),
                #("font-size", "12px"),
                #("cursor", "pointer"),
              ]),
            ],
            [text("Copy Pattern Skode")],
          ),
        ],
      ),
      // Live Pattern Skode Preview
      div(
        [
          styles([
            #("background", "var(--bg-app, #0d1117)"),
            #("border", "1px solid #30363d"),
            #("border-radius", "6px"),
            #("padding", "12px"),
          ]),
        ],
        [
          span(
            [
              styles([
                #("font-size", "11px"),
                #("text-transform", "uppercase"),
                #("letter-spacing", "0.5px"),
                #("color", "var(--text-muted, #8b949e)"),
                #("display", "block"),
                #("margin-bottom", "6px"),
              ]),
            ],
            [text("Compiled Pattern Skode (Pulp Sequencer Engine)")],
          ),
          pre(
            [
              styles([
                #("font-family", "monospace"),
                #("font-size", "13px"),
                #("color", "#7ee787"),
                #("margin", "0"),
                #("white-space", "pre-wrap"),
              ]),
            ],
            [text(pat_skode)],
          ),
        ],
      ),
    ],
  )
}

fn render_delay_matrix(model: Model) -> Element(Msg) {
  let bus = get_delay_bus(model.engine_settings, model.active_delay_id)
  let live_ms = delay.delay_time_ms(bus.coarse, bus.fine)
  let fb_pct = delay.feedback_gain(bus.feedback) *. 100.0
  let delay_skode = delay.to_skode(bus)

  div(
    [
      styles([
        #("display", "flex"),
        #("flex-direction", "column"),
        #("gap", "18px"),
      ]),
    ],
    [
      // Bus Selector Tabs: d1, d2, d3, d4
      div(
        [
          styles([
            #("display", "flex"),
            #("justify-content", "space-between"),
            #("align-items", "center"),
            #("background", "var(--bg-card, #161b22)"),
            #("border", "1px solid #30363d"),
            #("border-radius", "8px"),
            #("padding", "12px 16px"),
          ]),
        ],
        [
          span(
            [
              styles([
                #("font-size", "15px"),
                #("font-weight", "700"),
                #("color", "#d29922"),
              ]),
            ],
            [text("4-Bus Delay Matrix (Pulp parts/synth-delay.c)")],
          ),
          div(
            [styles([#("display", "flex"), #("gap", "8px")])],
            list.map([1, 2, 3, 4], fn(bid) {
              let is_sel = bid == bus.id
              button(
                [
                  on_click(SetDelayBusId(bid)),
                  type_("button"),
                  styles([
                    #("padding", "6px 14px"),
                    #("font-family", "monospace"),
                    #("font-size", "13px"),
                    #("font-weight", "600"),
                    #("border-radius", "6px"),
                    #("cursor", "pointer"),
                    #("background", case is_sel {
                      True -> "#d29922"
                      False -> "var(--bg-card-subtle, #21262d)"
                    }),
                    #("color", case is_sel {
                      True -> "var(--bg-app, #0d1117)"
                      False -> "var(--text-secondary, #c9d1d9)"
                    }),
                    #("border", case is_sel {
                      True -> "1px solid #d29922"
                      False -> "1px solid #30363d"
                    }),
                  ]),
                ],
                [text("Bus d" <> int.to_string(bid))],
              )
            }),
          ),
        ],
      ),
      // Calculated Live Telemetry Banner
      div(
        [
          styles([
            #("display", "grid"),
            #("grid-template-columns", "repeat(auto-fit, minmax(200px, 1fr))"),
            #("gap", "12px"),
            #("background", "var(--bg-card, #161b22)"),
            #("border", "1px solid #30363d"),
            #("border-radius", "8px"),
            #("padding", "16px"),
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
                  #("color", "var(--text-muted, #8b949e)"),
                  #("display", "block"),
                  #("margin-bottom", "4px"),
                ]),
              ],
              [text("Delay Time (Calculated)")],
            ),
            span(
              [
                styles([
                  #("font-size", "22px"),
                  #("font-weight", "700"),
                  #("color", "#d29922"),
                  #("font-family", "monospace"),
                ]),
              ],
              [text(param.format_float(live_ms) <> " ms")],
            ),
          ]),
          div([], [
            span(
              [
                styles([
                  #("font-size", "11px"),
                  #("text-transform", "uppercase"),
                  #("letter-spacing", "0.5px"),
                  #("color", "var(--text-muted, #8b949e)"),
                  #("display", "block"),
                  #("margin-bottom", "4px"),
                ]),
              ],
              [text("Feedback Gain")],
            ),
            span(
              [
                styles([
                  #("font-size", "22px"),
                  #("font-weight", "700"),
                  #("color", "#58a6ff"),
                  #("font-family", "monospace"),
                ]),
              ],
              [text(param.format_float(fb_pct) <> "%")],
            ),
          ]),
          div([], [
            span(
              [
                styles([
                  #("font-size", "11px"),
                  #("text-transform", "uppercase"),
                  #("letter-spacing", "0.5px"),
                  #("color", "var(--text-muted, #8b949e)"),
                  #("display", "block"),
                  #("margin-bottom", "4px"),
                ]),
              ],
              [text("Grit / Digital Format")],
            ),
            span(
              [
                styles([
                  #("font-size", "16px"),
                  #("font-weight", "600"),
                  #("color", "#7ee787"),
                ]),
              ],
              [
                text(case bus.grit {
                  NativeFloat -> "32-Bit Float"
                  Quantized(bits) -> int.to_string(bits) <> "-Bit Vintage"
                }),
              ],
            ),
          ]),
        ],
      ),
      // Sliders Matrix (2 Columns)
      div(
        [
          styles([
            #("display", "grid"),
            #("grid-template-columns", "repeat(auto-fit, minmax(320px, 1fr))"),
            #("gap", "16px"),
            #("background", "var(--bg-card, #161b22)"),
            #("border", "1px solid #30363d"),
            #("border-radius", "8px"),
            #("padding", "20px"),
          ]),
        ],
        [
          // Column 1: Time, Feedback, Damping, Highpass
          div([], [
            int_slider_row(
              "Coarse Time (8ms * 2^c)",
              bus.coarse,
              0,
              7,
              "/ 7 bucket",
              fn(v) { UpdateDelayCoarse(bus.id, v) },
            ),
            int_slider_row(
              "Fine Time Multiplier (0.5..1.0)",
              bus.fine,
              0,
              15,
              "/ 15 fine",
              fn(v) { UpdateDelayFine(bus.id, v) },
            ),
            int_slider_row(
              "Feedback Gain (0.0 .. 0.82)",
              bus.feedback,
              0,
              15,
              "/ 15 gain",
              fn(v) { UpdateDelayFeedback(bus.id, v) },
            ),
            int_slider_row(
              "Feedback Damping (HF Tone Rolloff)",
              bus.damping,
              0,
              15,
              "/ 15 (0=bright, 15=dark)",
              fn(v) { UpdateDelayDamping(bus.id, v) },
            ),
          ]),
          // Column 2: Highpass, LFO Mod, Level
          div([], [
            int_slider_row(
              "Feedback Highpass (LF Rumble Cut)",
              bus.highpass,
              0,
              15,
              "/ 15 (0=flat, 15=thin)",
              fn(v) { UpdateDelayHighpass(bus.id, v) },
            ),
            int_slider_row(
              "LFO Modulation Rate (0..10 Hz)",
              bus.mod_freq,
              0,
              31,
              "/ 31 rate",
              fn(v) { UpdateDelayModFreq(bus.id, v) },
            ),
            int_slider_row(
              "LFO Modulation Depth",
              bus.mod_depth,
              0,
              31,
              "/ 31 depth",
              fn(v) { UpdateDelayModDepth(bus.id, v) },
            ),
            int_slider_row(
              "Delay Wet Mix Level",
              bus.level,
              0,
              15,
              "/ 15 wet",
              fn(v) { UpdateDelayLevel(bus.id, v) },
            ),
          ]),
        ],
      ),
      // Toggles & Grit Selection
      div(
        [
          styles([
            #("display", "flex"),
            #("flex-wrap", "wrap"),
            #("gap", "12px"),
            #("align-items", "center"),
            #("background", "var(--bg-card, #161b22)"),
            #("border", "1px solid #30363d"),
            #("border-radius", "8px"),
            #("padding", "14px 16px"),
          ]),
        ],
        [
          button(
            [
              on_click(UpdateDelayPingPong(bus.id, !bus.pingpong)),
              type_("button"),
              styles([
                #("padding", "6px 14px"),
                #("border-radius", "6px"),
                #("cursor", "pointer"),
                #("font-size", "13px"),
                #("background", case bus.pingpong {
                  True -> "#1f6feb22"
                  False -> "var(--bg-card-subtle, #21262d)"
                }),
                #("color", case bus.pingpong {
                  True -> "#58a6ff"
                  False -> "var(--text-muted, #8b949e)"
                }),
                #("border", case bus.pingpong {
                  True -> "1px solid #1f6feb"
                  False -> "1px solid #30363d"
                }),
              ]),
            ],
            [
              text(case bus.pingpong {
                True -> "🔀 Stereo Ping-Pong: ON"
                False -> "➡️ Stereo Ping-Pong: OFF"
              }),
            ],
          ),
          button(
            [
              on_click(UpdateDelayFreeze(bus.id, !bus.freeze)),
              type_("button"),
              styles([
                #("padding", "6px 14px"),
                #("border-radius", "6px"),
                #("cursor", "pointer"),
                #("font-size", "13px"),
                #("background", case bus.freeze {
                  True -> "#8957e522"
                  False -> "var(--bg-card-subtle, #21262d)"
                }),
                #("color", case bus.freeze {
                  True -> "#bc8cff"
                  False -> "var(--text-muted, #8b949e)"
                }),
                #("border", case bus.freeze {
                  True -> "1px solid #8957e5"
                  False -> "1px solid #30363d"
                }),
              ]),
            ],
            [
              text(case bus.freeze {
                True -> "❄️ Infinite Freeze: HELD"
                False -> "💧 Infinite Freeze: PASS"
              }),
            ],
          ),
          span(
            [
              styles([
                #("font-size", "12px"),
                #("color", "var(--text-muted, #8b949e)"),
                #("margin-left", "8px"),
              ]),
            ],
            [text("Grit Bit Depth:")],
          ),
          button(
            [
              on_click(UpdateDelayGrit(bus.id, NativeFloat)),
              type_("button"),
              styles([
                #("padding", "4px 10px"),
                #("border-radius", "4px"),
                #("cursor", "pointer"),
                #("font-size", "12px"),
                #("background", case bus.grit == NativeFloat {
                  True -> "#238636"
                  False -> "var(--bg-card-subtle, #21262d)"
                }),
                #("color", case bus.grit == NativeFloat {
                  True -> "#ffffff"
                  False -> "var(--text-secondary, #c9d1d9)"
                }),
                #("border", "1px solid #30363d"),
              ]),
            ],
            [text("32-bit Float")],
          ),
          button(
            [
              on_click(UpdateDelayGrit(bus.id, Quantized(12))),
              type_("button"),
              styles([
                #("padding", "4px 10px"),
                #("border-radius", "4px"),
                #("cursor", "pointer"),
                #("font-size", "12px"),
                #("background", case bus.grit == Quantized(12) {
                  True -> "#1f6feb"
                  False -> "var(--bg-card-subtle, #21262d)"
                }),
                #("color", case bus.grit == Quantized(12) {
                  True -> "#ffffff"
                  False -> "var(--text-secondary, #c9d1d9)"
                }),
                #("border", "1px solid #30363d"),
              ]),
            ],
            [text("12-bit Vintage")],
          ),
          button(
            [
              on_click(UpdateDelayGrit(bus.id, Quantized(8))),
              type_("button"),
              styles([
                #("padding", "4px 10px"),
                #("border-radius", "4px"),
                #("cursor", "pointer"),
                #("font-size", "12px"),
                #("background", case bus.grit == Quantized(8) {
                  True -> "#d29922"
                  False -> "var(--bg-card-subtle, #21262d)"
                }),
                #("color", case bus.grit == Quantized(8) {
                  True -> "#ffffff"
                  False -> "var(--text-secondary, #c9d1d9)"
                }),
                #("border", "1px solid #30363d"),
              ]),
            ],
            [text("8-bit Lo-Fi")],
          ),
        ],
      ),
      // Presets & Live Pre Block
      div(
        [
          styles([
            #("display", "flex"),
            #("justify-content", "space-between"),
            #("align-items", "center"),
            #("flex-wrap", "wrap"),
            #("gap", "10px"),
          ]),
        ],
        [
          div(
            [
              styles([
                #("display", "flex"),
                #("gap", "8px"),
                #("align-items", "center"),
                #("flex-wrap", "wrap"),
              ]),
            ],
            [
              span(
                [
                  styles([
                    #("font-size", "12px"),
                    #("color", "var(--text-muted, #8b949e)"),
                  ]),
                ],
                [
                  text("Delay Presets:"),
                ],
              ),
              button(
                [
                  on_click(ApplyDelayPreset(bus.id, "Dub Space Echo")),
                  styles([
                    #("padding", "4px 10px"),
                    #("background", "var(--bg-card-subtle, #21262d)"),
                    #("color", "var(--text-secondary, #c9d1d9)"),
                    #("border", "1px solid #30363d"),
                    #("border-radius", "14px"),
                    #("font-size", "12px"),
                    #("cursor", "pointer"),
                  ]),
                ],
                [text("Dub Space Echo")],
              ),
              button(
                [
                  on_click(ApplyDelayPreset(bus.id, "Tape Chorus")),
                  styles([
                    #("padding", "4px 10px"),
                    #("background", "var(--bg-card-subtle, #21262d)"),
                    #("color", "var(--text-secondary, #c9d1d9)"),
                    #("border", "1px solid #30363d"),
                    #("border-radius", "14px"),
                    #("font-size", "12px"),
                    #("cursor", "pointer"),
                  ]),
                ],
                [text("Tape Chorus")],
              ),
              button(
                [
                  on_click(ApplyDelayPreset(bus.id, "Slapback")),
                  styles([
                    #("padding", "4px 10px"),
                    #("background", "var(--bg-card-subtle, #21262d)"),
                    #("color", "var(--text-secondary, #c9d1d9)"),
                    #("border", "1px solid #30363d"),
                    #("border-radius", "14px"),
                    #("font-size", "12px"),
                    #("cursor", "pointer"),
                  ]),
                ],
                [text("Slapback")],
              ),
              button(
                [
                  on_click(ApplyDelayPreset(bus.id, "Infinite Freeze")),
                  styles([
                    #("padding", "4px 10px"),
                    #("background", "var(--bg-card-subtle, #21262d)"),
                    #("color", "var(--text-secondary, #c9d1d9)"),
                    #("border", "1px solid #30363d"),
                    #("border-radius", "14px"),
                    #("font-size", "12px"),
                    #("cursor", "pointer"),
                  ]),
                ],
                [text("Infinite Freeze")],
              ),
            ],
          ),
          button(
            [
              on_click(CopyCustomText(delay_skode)),
              type_("button"),
              styles([
                #("padding", "6px 14px"),
                #("background", "var(--border, #30363d)"),
                #("color", "var(--text-primary, #f0f6fc)"),
                #("border", "1px solid #484f58"),
                #("border-radius", "6px"),
                #("font-size", "12px"),
                #("cursor", "pointer"),
              ]),
            ],
            [text("Copy Delay Skode")],
          ),
        ],
      ),
      // Live Delay Skode Preview
      div(
        [
          styles([
            #("background", "var(--bg-app, #0d1117)"),
            #("border", "1px solid #30363d"),
            #("border-radius", "6px"),
            #("padding", "12px"),
          ]),
        ],
        [
          span(
            [
              styles([
                #("font-size", "11px"),
                #("text-transform", "uppercase"),
                #("letter-spacing", "0.5px"),
                #("color", "var(--text-muted, #8b949e)"),
                #("display", "block"),
                #("margin-bottom", "6px"),
              ]),
            ],
            [text("Compiled Delay Bus Skode Command")],
          ),
          pre(
            [
              styles([
                #("font-family", "monospace"),
                #("font-size", "14px"),
                #("color", "#7ee787"),
                #("margin", "0"),
              ]),
            ],
            [text(delay_skode)],
          ),
        ],
      ),
    ],
  )
}

fn render_macro_studio(model: Model) -> Element(Msg) {
  div(
    [
      styles([
        #("display", "flex"),
        #("flex-direction", "column"),
        #("gap", "18px"),
      ]),
    ],
    [
      // 1. Header & Global Actions Bar
      div(
        [
          styles([
            #("background", "var(--bg-card, #161b22)"),
            #("border", "1px solid #30363d"),
            #("border-radius", "8px"),
            #("padding", "16px"),
            #("display", "flex"),
            #("justify-content", "space-between"),
            #("align-items", "center"),
            #("flex-wrap", "wrap"),
            #("gap", "12px"),
          ]),
        ],
        [
          div(
            [
              styles([
                #("display", "flex"),
                #("flex-direction", "column"),
                #("gap", "4px"),
              ]),
            ],
            [
              div(
                [
                  styles([
                    #("display", "flex"),
                    #("align-items", "center"),
                    #("gap", "8px"),
                  ]),
                ],
                [
                  span(
                    [
                      styles([
                        #("font-size", "16px"),
                        #("font-weight", "700"),
                        #("color", "var(--text-primary, #f0f6fc)"),
                      ]),
                    ],
                    [text("🔴 Macro Trigger Pad (e!0 .. e!15)")],
                  ),
                  span(
                    [
                      styles([
                        #("background", "rgba(56, 139, 253, 0.15)"),
                        #("color", "#58a6ff"),
                        #("font-size", "11px"),
                        #("font-weight", "600"),
                        #("padding", "2px 8px"),
                        #("border-radius", "10px"),
                      ]),
                    ],
                    [text("16 Hardware-Style Macro Slots")],
                  ),
                ],
              ),
              span(
                [
                  styles([
                    #("font-size", "12px"),
                    #("color", "var(--text-muted, #8b949e)"),
                  ]),
                ],
                [
                  text(
                    "Store Skode programs into memory slots with [code] e><slot>, and execute them with 1-click using e!<slot>.",
                  ),
                ],
              ),
            ],
          ),
          div([styles([#("display", "flex"), #("gap", "8px")])], [
            button(
              [
                on_click(QueryAllMacros),
                type_("button"),
                styles([
                  #("padding", "6px 12px"),
                  #("background", "var(--bg-card-subtle, #21262d)"),
                  #("color", "#58a6ff"),
                  #("border", "1px solid #30363d"),
                  #("border-radius", "6px"),
                  #("font-size", "12px"),
                  #("font-weight", "600"),
                  #("cursor", "pointer"),
                ]),
              ],
              [text("?m (List All Macros)")],
            ),
            button(
              [
                on_click(ClearAllMacros),
                type_("button"),
                styles([
                  #("padding", "6px 12px"),
                  #("background", "var(--bg-card-subtle, #21262d)"),
                  #("color", "#f85149"),
                  #("border", "1px solid #30363d"),
                  #("border-radius", "6px"),
                  #("font-size", "12px"),
                  #("font-weight", "600"),
                  #("cursor", "pointer"),
                ]),
              ],
              [text("/m! (Clear All)")],
            ),
          ]),
        ],
      ),
      // 2. 4x4 Macro Trigger Grid (e!0 .. e!15)
      div(
        [
          styles([
            #("background", "var(--bg-card, #161b22)"),
            #("border", "1px solid #30363d"),
            #("border-radius", "8px"),
            #("padding", "16px"),
          ]),
        ],
        [
          div(
            [
              styles([
                #("display", "flex"),
                #("justify-content", "space-between"),
                #("align-items", "center"),
                #("margin-bottom", "14px"),
                #("padding-bottom", "8px"),
                #("border-bottom", "1px solid #21262d"),
              ]),
            ],
            [
              span(
                [
                  styles([
                    #("font-size", "13px"),
                    #("font-weight", "700"),
                    #("color", "var(--text-primary, #f0f6fc)"),
                  ]),
                ],
                [
                  text(
                    "4×4 Trigger Pad Grid — Tap any pad to fire e!<slot> immediately",
                  ),
                ],
              ),
              span(
                [
                  styles([
                    #("font-size", "11px"),
                    #("color", "var(--text-muted, #8b949e)"),
                  ]),
                ],
                [
                  text(
                    "Active Editor Slot: e!" <> int.to_string(model.macro_slot),
                  ),
                ],
              ),
            ],
          ),
          div(
            [
              styles([
                #("display", "grid"),
                #("grid-template-columns", "repeat(4, 1fr)"),
                #("gap", "12px"),
              ]),
            ],
            list.map(model.macros, fn(entry) {
              let #(slot, code) = entry
              let is_active = model.macro_slot == slot
              let has_code = string.trim(code) != ""
              div(
                [
                  styles([
                    #("background", case is_active {
                      True -> "#1c2128"
                      False -> "var(--bg-app, #0d1117)"
                    }),
                    #("border", case is_active {
                      True -> "2px solid #58a6ff"
                      False ->
                        case has_code {
                          True -> "1px solid #30363d"
                          False -> "1px dashed #21262d"
                        }
                    }),
                    #("border-radius", "8px"),
                    #("padding", "12px"),
                    #("display", "flex"),
                    #("flex-direction", "column"),
                    #("justify-content", "space-between"),
                    #("gap", "8px"),
                    #("min-height", "110px"),
                    #("transition", "all 0.15s ease"),
                  ]),
                ],
                [
                  // Pad Header
                  div(
                    [
                      styles([
                        #("display", "flex"),
                        #("justify-content", "space-between"),
                        #("align-items", "center"),
                      ]),
                    ],
                    [
                      span(
                        [
                          styles([
                            #("font-family", "monospace"),
                            #("font-weight", "bold"),
                            #("font-size", "13px"),
                            #("color", case is_active {
                              True -> "#58a6ff"
                              False -> "var(--text-primary, #f0f6fc)"
                            }),
                          ]),
                        ],
                        [text("e!" <> int.to_string(slot))],
                      ),
                      div([styles([#("display", "flex"), #("gap", "4px")])], [
                        button(
                          [
                            on_click(SetMacroSlot(slot)),
                            type_("button"),
                            styles([
                              #("padding", "1px 6px"),
                              #("background", "var(--bg-card-subtle, #21262d)"),
                              #("color", "var(--text-muted, #8b949e)"),
                              #("border", "1px solid #30363d"),
                              #("border-radius", "4px"),
                              #("font-size", "10px"),
                              #("cursor", "pointer"),
                            ]),
                          ],
                          [text("✎ Edit")],
                        ),
                        button(
                          [
                            on_click(QueryMacro(slot)),
                            type_("button"),
                            styles([
                              #("padding", "1px 6px"),
                              #("background", "var(--bg-card-subtle, #21262d)"),
                              #("color", "var(--text-muted, #8b949e)"),
                              #("border", "1px solid #30363d"),
                              #("border-radius", "4px"),
                              #("font-size", "10px"),
                              #("cursor", "pointer"),
                            ]),
                          ],
                          [text("e?")],
                        ),
                      ]),
                    ],
                  ),
                  // Stored Code preview
                  div(
                    [
                      styles([
                        #("font-family", "monospace"),
                        #("font-size", "11px"),
                        #("color", case has_code {
                          True -> "#7ee787"
                          False -> "#484f58"
                        }),
                        #("background", "var(--bg-card, #161b22)"),
                        #("padding", "4px 8px"),
                        #("border-radius", "4px"),
                        #("overflow", "hidden"),
                        #("text-overflow", "ellipsis"),
                        #("white-space", "nowrap"),
                      ]),
                    ],
                    [
                      text(case has_code {
                        True -> code
                        False -> "(empty slot)"
                      }),
                    ],
                  ),
                  // Big Trigger Button
                  button(
                    [
                      on_click(ExecMacro(slot)),
                      type_("button"),
                      styles([
                        #("width", "100%"),
                        #("padding", "7px 10px"),
                        #("background", case has_code {
                          True -> "#238636"
                          False -> "var(--bg-card-subtle, #21262d)"
                        }),
                        #("color", case has_code {
                          True -> "#ffffff"
                          False -> "var(--text-muted, #8b949e)"
                        }),
                        #("border", "none"),
                        #("border-radius", "6px"),
                        #("font-size", "12px"),
                        #("font-weight", "bold"),
                        #("cursor", "pointer"),
                        #("display", "flex"),
                        #("align-items", "center"),
                        #("justify-content", "center"),
                        #("gap", "4px"),
                      ]),
                    ],
                    [text("▶ FIRE e!" <> int.to_string(slot))],
                  ),
                ],
              )
            }),
          ),
        ],
      ),
      // 3. Macro Composer & Slot Storer ([code] e>slot)
      div(
        [
          styles([
            #("background", "var(--bg-card, #161b22)"),
            #("border", "1px solid #30363d"),
            #("border-radius", "8px"),
            #("padding", "16px"),
          ]),
        ],
        [
          div(
            [
              styles([
                #("display", "flex"),
                #("justify-content", "space-between"),
                #("align-items", "center"),
                #("margin-bottom", "12px"),
              ]),
            ],
            [
              div(
                [
                  styles([
                    #("display", "flex"),
                    #("align-items", "center"),
                    #("gap", "8px"),
                  ]),
                ],
                [
                  span(
                    [
                      styles([
                        #("font-size", "14px"),
                        #("font-weight", "700"),
                        #("color", "var(--text-primary, #f0f6fc)"),
                      ]),
                    ],
                    [
                      text(
                        "Macro Composer • Save into Slot e>"
                        <> int.to_string(model.macro_slot),
                      ),
                    ],
                  ),
                  span(
                    [
                      styles([
                        #("font-size", "11px"),
                        #("color", "var(--text-muted, #8b949e)"),
                      ]),
                    ],
                    [
                      text(
                        "Stores bracketed Skode command: [program] e>"
                        <> int.to_string(model.macro_slot),
                      ),
                    ],
                  ),
                ],
              ),
              div(
                [
                  styles([
                    #("display", "flex"),
                    #("align-items", "center"),
                    #("gap", "6px"),
                  ]),
                ],
                [
                  span(
                    [
                      styles([
                        #("font-size", "12px"),
                        #("color", "var(--text-muted, #8b949e)"),
                      ]),
                    ],
                    [text("Target Slot:")],
                  ),
                  select(
                    [
                      on_change(fn(s) { SetMacroSlot(parse_int(s, 0)) }),
                      value(int.to_string(model.macro_slot)),
                      styles([
                        #("padding", "4px 8px"),
                        #("background", "var(--bg-card-subtle, #21262d)"),
                        #("color", "#58a6ff"),
                        #("border", "1px solid #30363d"),
                        #("border-radius", "4px"),
                        #("font-family", "monospace"),
                        #("font-weight", "bold"),
                      ]),
                    ],
                    list.map(
                      [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
                      fn(id) {
                        option(
                          [value(int.to_string(id))],
                          "Slot " <> int.to_string(id),
                        )
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
          // Composer Input form
          div(
            [
              styles([
                #("display", "flex"),
                #("gap", "8px"),
                #("margin-bottom", "12px"),
              ]),
            ],
            [
              input([
                type_("text"),
                placeholder("e.g. v0 n 60 T v1 n 64 T v2 n 67 T"),
                value(model.macro_input),
                on_input(SetMacroInput),
                styles([
                  #("flex", "1"),
                  #("padding", "10px 14px"),
                  #("background", "var(--bg-app, #0d1117)"),
                  #("color", "var(--text-primary, #f0f6fc)"),
                  #("border", "1px solid #30363d"),
                  #("border-radius", "6px"),
                  #("font-family", "monospace"),
                  #("font-size", "14px"),
                ]),
              ]),
              button(
                [
                  on_click(StoreMacro(model.macro_slot, model.macro_input)),
                  type_("button"),
                  styles([
                    #("padding", "10px 16px"),
                    #("background", "#8957e5"),
                    #("color", "#ffffff"),
                    #("border", "none"),
                    #("border-radius", "6px"),
                    #("font-weight", "600"),
                    #("cursor", "pointer"),
                    #("white-space", "nowrap"),
                  ]),
                ],
                [
                  text(
                    "Save ([code] e>" <> int.to_string(model.macro_slot) <> ")",
                  ),
                ],
              ),
              button(
                [
                  on_click(ExecMacro(model.macro_slot)),
                  type_("button"),
                  styles([
                    #("padding", "10px 16px"),
                    #("background", "#238636"),
                    #("color", "#ffffff"),
                    #("border", "none"),
                    #("border-radius", "6px"),
                    #("font-weight", "600"),
                    #("cursor", "pointer"),
                    #("white-space", "nowrap"),
                  ]),
                ],
                [text("Run e!" <> int.to_string(model.macro_slot))],
              ),
              button(
                [
                  on_click(QueryMacro(model.macro_slot)),
                  type_("button"),
                  styles([
                    #("padding", "10px 12px"),
                    #("background", "var(--bg-card-subtle, #21262d)"),
                    #("color", "var(--text-muted, #8b949e)"),
                    #("border", "1px solid #30363d"),
                    #("border-radius", "6px"),
                    #("font-weight", "600"),
                    #("cursor", "pointer"),
                  ]),
                ],
                [text("e? " <> int.to_string(model.macro_slot))],
              ),
            ],
          ),
          // Starter Presets
          div(
            [
              styles([
                #("display", "flex"),
                #("gap", "6px"),
                #("align-items", "center"),
                #("flex-wrap", "wrap"),
              ]),
            ],
            [
              span(
                [
                  styles([
                    #("font-size", "11px"),
                    #("color", "var(--text-muted, #8b949e)"),
                  ]),
                ],
                [
                  text("Preset Ideas:"),
                ],
              ),
              ..list.map(
                [
                  #("Major Triad", "v0 n 60 T v1 n 64 T v2 n 67 T"),
                  #("Minor 7th", "v0 n 60 T v1 n 63 T v2 n 67 T v3 n 70 T"),
                  #("Synth Bass", "v0 w 1 f 110 c 800 q 0.8 a -4 T"),
                  #("Kick + Sub", "v0 w 0 f 60 a 0 T v1 w 4 f 120 a -3 T"),
                  #("Snare Layer", "v2 w 4 f 1800 c 4000 q 0.7 a -2 T"),
                  #("Hi-Hat", "v3 w 4 c 9000 q 0.9 a -6 T"),
                  #("Reset Voices", "v0 reset v1 reset v2 reset v3 reset"),
                ],
                fn(preset) {
                  let #(name, code) = preset
                  button(
                    [
                      on_click(SetMacroInput(code)),
                      type_("button"),
                      styles([
                        #("padding", "3px 8px"),
                        #("background", "var(--bg-card-subtle, #21262d)"),
                        #("color", "#58a6ff"),
                        #("border", "1px solid #30363d"),
                        #("border-radius", "4px"),
                        #("font-size", "11px"),
                        #("cursor", "pointer"),
                      ]),
                    ],
                    [text(name)],
                  )
                },
              )
            ],
          ),
        ],
      ),
    ],
  )
}

fn render_ksynth_studio(model: Model) -> Element(Msg) {
  div(
    [
      styles([
        #("display", "flex"),
        #("flex-direction", "column"),
        #("gap", "18px"),
      ]),
    ],
    [
      // KSynth Scratchpad
      div(
        [
          styles([
            #("background", "var(--bg-card, #161b22)"),
            #("border", "1px solid #30363d"),
            #("border-radius", "8px"),
            #("padding", "16px"),
          ]),
        ],
        [
          div(
            [
              styles([
                #("display", "flex"),
                #("justify-content", "space-between"),
                #("align-items", "center"),
                #("flex-wrap", "wrap"),
                #("gap", "8px"),
                #("margin-bottom", "12px"),
              ]),
            ],
            [
              div(
                [
                  styles([
                    #("display", "flex"),
                    #("align-items", "center"),
                    #("gap", "8px"),
                  ]),
                ],
                [
                  span(
                    [
                      styles([
                        #("font-size", "15px"),
                        #("font-weight", "700"),
                        #("color", "#bc8cff"),
                      ]),
                    ],
                    [
                      text(
                        "k/synth Array-Oriented Vector Synthesis (octetta/k-synth)",
                      ),
                    ],
                  ),
                  span(
                    [
                      styles([
                        #("background", "rgba(188, 140, 255, 0.15)"),
                        #("color", "#bc8cff"),
                        #("font-size", "10px"),
                        #("font-weight", "600"),
                        #("padding", "2px 8px"),
                        #("border-radius", "10px"),
                      ]),
                    ],
                    [text("K/Simple Lineage")],
                  ),
                ],
              ),
              span(
                [
                  styles([
                    #("font-size", "12px"),
                    #("color", "var(--text-muted, #8b949e)"),
                  ]),
                ],
                [
                  text(
                    "Evaluates K vector expressions via [code] ks • ks & k! are identical",
                  ),
                ],
              ),
            ],
          ),
          // Formula Input
          form(
            [
              on_submit(fn(_) { SubmitKSynthEval }),
              styles([
                #("display", "flex"),
                #("gap", "8px"),
                #("margin-bottom", "12px"),
                #("flex-wrap", "wrap"),
              ]),
            ],
            [
              input([
                type_("text"),
                placeholder("e.g. w s +\\(44100#220*(6.28318%44100))"),
                value(model.ksynth_input),
                on_input(SetKSynthInput),
                styles([
                  #("flex", "1 1 300px"),
                  #("padding", "10px 14px"),
                  #("background", "var(--bg-app, #0d1117)"),
                  #("color", "var(--text-primary, #f0f6fc)"),
                  #("border", "1px solid #30363d"),
                  #("border-radius", "6px"),
                  #("font-family", "monospace"),
                  #("font-size", "14px"),
                ]),
              ]),
              button(
                [
                  type_("submit"),
                  styles([
                    #("padding", "10px 16px"),
                    #("background", "#8957e5"),
                    #("color", "#ffffff"),
                    #("border", "none"),
                    #("border-radius", "6px"),
                    #("font-weight", "600"),
                    #("cursor", "pointer"),
                    #("white-space", "nowrap"),
                  ]),
                ],
                [text("[expr] ks (Evaluate)")],
              ),
              button(
                [
                  on_click(SubmitKSynthQuery),
                  type_("button"),
                  styles([
                    #("padding", "10px 14px"),
                    #("background", "var(--bg-card-subtle, #21262d)"),
                    #("color", "#58a6ff"),
                    #("border", "1px solid #30363d"),
                    #("border-radius", "6px"),
                    #("font-weight", "600"),
                    #("cursor", "pointer"),
                    #("white-space", "nowrap"),
                  ]),
                ],
                [text("k? (Inspect Result)")],
              ),
              button(
                [
                  on_click(SubmitKSynthToData),
                  type_("button"),
                  styles([
                    #("padding", "10px 14px"),
                    #("background", "var(--bg-card-subtle, #21262d)"),
                    #("color", "#3fb950"),
                    #("border", "1px solid #30363d"),
                    #("border-radius", "6px"),
                    #("font-weight", "600"),
                    #("cursor", "pointer"),
                    #("white-space", "nowrap"),
                  ]),
                ],
                [text("k>d (Copy to Data)")],
              ),
              button(
                [
                  on_click(SubmitQueryDataArray),
                  type_("button"),
                  styles([
                    #("padding", "10px 14px"),
                    #("background", "var(--bg-card-subtle, #21262d)"),
                    #("color", "#d29922"),
                    #("border", "1px solid #30363d"),
                    #("border-radius", "6px"),
                    #("font-weight", "600"),
                    #("cursor", "pointer"),
                    #("white-space", "nowrap"),
                  ]),
                ],
                [text("?d (View Data Array)")],
              ),
            ],
          ),
          // Authentic K-Synth Presets from octetta/k-synth
          div(
            [
              styles([
                #("display", "flex"),
                #("gap", "6px"),
                #("align-items", "center"),
                #("flex-wrap", "wrap"),
                #("margin-bottom", "14px"),
              ]),
            ],
            [
              span(
                [
                  styles([
                    #("font-size", "11px"),
                    #("color", "var(--text-muted, #8b949e)"),
                  ]),
                ],
                [
                  text("octetta/k-synth Examples:"),
                ],
              ),
              ..list.map(
                [
                  #("Sine 220Hz", "w s +\\(44100#220*(6.28318%44100))"),
                  #(
                    "Saw Additive ($)",
                    "w (+\\(44100#220*(6.28318%44100))) $ (1%(!32+1))",
                  ),
                  #(
                    "Square Odd ($)",
                    "w (+\\(44100#220*(6.28318%44100))) $ (1 0 0.333 0 0.2 0 0.143)",
                  ),
                  #(
                    "Triangle ($)",
                    "w (+\\(44100#220*(6.28318%44100))) $ (1 0 -.111 0 .04 0 -.0204)",
                  ),
                  #("Organ (o)", "w (+\\(44100#220*(6.28318%44100))) o 1 3 5 7"),
                  #(
                    "FM Bell",
                    "w (exp(!44100*(0-3%44100))) * (sin(+\\(44100#440*(6.28318%44100)) + 3.5*sin(+\\(44100#440*(6.28318%44100)))))",
                  ),
                  #(
                    "Kick Drum",
                    "0.5 & -0.5 | 5 * (s 0.007 * !8000) * (1 - 0.000125 * !8000) * (1 - 0.000125 * !8000)",
                  ),
                  #("Filtered Noise", "w 0.7 f rand(!44100)"),
                  #("Step Pulse", "128#!1"),
                  #("Index Ramp", "!128"),
                ],
                fn(pair) {
                  let #(name, formula) = pair
                  button(
                    [
                      on_click(SetKSynthInput(formula)),
                      type_("button"),
                      styles([
                        #("padding", "3px 8px"),
                        #("background", "var(--bg-card-subtle, #21262d)"),
                        #("color", "#bc8cff"),
                        #("border", "1px solid #30363d"),
                        #("border-radius", "4px"),
                        #("font-size", "11px"),
                        #("cursor", "pointer"),
                      ]),
                    ],
                    [text(name)],
                  )
                },
              )
            ],
          ),
          // Wavetable Routing: k>w
          div(
            [
              styles([
                #("display", "flex"),
                #("gap", "10px"),
                #("align-items", "center"),
                #("padding-top", "12px"),
                #("border-top", "1px solid #21262d"),
                #("flex-wrap", "wrap"),
              ]),
            ],
            [
              span(
                [
                  styles([
                    #("font-size", "12px"),
                    #("color", "var(--text-muted, #8b949e)"),
                  ]),
                ],
                [
                  text("Install Last K-Synth Result to Wavetable (k>w):"),
                ],
              ),
              select(
                [
                  on_change(fn(s) { SetKSynthSlot(parse_int(s, 0)) }),
                  value(int.to_string(model.ksynth_slot)),
                  styles([
                    #("padding", "6px 10px"),
                    #("background", "var(--bg-card-subtle, #21262d)"),
                    #("color", "var(--text-primary, #f0f6fc)"),
                    #("border", "1px solid #30363d"),
                    #("border-radius", "6px"),
                    #("font-family", "monospace"),
                  ]),
                ],
                list.map(
                  [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
                  fn(slot_id) {
                    option(
                      [value(int.to_string(slot_id))],
                      "Wavetable Slot w" <> int.to_string(slot_id),
                    )
                  },
                ),
              ),
              button(
                [
                  on_click(SubmitKSynthToWave(model.ksynth_slot)),
                  type_("button"),
                  styles([
                    #("padding", "6px 14px"),
                    #("background", "var(--border, #30363d)"),
                    #("color", "var(--text-primary, #f0f6fc)"),
                    #("border", "1px solid #484f58"),
                    #("border-radius", "6px"),
                    #("font-size", "12px"),
                    #("cursor", "pointer"),
                  ]),
                ],
                [
                  text(
                    "k>w "
                    <> int.to_string(model.ksynth_slot)
                    <> " (Install Vector to Wave)",
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
      // Stream Engine Controls (/SM, /SP, ?S)
      div(
        [
          styles([
            #("background", "var(--bg-card, #161b22)"),
            #("border", "1px solid #30363d"),
            #("border-radius", "8px"),
            #("padding", "16px"),
          ]),
        ],
        [
          span(
            [
              styles([
                #("font-size", "14px"),
                #("font-weight", "600"),
                #("color", "var(--text-primary, #f0f6fc)"),
                #("display", "block"),
                #("margin-bottom", "12px"),
              ]),
            ],
            [text("Real-Time Stream Engine (/SM /SP ?S)")],
          ),
          div(
            [
              styles([
                #("display", "flex"),
                #("gap", "12px"),
                #("align-items", "center"),
                #("flex-wrap", "wrap"),
              ]),
            ],
            [
              span(
                [
                  styles([
                    #("font-size", "12px"),
                    #("color", "var(--text-muted, #8b949e)"),
                  ]),
                ],
                [
                  text("Stream Mode:"),
                ],
              ),
              button(
                [
                  on_click(SetStreamMode(0)),
                  type_("button"),
                  styles([
                    #("padding", "6px 12px"),
                    #("background", "var(--bg-card-subtle, #21262d)"),
                    #("color", "var(--text-secondary, #c9d1d9)"),
                    #("border", "1px solid #30363d"),
                    #("border-radius", "6px"),
                    #("font-size", "12px"),
                    #("cursor", "pointer"),
                  ]),
                ],
                [text("/SM 0 (Off)")],
              ),
              button(
                [
                  on_click(SetStreamMode(1)),
                  type_("button"),
                  styles([
                    #("padding", "6px 12px"),
                    #("background", "var(--bg-card-subtle, #21262d)"),
                    #("color", "#3fb950"),
                    #("border", "1px solid #238636"),
                    #("border-radius", "6px"),
                    #("font-size", "12px"),
                    #("cursor", "pointer"),
                  ]),
                ],
                [text("/SM 1 (Continuous)")],
              ),
              button(
                [
                  on_click(SetStreamMode(2)),
                  type_("button"),
                  styles([
                    #("padding", "6px 12px"),
                    #("background", "var(--bg-card-subtle, #21262d)"),
                    #("color", "#58a6ff"),
                    #("border", "1px solid #1f6feb"),
                    #("border-radius", "6px"),
                    #("font-size", "12px"),
                    #("cursor", "pointer"),
                  ]),
                ],
                [text("/SM 2 (Events)")],
              ),
              button(
                [
                  on_click(SetInputCommand("?S")),
                  type_("button"),
                  styles([
                    #("padding", "6px 12px"),
                    #("background", "var(--border, #30363d)"),
                    #("color", "var(--text-primary, #f0f6fc)"),
                    #("border", "1px solid #484f58"),
                    #("border-radius", "6px"),
                    #("font-size", "12px"),
                    #("cursor", "pointer"),
                  ]),
                ],
                [text("?S (Query Stream)")],
              ),
            ],
          ),
        ],
      ),
    ],
  )
}

fn render_audio_midi_studio(model: Model) -> Element(Msg) {
  let #(card_bg, border_color, text_color, subtle_color) = case model.theme {
    ThemeDark -> #(
      "var(--bg-card, #161b22)",
      "var(--border, #30363d)",
      "var(--text-primary, #f0f6fc)",
      "var(--text-muted, #8b949e)",
    )
    ThemeLight -> #("#ffffff", "#d0d7de", "#24292f", "#57606a")
  }
  let btn_bg = case model.theme {
    ThemeDark -> "var(--bg-card-subtle, #21262d)"
    ThemeLight -> "#eaeef2"
  }
  let btn_border = case model.theme {
    ThemeDark -> "1px solid #30363d"
    ThemeLight -> "1px solid #d0d7de"
  }

  div(
    [
      styles([
        #("display", "flex"),
        #("flex-direction", "column"),
        #("gap", "18px"),
      ]),
    ],
    [
      // Panel 1: Audio Host Devices & Drivers
      div(
        [
          styles([
            #("background", card_bg),
            #("border", "1px solid " <> border_color),
            #("border-radius", "8px"),
            #("padding", "18px"),
          ]),
        ],
        [
          div(
            [
              styles([
                #("display", "flex"),
                #("justify-content", "space-between"),
                #("align-items", "center"),
                #("margin-bottom", "14px"),
                #("flex-wrap", "wrap"),
                #("gap", "8px"),
              ]),
            ],
            [
              div([], [
                span(
                  [
                    styles([
                      #("font-size", "15px"),
                      #("font-weight", "700"),
                      #("color", "#58a6ff"),
                      #("display", "block"),
                      #("margin-bottom", "2px"),
                    ]),
                  ],
                  [text("🎧 Audio Host Devices & Drivers (/als /ao /ai ?a)")],
                ),
                span(
                  [styles([#("font-size", "12px"), #("color", subtle_color)])],
                  [
                    text(
                      "Pulp hardware audio interface routing via skred_audio_command",
                    ),
                  ],
                ),
              ]),
              div([styles([#("display", "flex"), #("gap", "8px")])], [
                button(
                  [
                    on_click(SubmitAudioList),
                    type_("button"),
                    styles([
                      #("padding", "6px 14px"),
                      #("background", "#1f6feb"),
                      #("color", "#ffffff"),
                      #("border", "none"),
                      #("border-radius", "6px"),
                      #("font-weight", "600"),
                      #("font-size", "12px"),
                      #("cursor", "pointer"),
                    ]),
                  ],
                  [text("Scan Devices (/als)")],
                ),
                button(
                  [
                    on_click(SubmitAudioQuery),
                    type_("button"),
                    styles([
                      #("padding", "6px 14px"),
                      #("background", btn_bg),
                      #("color", text_color),
                      #("border", btn_border),
                      #("border-radius", "6px"),
                      #("font-size", "12px"),
                      #("cursor", "pointer"),
                    ]),
                  ],
                  [text("Query Status (?a)")],
                ),
              ]),
            ],
          ),
          div(
            [
              styles([
                #("display", "grid"),
                #(
                  "grid-template-columns",
                  "repeat(auto-fit, minmax(300px, 1fr))",
                ),
                #("gap", "14px"),
                #("padding", "12px"),
                #("background", case model.theme {
                  ThemeDark -> "var(--bg-app, #0d1117)"
                  ThemeLight -> "#f6f8fa"
                }),
                #("border", "1px solid " <> border_color),
                #("border-radius", "6px"),
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
                      #("font-weight", "600"),
                      #("color", subtle_color),
                      #("display", "block"),
                      #("margin-bottom", "6px"),
                    ]),
                  ],
                  [text("Select Audio Output (/ao <id>)")],
                ),
                div(
                  [
                    styles([
                      #("display", "flex"),
                      #("gap", "6px"),
                      #("flex-wrap", "wrap"),
                    ]),
                  ],
                  list.map([0, 1, 2, 3], fn(dev_id) {
                    button(
                      [
                        on_click(SubmitAudioOut(dev_id)),
                        type_("button"),
                        styles([
                          #("padding", "5px 12px"),
                          #("background", btn_bg),
                          #("color", text_color),
                          #("border", btn_border),
                          #("border-radius", "4px"),
                          #("font-size", "12px"),
                          #("font-family", "monospace"),
                          #("cursor", "pointer"),
                        ]),
                      ],
                      [text("/ao " <> int.to_string(dev_id))],
                    )
                  }),
                ),
              ]),
              div([], [
                span(
                  [
                    styles([
                      #("font-size", "11px"),
                      #("text-transform", "uppercase"),
                      #("letter-spacing", "0.5px"),
                      #("font-weight", "600"),
                      #("color", subtle_color),
                      #("display", "block"),
                      #("margin-bottom", "6px"),
                    ]),
                  ],
                  [text("Select Audio Input (/ai <id>)")],
                ),
                div(
                  [
                    styles([
                      #("display", "flex"),
                      #("gap", "6px"),
                      #("flex-wrap", "wrap"),
                    ]),
                  ],
                  list.map([0, 1, 2, 3], fn(dev_id) {
                    button(
                      [
                        on_click(SubmitAudioIn(dev_id)),
                        type_("button"),
                        styles([
                          #("padding", "5px 12px"),
                          #("background", btn_bg),
                          #("color", text_color),
                          #("border", btn_border),
                          #("border-radius", "4px"),
                          #("font-size", "12px"),
                          #("font-family", "monospace"),
                          #("cursor", "pointer"),
                        ]),
                      ],
                      [text("/ai " <> int.to_string(dev_id))],
                    )
                  }),
                ),
              ]),
            ],
          ),
        ],
      ),
      // Panel 2: MIDI Hardware, Ports & Routing
      div(
        [
          styles([
            #("background", card_bg),
            #("border", "1px solid " <> border_color),
            #("border-radius", "8px"),
            #("padding", "18px"),
          ]),
        ],
        [
          div(
            [
              styles([
                #("display", "flex"),
                #("justify-content", "space-between"),
                #("align-items", "center"),
                #("margin-bottom", "14px"),
                #("flex-wrap", "wrap"),
                #("gap", "8px"),
              ]),
            ],
            [
              div([], [
                span(
                  [
                    styles([
                      #("font-size", "15px"),
                      #("font-weight", "700"),
                      #("color", "#bc8cff"),
                      #("display", "block"),
                      #("margin-bottom", "2px"),
                    ]),
                  ],
                  [
                    text(
                      "🎹 MIDI Hardware & Port Routing (/mls /mi /mo /mv /mp ?m)",
                    ),
                  ],
                ),
                span(
                  [styles([#("font-size", "12px"), #("color", subtle_color)])],
                  [
                    text(
                      "Multi-channel MIDI inputs, virtual ports, voice routing, and poly pools",
                    ),
                  ],
                ),
              ]),
              div([styles([#("display", "flex"), #("gap", "8px")])], [
                button(
                  [
                    on_click(SubmitMidiList),
                    type_("button"),
                    styles([
                      #("padding", "6px 14px"),
                      #("background", "#8957e5"),
                      #("color", "#ffffff"),
                      #("border", "none"),
                      #("border-radius", "6px"),
                      #("font-weight", "600"),
                      #("font-size", "12px"),
                      #("cursor", "pointer"),
                    ]),
                  ],
                  [text("Scan MIDI (/mls)")],
                ),
                button(
                  [
                    on_click(SubmitMidiQuery),
                    type_("button"),
                    styles([
                      #("padding", "6px 14px"),
                      #("background", btn_bg),
                      #("color", text_color),
                      #("border", btn_border),
                      #("border-radius", "6px"),
                      #("font-size", "12px"),
                      #("cursor", "pointer"),
                    ]),
                  ],
                  [text("Query Routing (?m)")],
                ),
              ]),
            ],
          ),
          div(
            [
              styles([
                #("display", "grid"),
                #(
                  "grid-template-columns",
                  "repeat(auto-fit, minmax(280px, 1fr))",
                ),
                #("gap", "12px"),
                #("margin-bottom", "14px"),
              ]),
            ],
            [
              div(
                [
                  styles([
                    #("padding", "12px"),
                    #("background", case model.theme {
                      ThemeDark -> "var(--bg-app, #0d1117)"
                      ThemeLight -> "#f6f8fa"
                    }),
                    #("border", "1px solid " <> border_color),
                    #("border-radius", "6px"),
                  ]),
                ],
                [
                  span(
                    [
                      styles([
                        #("font-size", "11px"),
                        #("font-weight", "600"),
                        #("color", subtle_color),
                        #("display", "block"),
                        #("margin-bottom", "6px"),
                      ]),
                    ],
                    [text("Open MIDI Input (/mi <id>)")],
                  ),
                  div(
                    [styles([#("display", "flex"), #("gap", "6px")])],
                    list.map([0, 1, 2], fn(port) {
                      button(
                        [
                          on_click(SubmitMidiIn(port)),
                          type_("button"),
                          styles([
                            #("padding", "5px 12px"),
                            #("background", btn_bg),
                            #("color", text_color),
                            #("border", btn_border),
                            #("border-radius", "4px"),
                            #("font-size", "12px"),
                            #("cursor", "pointer"),
                          ]),
                        ],
                        [text("Port " <> int.to_string(port))],
                      )
                    }),
                  ),
                ],
              ),
              div(
                [
                  styles([
                    #("padding", "12px"),
                    #("background", case model.theme {
                      ThemeDark -> "var(--bg-app, #0d1117)"
                      ThemeLight -> "#f6f8fa"
                    }),
                    #("border", "1px solid " <> border_color),
                    #("border-radius", "6px"),
                  ]),
                ],
                [
                  span(
                    [
                      styles([
                        #("font-size", "11px"),
                        #("font-weight", "600"),
                        #("color", subtle_color),
                        #("display", "block"),
                        #("margin-bottom", "6px"),
                      ]),
                    ],
                    [text("Open MIDI Output (/mo <id>)")],
                  ),
                  div(
                    [styles([#("display", "flex"), #("gap", "6px")])],
                    list.map([0, 1, 2], fn(port) {
                      button(
                        [
                          on_click(SubmitMidiOut(port)),
                          type_("button"),
                          styles([
                            #("padding", "5px 12px"),
                            #("background", btn_bg),
                            #("color", text_color),
                            #("border", btn_border),
                            #("border-radius", "4px"),
                            #("font-size", "12px"),
                            #("cursor", "pointer"),
                          ]),
                        ],
                        [text("Port " <> int.to_string(port))],
                      )
                    }),
                  ),
                ],
              ),
            ],
          ),
          div(
            [
              styles([
                #("display", "flex"),
                #("flex-direction", "column"),
                #("gap", "8px"),
                #("padding", "12px"),
                #("background", case model.theme {
                  ThemeDark -> "var(--bg-app, #0d1117)"
                  ThemeLight -> "#f6f8fa"
                }),
                #("border", "1px solid " <> border_color),
                #("border-radius", "6px"),
              ]),
            ],
            [
              span(
                [
                  styles([
                    #("font-size", "11px"),
                    #("text-transform", "uppercase"),
                    #("letter-spacing", "0.5px"),
                    #("font-weight", "600"),
                    #("color", subtle_color),
                  ]),
                ],
                [text("Quick Channel Routing Presets (/mv and /mp)")],
              ),
              div(
                [
                  styles([
                    #("display", "flex"),
                    #("gap", "8px"),
                    #("flex-wrap", "wrap"),
                  ]),
                ],
                [
                  button(
                    [
                      on_click(SubmitMidiVoiceRoute(1, 0)),
                      type_("button"),
                      styles([
                        #("padding", "6px 12px"),
                        #("background", btn_bg),
                        #("color", text_color),
                        #("border", btn_border),
                        #("border-radius", "4px"),
                        #("font-size", "12px"),
                        #("cursor", "pointer"),
                      ]),
                    ],
                    [text("/mv 1,0 (Ch 1 -> Voice 0)")],
                  ),
                  button(
                    [
                      on_click(SubmitMidiVoiceRoute(2, 1)),
                      type_("button"),
                      styles([
                        #("padding", "6px 12px"),
                        #("background", btn_bg),
                        #("color", text_color),
                        #("border", btn_border),
                        #("border-radius", "4px"),
                        #("font-size", "12px"),
                        #("cursor", "pointer"),
                      ]),
                    ],
                    [text("/mv 2,1 (Ch 2 -> Voice 1)")],
                  ),
                  button(
                    [
                      on_click(SubmitMidiVoiceRoute(10, 9)),
                      type_("button"),
                      styles([
                        #("padding", "6px 12px"),
                        #("background", btn_bg),
                        #("color", text_color),
                        #("border", btn_border),
                        #("border-radius", "4px"),
                        #("font-size", "12px"),
                        #("cursor", "pointer"),
                      ]),
                    ],
                    [text("/mv 10,9 (Ch 10 -> Voice 9 Drums)")],
                  ),
                  button(
                    [
                      on_click(SubmitMidiPoolRoute(1, 0)),
                      type_("button"),
                      styles([
                        #("padding", "6px 12px"),
                        #("background", btn_bg),
                        #("color", text_color),
                        #("border", btn_border),
                        #("border-radius", "4px"),
                        #("font-size", "12px"),
                        #("cursor", "pointer"),
                      ]),
                    ],
                    [text("/mp 1,0 (Ch 1 -> Poly Pool 0)")],
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
      // Panel 3: Control Plane & Event Dispatcher
      div(
        [
          styles([
            #("background", card_bg),
            #("border", "1px solid " <> border_color),
            #("border-radius", "8px"),
            #("padding", "18px"),
          ]),
        ],
        [
          div(
            [
              styles([
                #("display", "flex"),
                #("justify-content", "space-between"),
                #("align-items", "center"),
                #("margin-bottom", "14px"),
                #("flex-wrap", "wrap"),
                #("gap", "8px"),
              ]),
            ],
            [
              div([], [
                span(
                  [
                    styles([
                      #("font-size", "15px"),
                      #("font-weight", "700"),
                      #("color", "#3fb950"),
                      #("display", "block"),
                      #("margin-bottom", "2px"),
                    ]),
                  ],
                  [
                    text(
                      "⚡ Control Plane & Event Dispatcher (vc1 yc1 ce ?ce ?q)",
                    ),
                  ],
                ),
                span(
                  [styles([#("font-size", "12px"), #("color", subtle_color)])],
                  [
                    text(
                      "Real-time event loop notifications from DSP thread to host UI (skred_control_event_poll)",
                    ),
                  ],
                ),
              ]),
              div([styles([#("display", "flex"), #("gap", "8px")])], [
                button(
                  [
                    on_click(SubmitControlEventQuery),
                    type_("button"),
                    styles([
                      #("padding", "6px 14px"),
                      #("background", "#238636"),
                      #("color", "#ffffff"),
                      #("border", "none"),
                      #("border-radius", "6px"),
                      #("font-weight", "600"),
                      #("font-size", "12px"),
                      #("cursor", "pointer"),
                    ]),
                  ],
                  [text("Poll Events (?ce)")],
                ),
                button(
                  [
                    on_click(SubmitControlEventClear),
                    type_("button"),
                    styles([
                      #("padding", "6px 14px"),
                      #("background", btn_bg),
                      #("color", "#f85149"),
                      #("border", btn_border),
                      #("border-radius", "6px"),
                      #("font-size", "12px"),
                      #("cursor", "pointer"),
                    ]),
                  ],
                  [text("Flush Events (?ce!)")],
                ),
                button(
                  [
                    on_click(SubmitScheduledQueueQuery),
                    type_("button"),
                    styles([
                      #("padding", "6px 14px"),
                      #("background", btn_bg),
                      #("color", text_color),
                      #("border", btn_border),
                      #("border-radius", "6px"),
                      #("font-size", "12px"),
                      #("cursor", "pointer"),
                    ]),
                  ],
                  [text("Inspect Queue (?q)")],
                ),
              ]),
            ],
          ),
          div(
            [
              styles([
                #("display", "grid"),
                #(
                  "grid-template-columns",
                  "repeat(auto-fit, minmax(320px, 1fr))",
                ),
                #("gap", "12px"),
              ]),
            ],
            [
              div(
                [
                  styles([
                    #("padding", "14px"),
                    #("background", case model.theme {
                      ThemeDark -> "var(--bg-app, #0d1117)"
                      ThemeLight -> "#f6f8fa"
                    }),
                    #("border", "1px solid " <> border_color),
                    #("border-radius", "6px"),
                    #("display", "flex"),
                    #("flex-direction", "column"),
                    #("gap", "10px"),
                  ]),
                ],
                [
                  span(
                    [
                      styles([
                        #("font-size", "12px"),
                        #("font-weight", "600"),
                        #("color", text_color),
                      ]),
                    ],
                    [text("Event Subscriptions")],
                  ),
                  button(
                    [
                      on_click(ToggleControlVoiceEvents),
                      type_("button"),
                      styles([
                        #("padding", "8px 12px"),
                        #("border-radius", "6px"),
                        #("font-size", "12px"),
                        #("font-weight", "600"),
                        #("cursor", "pointer"),
                        #("text-align", "left"),
                        #("background", case model.control_voice_events {
                          True -> "#23863622"
                          False -> btn_bg
                        }),
                        #("color", case model.control_voice_events {
                          True -> "#3fb950"
                          False -> subtle_color
                        }),
                        #("border", case model.control_voice_events {
                          True -> "1px solid #238636"
                          False -> btn_border
                        }),
                      ]),
                    ],
                    [
                      text(case model.control_voice_events {
                        True -> "🟢 Voice Trigger/Release Events: ACTIVE (vc1)"
                        False -> "⚪ Voice Trigger/Release Events: OFF (vc0)"
                      }),
                    ],
                  ),
                  button(
                    [
                      on_click(ToggleControlPatternEvents),
                      type_("button"),
                      styles([
                        #("padding", "8px 12px"),
                        #("border-radius", "6px"),
                        #("font-size", "12px"),
                        #("font-weight", "600"),
                        #("cursor", "pointer"),
                        #("text-align", "left"),
                        #("background", case model.control_pattern_events {
                          True -> "#1f6feb22"
                          False -> btn_bg
                        }),
                        #("color", case model.control_pattern_events {
                          True -> "#58a6ff"
                          False -> subtle_color
                        }),
                        #("border", case model.control_pattern_events {
                          True -> "1px solid #1f6feb"
                          False -> btn_border
                        }),
                      ]),
                    ],
                    [
                      text(case model.control_pattern_events {
                        True -> "🟢 Pattern Boundary Events: ACTIVE (yc1)"
                        False -> "⚪ Pattern Boundary Events: OFF (yc0)"
                      }),
                    ],
                  ),
                ],
              ),
              div(
                [
                  styles([
                    #("padding", "14px"),
                    #("background", case model.theme {
                      ThemeDark -> "var(--bg-app, #0d1117)"
                      ThemeLight -> "#f6f8fa"
                    }),
                    #("border", "1px solid " <> border_color),
                    #("border-radius", "6px"),
                    #("display", "flex"),
                    #("flex-direction", "column"),
                    #("gap", "10px"),
                  ]),
                ],
                [
                  span(
                    [
                      styles([
                        #("font-size", "12px"),
                        #("font-weight", "600"),
                        #("color", text_color),
                      ]),
                    ],
                    [text("Emit Custom Control Marker (ce id[,a,b,c])")],
                  ),
                  div(
                    [
                      styles([
                        #("display", "flex"),
                        #("gap", "6px"),
                        #("flex-wrap", "wrap"),
                      ]),
                    ],
                    [
                      button(
                        [
                          on_click(SubmitUserControlEvent(1, 100, 0, 0)),
                          type_("button"),
                          styles([
                            #("padding", "6px 10px"),
                            #("background", btn_bg),
                            #("color", text_color),
                            #("border", btn_border),
                            #("border-radius", "4px"),
                            #("font-size", "12px"),
                            #("cursor", "pointer"),
                          ]),
                        ],
                        [text("ce 1,100,0,0 (Marker 1)")],
                      ),
                      button(
                        [
                          on_click(SubmitUserControlEvent(2, 200, 0, 0)),
                          type_("button"),
                          styles([
                            #("padding", "6px 10px"),
                            #("background", btn_bg),
                            #("color", text_color),
                            #("border", btn_border),
                            #("border-radius", "4px"),
                            #("font-size", "12px"),
                            #("cursor", "pointer"),
                          ]),
                        ],
                        [text("ce 2,200,0,0 (Marker 2)")],
                      ),
                      button(
                        [
                          on_click(SubmitUserControlEvent(99, 127, 64, 32)),
                          type_("button"),
                          styles([
                            #("padding", "6px 10px"),
                            #("background", btn_bg),
                            #("color", text_color),
                            #("border", btn_border),
                            #("border-radius", "4px"),
                            #("font-size", "12px"),
                            #("cursor", "pointer"),
                          ]),
                        ],
                        [text("ce 99,127,64,32 (Cue 99)")],
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    ],
  )
}

fn render_studio_footer(model: Model) -> Element(Msg) {
  footer(
    [
      styles([
        #("display", "flex"),
        #("justify-content", "space-between"),
        #("align-items", "center"),
        #("font-size", "12px"),
        #("color", "var(--text-muted, #8b949e)"),
        #("border-top", "1px solid #21262d"),
        #("padding-top", "16px"),
        #("margin-top", "24px"),
      ]),
    ],
    [
      span([], [
        text(
          "Pulp 0.85.0 Audio Engine • Full 256 Voice Sparse Architecture • Lustre 5.7",
        ),
      ]),
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
  )
}

fn preset_pill(label_text: String) -> Element(Msg) {
  button(
    [
      on_click(ApplyPreset(label_text)),
      styles([
        #("padding", "4px 10px"),
        #("background", "var(--bg-card-subtle, #21262d)"),
        #("color", "var(--text-secondary, #c9d1d9)"),
        #("border", "1px solid #30363d"),
        #("border-radius", "14px"),
        #("font-size", "12px"),
        #("cursor", "pointer"),
      ]),
    ],
    [text(label_text)],
  )
}

// -----------------------------------------------------------------------------
// Files & Virtual Filesystem (VFS) Studio
// -----------------------------------------------------------------------------

fn render_files_studio(model: Model) -> Element(Msg) {
  let #(card_bg, border_color, text_color, subtle_color) = case model.theme {
    ThemeDark -> #(
      "var(--bg-card, #161b22)",
      "var(--border, #30363d)",
      "var(--text-primary, #f0f6fc)",
      "var(--text-muted, #8b949e)",
    )
    ThemeLight -> #("#ffffff", "#d0d7de", "#24292f", "#57606a")
  }
  let btn_bg = case model.theme {
    ThemeDark -> "var(--bg-card-subtle, #21262d)"
    ThemeLight -> "#eaeef2"
  }
  let btn_border = case model.theme {
    ThemeDark -> "1px solid #30363d"
    ThemeLight -> "1px solid #d0d7de"
  }

  div(
    [
      styles([
        #("display", "flex"),
        #("flex-direction", "column"),
        #("gap", "18px"),
      ]),
    ],
    [
      // Panel 1: File Manager Toolbar & Project Bundler
      div(
        [
          styles([
            #("background", card_bg),
            #("border", "1px solid " <> border_color),
            #("border-radius", "8px"),
            #("padding", "18px"),
          ]),
        ],
        [
          div(
            [
              styles([
                #("display", "flex"),
                #("justify-content", "space-between"),
                #("align-items", "center"),
                #("margin-bottom", "14px"),
                #("flex-wrap", "wrap"),
                #("gap", "10px"),
              ]),
            ],
            [
              div([], [
                span(
                  [
                    styles([
                      #("font-size", "15px"),
                      #("font-weight", "700"),
                      #("color", "#58a6ff"),
                      #("display", "block"),
                      #("margin-bottom", "2px"),
                    ]),
                  ],
                  [text("📁 Virtual Filesystem & Attachments (MEMFS / -add)")],
                ),
                span(
                  [styles([#("font-size", "12px"), #("color", subtle_color)])],
                  [
                    text(
                      "Attach audio (.wav, .mp3, .flac), scripts (.sk, .ks), or ZIP soundpacks (%z)",
                    ),
                  ],
                ),
              ]),
              div(
                [
                  styles([
                    #("display", "flex"),
                    #("gap", "8px"),
                    #("flex-wrap", "wrap"),
                  ]),
                ],
                [
                  button(
                    [
                      on_click(AttachFilesViaDialog),
                      type_("button"),
                      styles([
                        #("padding", "7px 14px"),
                        #("background", "#1f6feb"),
                        #("color", "#ffffff"),
                        #("border", "none"),
                        #("border-radius", "6px"),
                        #("cursor", "pointer"),
                        #("font-size", "12px"),
                        #("font-weight", "600"),
                      ]),
                    ],
                    [text("📎 Attach Files (-add)")],
                  ),
                  button(
                    [
                      on_click(ExportSessionZip),
                      type_("button"),
                      styles([
                        #("padding", "7px 14px"),
                        #("background", btn_bg),
                        #("color", text_color),
                        #("border", btn_border),
                        #("border-radius", "6px"),
                        #("cursor", "pointer"),
                        #("font-size", "12px"),
                        #("font-weight", "600"),
                      ]),
                    ],
                    [text("💾 Export Project (.zip)")],
                  ),
                  button(
                    [
                      on_click(ImportSessionZip),
                      type_("button"),
                      styles([
                        #("padding", "7px 14px"),
                        #("background", btn_bg),
                        #("color", text_color),
                        #("border", btn_border),
                        #("border-radius", "6px"),
                        #("cursor", "pointer"),
                        #("font-size", "12px"),
                        #("font-weight", "600"),
                      ]),
                    ],
                    [text("📂 Import Project (.zip)")],
                  ),
                  button(
                    [
                      on_click(UnmountZipFile),
                      type_("button"),
                      styles([
                        #("padding", "7px 14px"),
                        #("background", btn_bg),
                        #("color", "#d29922"),
                        #("border", btn_border),
                        #("border-radius", "6px"),
                        #("cursor", "pointer"),
                        #("font-size", "12px"),
                      ]),
                    ],
                    [text("⏏ Unmount Zip (%u)")],
                  ),
                ],
              ),
            ],
          ),
          // Attached Files Table
          div(
            [
              styles([
                #("border", "1px solid " <> border_color),
                #("border-radius", "6px"),
                #("overflow", "hidden"),
                #("background", "var(--bg-app, #0d1117)"),
              ]),
            ],
            [
              div(
                [
                  styles([
                    #("display", "grid"),
                    #("grid-template-columns", "2fr 1fr 1fr 3fr"),
                    #("padding", "8px 14px"),
                    #("font-size", "11px"),
                    #("font-weight", "700"),
                    #("color", subtle_color),
                    #("border-bottom", "1px solid " <> border_color),
                    #("background", btn_bg),
                  ]),
                ],
                [
                  span([], [text("FILE NAME")]),
                  span([], [text("TYPE")]),
                  span([], [text("SIZE")]),
                  span([styles([#("text-align", "right")])], [text("ACTIONS")]),
                ],
              ),
              case list.is_empty(model.vfs_items) {
                True ->
                  div(
                    [
                      styles([
                        #("padding", "24px"),
                        #("text-align", "center"),
                        #("color", subtle_color),
                        #("font-size", "13px"),
                      ]),
                    ],
                    [
                      text(
                        "No files currently attached. Click '📎 Attach Files' to add assets.",
                      ),
                    ],
                  )
                False ->
                  div(
                    [],
                    list.map(model.vfs_items, fn(item) {
                      let kind_badge_color = case item.kind {
                        "wav" | "mp3" | "flac" -> "#3fb950"
                        "sk" -> "#58a6ff"
                        "ks" -> "#a371f7"
                        "zip" -> "#d29922"
                        _ -> subtle_color
                      }
                      div(
                        [
                          styles([
                            #("display", "grid"),
                            #("grid-template-columns", "2fr 1fr 1fr 3fr"),
                            #("padding", "10px 14px"),
                            #("align-items", "center"),
                            #("border-bottom", "1px solid " <> border_color),
                            #("font-size", "12px"),
                            #("color", text_color),
                          ]),
                        ],
                        [
                          span(
                            [
                              styles([
                                #("font-weight", "600"),
                                #("font-family", "monospace"),
                              ]),
                            ],
                            [text(item.name)],
                          ),
                          span([], [
                            span(
                              [
                                styles([
                                  #("padding", "2px 6px"),
                                  #("border-radius", "4px"),
                                  #("font-size", "10px"),
                                  #("font-weight", "700"),
                                  #("background", kind_badge_color <> "22"),
                                  #("color", kind_badge_color),
                                ]),
                              ],
                              [text(string.uppercase(item.kind))],
                            ),
                          ]),
                          span(
                            [
                              styles([
                                #("color", subtle_color),
                                #("font-family", "monospace"),
                              ]),
                            ],
                            [text(item.size_str)],
                          ),
                          div(
                            [
                              styles([
                                #("display", "flex"),
                                #("gap", "6px"),
                                #("justify-content", "flex-end"),
                              ]),
                            ],
                            [
                              case item.kind {
                                "wav" | "mp3" | "flac" ->
                                  button(
                                    [
                                      on_click(LoadFileToWaveSlot(
                                        item.name,
                                        model.voice.wave_table_index,
                                      )),
                                      type_("button"),
                                      styles([
                                        #("padding", "3px 8px"),
                                        #("background", btn_bg),
                                        #("color", "#3fb950"),
                                        #("border", btn_border),
                                        #("border-radius", "4px"),
                                        #("cursor", "pointer"),
                                        #("font-size", "11px"),
                                      ]),
                                    ],
                                    [
                                      text(
                                        "Load to w"
                                        <> int.to_string(
                                          model.voice.wave_table_index,
                                        )
                                        <> " (/ws)",
                                      ),
                                    ],
                                  )
                                "zip" ->
                                  button(
                                    [
                                      on_click(MountZipFile(item.name)),
                                      type_("button"),
                                      styles([
                                        #("padding", "3px 8px"),
                                        #("background", btn_bg),
                                        #("color", "#d29922"),
                                        #("border", btn_border),
                                        #("border-radius", "4px"),
                                        #("cursor", "pointer"),
                                        #("font-size", "11px"),
                                      ]),
                                    ],
                                    [text("Mount (%z)")],
                                  )
                                "sk" | "ks" ->
                                  button(
                                    [
                                      on_click(RunVfsScript(item.name)),
                                      type_("button"),
                                      styles([
                                        #("padding", "3px 8px"),
                                        #("background", btn_bg),
                                        #("color", "#58a6ff"),
                                        #("border", btn_border),
                                        #("border-radius", "4px"),
                                        #("cursor", "pointer"),
                                        #("font-size", "11px"),
                                      ]),
                                    ],
                                    [
                                      text(case item.kind == "ks" {
                                        True -> "Run (/ks)"
                                        False -> "Run (/ls)"
                                      }),
                                    ],
                                  )
                                _ -> div([], [])
                              },
                              button(
                                [
                                  on_click(DeleteVfsItem(item.name)),
                                  type_("button"),
                                  styles([
                                    #("padding", "3px 8px"),
                                    #("background", btn_bg),
                                    #("color", "#f85149"),
                                    #("border", btn_border),
                                    #("border-radius", "4px"),
                                    #("cursor", "pointer"),
                                    #("font-size", "11px"),
                                  ]),
                                ],
                                [text("🗑 Remove")],
                              ),
                            ],
                          ),
                        ],
                      )
                    }),
                  )
              },
            ],
          ),
        ],
      ),
      // Panel 2: Pulp VFS Quick Guide
      div(
        [
          styles([
            #("background", card_bg),
            #("border", "1px solid " <> border_color),
            #("border-radius", "8px"),
            #("padding", "16px"),
          ]),
        ],
        [
          span(
            [
              styles([
                #("font-size", "13px"),
                #("font-weight", "700"),
                #("color", text_color),
                #("display", "block"),
                #("margin-bottom", "8px"),
              ]),
            ],
            [text("💡 Skode / Pulp Virtual Filesystem Reference")],
          ),
          div(
            [
              styles([
                #("display", "grid"),
                #(
                  "grid-template-columns",
                  "repeat(auto-fit, minmax(240px, 1fr))",
                ),
                #("gap", "10px"),
                #("font-size", "12px"),
                #("color", subtle_color),
              ]),
            ],
            [
              div([], [
                span(
                  [
                    styles([
                      #("color", "#3fb950"),
                      #("font-family", "monospace"),
                      #("font-weight", "600"),
                    ]),
                  ],
                  [text("[file.wav] /ws <slot>")],
                ),
                p([styles([#("margin", "2px 0 0 0")])], [
                  text(
                    "Decodes and loads PCM audio directly into a wavetable slot (e.g. w15).",
                  ),
                ]),
              ]),
              div([], [
                span(
                  [
                    styles([
                      #("color", "#d29922"),
                      #("font-family", "monospace"),
                      #("font-weight", "600"),
                    ]),
                  ],
                  [text("[pack.zip] %z  /  %u")],
                ),
                p([styles([#("margin", "2px 0 0 0")])], [
                  text(
                    "Mounts an uncompressed ZIP soundpack bundle into MEMFS (/); %u unmounts.",
                  ),
                ]),
              ]),
              div([], [
                span(
                  [
                    styles([
                      #("color", "#58a6ff"),
                      #("font-family", "monospace"),
                      #("font-weight", "600"),
                    ]),
                  ],
                  [text("[patch.sk] /ls")],
                ),
                p([styles([#("margin", "2px 0 0 0")])], [
                  text(
                    "Loads and executes Skode script line by line in real time.",
                  ),
                ]),
              ]),
              div([], [
                span(
                  [
                    styles([
                      #("color", "#a371f7"),
                      #("font-family", "monospace"),
                      #("font-weight", "600"),
                    ]),
                  ],
                  [text("[synth.ks] /ks")],
                ),
                p([styles([#("margin", "2px 0 0 0")])], [
                  text(
                    "Executes K-Synth token definitions into the active sound matrix.",
                  ),
                ]),
              ]),
            ],
          ),
        ],
      ),
    ],
  )
}

// -----------------------------------------------------------------------------
// Streams Studio (16 Modulation Streams 0..15)
// -----------------------------------------------------------------------------

fn render_streams_studio(model: Model) -> Element(Msg) {
  let #(card_bg, border_color, text_color, subtle_color) = case model.theme {
    ThemeDark -> #(
      "var(--bg-card, #161b22)",
      "var(--border, #30363d)",
      "var(--text-primary, #f0f6fc)",
      "var(--text-muted, #8b949e)",
    )
    ThemeLight -> #("#ffffff", "#d0d7de", "#24292f", "#57606a")
  }
  let btn_bg = case model.theme {
    ThemeDark -> "var(--bg-card-subtle, #21262d)"
    ThemeLight -> "#eaeef2"
  }
  let btn_border = case model.theme {
    ThemeDark -> "1px solid #30363d"
    ThemeLight -> "1px solid #d0d7de"
  }

  let stream_slots = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]

  div(
    [
      styles([
        #("display", "flex"),
        #("flex-direction", "column"),
        #("gap", "18px"),
      ]),
    ],
    [
      // Panel 1: Stream Slots 0..15 Selector Bar
      div(
        [
          styles([
            #("background", card_bg),
            #("border", "1px solid " <> border_color),
            #("border-radius", "8px"),
            #("padding", "16px"),
          ]),
        ],
        [
          div(
            [
              styles([
                #("display", "flex"),
                #("justify-content", "space-between"),
                #("align-items", "center"),
                #("margin-bottom", "12px"),
                #("flex-wrap", "wrap"),
                #("gap", "8px"),
              ]),
            ],
            [
              div([], [
                span(
                  [
                    styles([
                      #("font-size", "15px"),
                      #("font-weight", "700"),
                      #("color", "#58a6ff"),
                      #("display", "block"),
                    ]),
                  ],
                  [text("🌊 Modulation Streams (/SS, /SM, /SP, ?S)")],
                ),
                span(
                  [styles([#("font-size", "12px"), #("color", subtle_color)])],
                  [
                    text(
                      "16 Polyphonic Modulation Streams for LFOs, Arpeggios, and Waveshapes",
                    ),
                  ],
                ),
              ]),
              div([styles([#("display", "flex"), #("gap", "6px")])], [
                button(
                  [
                    on_click(QueryStreamSlot(model.active_stream_slot)),
                    type_("button"),
                    styles([
                      #("padding", "5px 12px"),
                      #("background", btn_bg),
                      #("color", "#58a6ff"),
                      #("border", btn_border),
                      #("border-radius", "6px"),
                      #("cursor", "pointer"),
                      #("font-size", "12px"),
                    ]),
                  ],
                  [
                    text(
                      "Query Slot "
                      <> int.to_string(model.active_stream_slot)
                      <> " (?S)",
                    ),
                  ],
                ),
                button(
                  [
                    on_click(QueryStreamSlot(-1)),
                    type_("button"),
                    styles([
                      #("padding", "5px 12px"),
                      #("background", btn_bg),
                      #("color", text_color),
                      #("border", btn_border),
                      #("border-radius", "6px"),
                      #("cursor", "pointer"),
                      #("font-size", "12px"),
                    ]),
                  ],
                  [text("Query All (?S)")],
                ),
              ]),
            ],
          ),
          // Slots 0..15 grid
          div(
            [
              styles([
                #("display", "grid"),
                #(
                  "grid-template-columns",
                  "repeat(auto-fill, minmax(58px, 1fr))",
                ),
                #("gap", "6px"),
              ]),
            ],
            list.map(stream_slots, fn(slot) {
              let is_active = model.active_stream_slot == slot
              button(
                [
                  on_click(SelectStreamSlot(slot)),
                  type_("button"),
                  styles([
                    #("padding", "8px 4px"),
                    #("border-radius", "6px"),
                    #("font-size", "12px"),
                    #("font-weight", "700"),
                    #("cursor", "pointer"),
                    #("text-align", "center"),
                    #("background", case is_active {
                      True -> "#1f6feb"
                      False -> btn_bg
                    }),
                    #("color", case is_active {
                      True -> "#ffffff"
                      False -> text_color
                    }),
                    #("border", case is_active {
                      True -> "1px solid #58a6ff"
                      False -> btn_border
                    }),
                  ]),
                ],
                [text("S" <> int.to_string(slot))],
              )
            }),
          ),
        ],
      ),
      // Panel 2: Active Stream Configuration
      div(
        [
          styles([
            #("background", card_bg),
            #("border", "1px solid " <> border_color),
            #("border-radius", "8px"),
            #("padding", "18px"),
          ]),
        ],
        [
          span(
            [
              styles([
                #("font-size", "14px"),
                #("font-weight", "700"),
                #("color", text_color),
                #("display", "block"),
                #("margin-bottom", "14px"),
              ]),
            ],
            [
              text(
                "Editing Stream Slot "
                <> int.to_string(model.active_stream_slot),
              ),
            ],
          ),
          div(
            [
              styles([
                #("display", "grid"),
                #(
                  "grid-template-columns",
                  "repeat(auto-fit, minmax(280px, 1fr))",
                ),
                #("gap", "16px"),
                #("margin-bottom", "16px"),
              ]),
            ],
            [
              // Stream Mode (/SM)
              div([], [
                label(
                  [
                    styles([
                      #("font-size", "12px"),
                      #("color", subtle_color),
                      #("display", "block"),
                      #("margin-bottom", "6px"),
                    ]),
                  ],
                  [
                    text(
                      "Stream Mode (/SM "
                      <> int.to_string(model.active_stream_slot)
                      <> " <mode>)",
                    ),
                  ],
                ),
                select(
                  [
                    value(int.to_string(model.active_stream_mode)),
                    on_change(fn(s) {
                      SetStreamSlotMode(
                        model.active_stream_slot,
                        parse_int(s, 0),
                      )
                    }),
                    styles([
                      #("width", "100%"),
                      #("padding", "8px 12px"),
                      #("background", "var(--bg-app, #0d1117)"),
                      #("color", text_color),
                      #("border", "1px solid " <> border_color),
                      #("border-radius", "6px"),
                    ]),
                  ],
                  [
                    option(
                      [
                        value("0"),
                        attribute.selected(model.active_stream_mode == 0),
                      ],
                      "0: Linear Forward (Wrap)",
                    ),
                    option(
                      [
                        value("1"),
                        attribute.selected(model.active_stream_mode == 1),
                      ],
                      "1: Linear Backward (Wrap)",
                    ),
                    option(
                      [
                        value("2"),
                        attribute.selected(model.active_stream_mode == 2),
                      ],
                      "2: Ping-Pong / Bounce",
                    ),
                    option(
                      [
                        value("3"),
                        attribute.selected(model.active_stream_mode == 3),
                      ],
                      "3: Random Walk / Jitter",
                    ),
                    option(
                      [
                        value("4"),
                        attribute.selected(model.active_stream_mode == 4),
                      ],
                      "4: Interpolated / Smooth Spline",
                    ),
                    option(
                      [
                        value("5"),
                        attribute.selected(model.active_stream_mode == 5),
                      ],
                      "5: Quantized Semitones",
                    ),
                  ],
                ),
              ]),
              // Stream Position (/SP)
              div([], [
                div(
                  [
                    styles([
                      #("display", "flex"),
                      #("justify-content", "space-between"),
                      #("margin-bottom", "6px"),
                    ]),
                  ],
                  [
                    label(
                      [
                        styles([
                          #("font-size", "12px"),
                          #("color", subtle_color),
                        ]),
                      ],
                      [text("Stream Head Position (/SP)")],
                    ),
                    span(
                      [
                        styles([
                          #("font-size", "12px"),
                          #("font-family", "monospace"),
                          #("color", "#58a6ff"),
                        ]),
                      ],
                      [text(int.to_string(model.active_stream_pos))],
                    ),
                  ],
                ),
                input([
                  type_("range"),
                  min("0"),
                  max("64"),
                  step("1"),
                  value(int.to_string(model.active_stream_pos)),
                  on_input(fn(s) {
                    SetStreamSlotPos(model.active_stream_slot, parse_int(s, 0))
                  }),
                  styles([#("width", "100%"), #("accent-color", "#1f6feb")]),
                ]),
              ]),
            ],
          ),
          // Stream Data Array Array Input (/SS)
          div([styles([#("margin-bottom", "16px")])], [
            label(
              [
                styles([
                  #("font-size", "12px"),
                  #("color", subtle_color),
                  #("display", "block"),
                  #("margin-bottom", "6px"),
                ]),
              ],
              [
                text(
                  "Stream Data Values Array: ( v0 v1 v2 ... ) /SS "
                  <> int.to_string(model.active_stream_slot),
                ),
              ],
            ),
            input([
              type_("text"),
              placeholder("e.g. 0.0 0.25 0.5 0.75 1.0 0.8 0.6 0.4 0.2"),
              value(model.stream_data_input),
              on_input(SetStreamDataInput),
              styles([
                #("width", "100%"),
                #("padding", "8px 12px"),
                #("background", "var(--bg-app, #0d1117)"),
                #("color", text_color),
                #("border", "1px solid " <> border_color),
                #("border-radius", "6px"),
                #("font-family", "monospace"),
                #("font-size", "13px"),
                #("box-sizing", "border-box"),
                #("margin-bottom", "8px"),
              ]),
            ]),
            div(
              [
                styles([
                  #("display", "flex"),
                  #("gap", "6px"),
                  #("flex-wrap", "wrap"),
                  #("align-items", "center"),
                ]),
              ],
              [
                span(
                  [
                    styles([
                      #("font-size", "11px"),
                      #("color", subtle_color),
                      #("margin-right", "4px"),
                    ]),
                  ],
                  [text("Presets:")],
                ),
                button(
                  [
                    on_click(SetStreamDataInput(
                      "0.0 0.1 0.2 0.3 0.4 0.5 0.6 0.7 0.8 0.9 1.0",
                    )),
                    type_("button"),
                    styles([
                      #("padding", "3px 8px"),
                      #("background", btn_bg),
                      #("color", subtle_color),
                      #("border", btn_border),
                      #("border-radius", "4px"),
                      #("cursor", "pointer"),
                      #("font-size", "11px"),
                    ]),
                  ],
                  [text("Ramp Up")],
                ),
                button(
                  [
                    on_click(SetStreamDataInput(
                      "0.0 0.38 0.71 0.92 1.0 0.92 0.71 0.38 0.0 -0.38 -0.71 -0.92 -1.0 -0.92 -0.71 -0.38",
                    )),
                    type_("button"),
                    styles([
                      #("padding", "3px 8px"),
                      #("background", btn_bg),
                      #("color", subtle_color),
                      #("border", btn_border),
                      #("border-radius", "4px"),
                      #("cursor", "pointer"),
                      #("font-size", "11px"),
                    ]),
                  ],
                  [text("Sine Wave")],
                ),
                button(
                  [
                    on_click(SetStreamDataInput(
                      "0.0 0.25 0.5 0.75 1.0 0.75 0.5 0.25 0.0",
                    )),
                    type_("button"),
                    styles([
                      #("padding", "3px 8px"),
                      #("background", btn_bg),
                      #("color", subtle_color),
                      #("border", btn_border),
                      #("border-radius", "4px"),
                      #("cursor", "pointer"),
                      #("font-size", "11px"),
                    ]),
                  ],
                  [text("Triangle")],
                ),
                button(
                  [
                    on_click(SetStreamDataInput(
                      "0.0 4.0 7.0 12.0 16.0 19.0 24.0",
                    )),
                    type_("button"),
                    styles([
                      #("padding", "3px 8px"),
                      #("background", btn_bg),
                      #("color", subtle_color),
                      #("border", btn_border),
                      #("border-radius", "4px"),
                      #("cursor", "pointer"),
                      #("font-size", "11px"),
                    ]),
                  ],
                  [text("Arp (Maj7)")],
                ),
                div([styles([#("flex", "1")])], []),
                button(
                  [
                    on_click(SubmitStreamDataSet(
                      model.active_stream_slot,
                      model.stream_data_input,
                    )),
                    type_("button"),
                    styles([
                      #("padding", "6px 14px"),
                      #("background", "#1f6feb"),
                      #("color", "#ffffff"),
                      #("border", "none"),
                      #("border-radius", "6px"),
                      #("cursor", "pointer"),
                      #("font-size", "12px"),
                      #("font-weight", "600"),
                    ]),
                  ],
                  [
                    text(
                      "Commit Array to Stream S"
                      <> int.to_string(model.active_stream_slot)
                      <> " (/SS)",
                    ),
                  ],
                ),
              ],
            ),
          ]),
          // Stream Slot Copy (/SC)
          div(
            [
              styles([
                #("display", "flex"),
                #("gap", "8px"),
                #("align-items", "center"),
                #("padding", "10px"),
                #("background", "var(--bg-app, #0d1117)"),
                #("border-radius", "6px"),
                #("border", "1px solid " <> border_color),
              ]),
            ],
            [
              span(
                [
                  styles([
                    #("font-size", "12px"),
                    #("color", text_color),
                    #("font-weight", "600"),
                  ]),
                ],
                [
                  text(
                    "Copy Stream S"
                    <> int.to_string(model.active_stream_slot)
                    <> " to Next Slot:",
                  ),
                ],
              ),
              button(
                [
                  on_click(CopyStreamSlot(
                    model.active_stream_slot,
                    { model.active_stream_slot + 1 } % 16,
                  )),
                  type_("button"),
                  styles([
                    #("padding", "4px 10px"),
                    #("background", btn_bg),
                    #("color", text_color),
                    #("border", btn_border),
                    #("border-radius", "6px"),
                    #("cursor", "pointer"),
                    #("font-size", "11px"),
                  ]),
                ],
                [
                  text(
                    "Copy to S"
                    <> int.to_string({ model.active_stream_slot + 1 } % 16)
                    <> " (/SC)",
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
      // Panel 3: Global Variables ($0..$127) Register Bank
      div(
        [
          styles([
            #("background", card_bg),
            #("border", "1px solid " <> border_color),
            #("border-radius", "8px"),
            #("padding", "16px"),
          ]),
        ],
        [
          div(
            [
              styles([
                #("display", "flex"),
                #("justify-content", "space-between"),
                #("align-items", "center"),
                #("margin-bottom", "14px"),
                #("flex-wrap", "wrap"),
                #("gap", "8px"),
              ]),
            ],
            [
              div([], [
                span(
                  [
                    styles([
                      #("font-size", "15px"),
                      #("font-weight", "700"),
                      #("color", "#58a6ff"),
                      #("display", "block"),
                    ]),
                  ],
                  [
                    text(
                      "🧮 Global Variable Registers (=, a=, s=, *=, /=, $0..$127)",
                    ),
                  ],
                ),
                span(
                  [styles([#("font-size", "12px"), #("color", subtle_color)])],
                  [
                    text(
                      "Real-time expression variables. Store with =<var>,<val>, read as $<var> in Skode.",
                    ),
                  ],
                ),
              ]),
              span(
                [
                  styles([
                    #("font-size", "11px"),
                    #("font-family", "monospace"),
                    #("padding", "3px 8px"),
                    #("border-radius", "4px"),
                    #("background", btn_bg),
                    #("color", "#58a6ff"),
                    #("border", btn_border),
                  ]),
                ],
                [
                  text(
                    int.to_string(dict.size(model.variables))
                    <> " Active Variables",
                  ),
                ],
              ),
            ],
          ),
          // Variable Selector Chips ($0..$15 quick selectors)
          div(
            [
              styles([
                #("display", "grid"),
                #(
                  "grid-template-columns",
                  "repeat(auto-fill, minmax(58px, 1fr))",
                ),
                #("gap", "6px"),
                #("margin-bottom", "14px"),
              ]),
            ],
            list.map(
              [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
              fn(vid) {
                let is_active = model.active_var_id == vid
                let has_val = dict.has_key(model.variables, vid)
                button(
                  [
                    on_click(SelectVariable(vid)),
                    type_("button"),
                    styles([
                      #("padding", "6px 4px"),
                      #("border-radius", "6px"),
                      #("font-size", "12px"),
                      #("cursor", "pointer"),
                      #("font-weight", "600"),
                      #("background", case is_active {
                        True -> "#1f6feb"
                        False -> btn_bg
                      }),
                      #("color", case is_active {
                        True -> "#ffffff"
                        False ->
                          case has_val {
                            True -> "#58a6ff"
                            False -> subtle_color
                          }
                      }),
                      #("border", case is_active {
                        True -> "1px solid #58a6ff"
                        False -> btn_border
                      }),
                    ]),
                  ],
                  [
                    text(case has_val {
                      True -> "● $" <> int.to_string(vid)
                      False -> "$" <> int.to_string(vid)
                    }),
                  ],
                )
              },
            ),
          ),
          // Variable Editor & Math Operations Form
          div(
            [
              styles([
                #("display", "flex"),
                #("gap", "12px"),
                #("align-items", "center"),
                #("flex-wrap", "wrap"),
                #("padding", "12px"),
                #("background", "var(--bg-app, #0d1117)"),
                #("border", btn_border),
                #("border-radius", "6px"),
                #("margin-bottom", "14px"),
              ]),
            ],
            [
              div(
                [
                  styles([
                    #("display", "flex"),
                    #("align-items", "center"),
                    #("gap", "6px"),
                  ]),
                ],
                [
                  span(
                    [styles([#("font-weight", "bold"), #("color", "#58a6ff")])],
                    [
                      text("$" <> int.to_string(model.active_var_id) <> " = "),
                    ],
                  ),
                  input([
                    type_("text"),
                    value(model.var_input_val),
                    on_input(SetVariableInput),
                    styles([
                      #("width", "130px"),
                      #("padding", "6px 10px"),
                      #("border-radius", "6px"),
                      #("border", btn_border),
                      #("background", card_bg),
                      #("color", text_color),
                      #("font-family", "monospace"),
                      #("font-size", "13px"),
                    ]),
                  ]),
                ],
              ),
              button(
                [
                  on_click(SubmitSetVariable(
                    model.active_var_id,
                    parse_float(model.var_input_val, 0.0),
                  )),
                  type_("button"),
                  styles([
                    #("padding", "6px 12px"),
                    #("background", "#1f6feb"),
                    #("color", "#ffffff"),
                    #("border", "none"),
                    #("border-radius", "6px"),
                    #("cursor", "pointer"),
                    #("font-weight", "600"),
                    #("font-size", "12px"),
                  ]),
                ],
                [text("Set (=)")],
              ),
              button(
                [
                  on_click(SubmitOpVariable(
                    "a=",
                    model.active_var_id,
                    parse_float(model.var_input_val, 0.0),
                  )),
                  type_("button"),
                  styles([
                    #("padding", "6px 10px"),
                    #("background", btn_bg),
                    #("color", text_color),
                    #("border", btn_border),
                    #("border-radius", "6px"),
                    #("cursor", "pointer"),
                    #("font-size", "12px"),
                  ]),
                ],
                [text("Add (a=)")],
              ),
              button(
                [
                  on_click(SubmitOpVariable(
                    "s=",
                    model.active_var_id,
                    parse_float(model.var_input_val, 0.0),
                  )),
                  type_("button"),
                  styles([
                    #("padding", "6px 10px"),
                    #("background", btn_bg),
                    #("color", text_color),
                    #("border", btn_border),
                    #("border-radius", "6px"),
                    #("cursor", "pointer"),
                    #("font-size", "12px"),
                  ]),
                ],
                [text("Sub (s=)")],
              ),
              button(
                [
                  on_click(SubmitOpVariable(
                    "*=",
                    model.active_var_id,
                    parse_float(model.var_input_val, 0.0),
                  )),
                  type_("button"),
                  styles([
                    #("padding", "6px 10px"),
                    #("background", btn_bg),
                    #("color", text_color),
                    #("border", btn_border),
                    #("border-radius", "6px"),
                    #("cursor", "pointer"),
                    #("font-size", "12px"),
                  ]),
                ],
                [text("Mul (*=)")],
              ),
              button(
                [
                  on_click(SubmitOpVariable(
                    "/=",
                    model.active_var_id,
                    parse_float(model.var_input_val, 0.0),
                  )),
                  type_("button"),
                  styles([
                    #("padding", "6px 10px"),
                    #("background", btn_bg),
                    #("color", text_color),
                    #("border", btn_border),
                    #("border-radius", "6px"),
                    #("cursor", "pointer"),
                    #("font-size", "12px"),
                  ]),
                ],
                [text("Div (/=)")],
              ),
              button(
                [
                  on_click(ClearVariable(model.active_var_id)),
                  type_("button"),
                  styles([
                    #("padding", "6px 10px"),
                    #("background", btn_bg),
                    #("color", "#f85149"),
                    #("border", btn_border),
                    #("border-radius", "6px"),
                    #("cursor", "pointer"),
                    #("font-size", "12px"),
                  ]),
                ],
                [text("Clear (=0)")],
              ),
            ],
          ),
          // Active Variables Readout Table
          div(
            [
              styles([
                #("display", "grid"),
                #(
                  "grid-template-columns",
                  "repeat(auto-fill, minmax(130px, 1fr))",
                ),
                #("gap", "8px"),
              ]),
            ],
            case dict.size(model.variables) {
              0 -> [
                span(
                  [
                    styles([
                      #("font-size", "12px"),
                      #("color", subtle_color),
                      #("font-style", "italic"),
                    ]),
                  ],
                  [
                    text(
                      "No custom variables assigned yet. Use the controls above or type =0,440 in the console.",
                    ),
                  ],
                ),
              ]
              _ ->
                dict.to_list(model.variables)
                |> list.sort(fn(a, b) { int.compare(a.0, b.0) })
                |> list.map(fn(pair) {
                  let #(vid, val) = pair
                  div(
                    [
                      on_click(SelectVariable(vid)),
                      styles([
                        #("padding", "8px 10px"),
                        #("background", "var(--bg-app, #0d1117)"),
                        #("border", btn_border),
                        #("border-radius", "6px"),
                        #("cursor", "pointer"),
                        #("display", "flex"),
                        #("justify-content", "space-between"),
                        #("align-items", "center"),
                      ]),
                    ],
                    [
                      span(
                        [
                          styles([
                            #("font-family", "monospace"),
                            #("font-weight", "bold"),
                            #("color", "#58a6ff"),
                            #("font-size", "12px"),
                          ]),
                        ],
                        [text("$" <> int.to_string(vid))],
                      ),
                      span(
                        [
                          styles([
                            #("font-family", "monospace"),
                            #("color", text_color),
                            #("font-size", "12px"),
                          ]),
                        ],
                        [text(param.format_float(val))],
                      ),
                    ],
                  )
                })
            },
          ),
        ],
      ),
    ],
  )
}

// -----------------------------------------------------------------------------
// Main View
// -----------------------------------------------------------------------------

pub fn view(model: Model) -> Element(Msg) {
  let skode_cmd = voice_gen.to_skode(model.voice)
  let #(
    bg_app,
    bg_card,
    bg_subtle,
    bg_input,
    border,
    border_muted,
    text_pri,
    text_sec,
    text_mut,
  ) = case model.theme {
    ThemeDark -> #(
      "#0d1117",
      "#161b22",
      "#21262d",
      "#0d1117",
      "#30363d",
      "#21262d",
      "#f0f6fc",
      "#c9d1d9",
      "#8b949e",
    )
    ThemeLight -> #(
      "#f6f8fa",
      "#ffffff",
      "#f0f2f5",
      "#ffffff",
      "#d0d7de",
      "#e1e4e8",
      "#1f2328",
      "#24292f",
      "#656d76",
    )
  }

  div(
    [
      attribute.attribute("data-theme", case model.theme {
        ThemeDark -> "dark"
        ThemeLight -> "light"
      }),
      styles([
        #("background", bg_app),
        #("min-height", "100vh"),
        #("color", text_sec),
        #("--bg-app", bg_app),
        #("--bg-card", bg_card),
        #("--bg-card-subtle", bg_subtle),
        #("--bg-input", bg_input),
        #("--border", border),
        #("--border-muted", border_muted),
        #("--text-primary", text_pri),
        #("--text-secondary", text_sec),
        #("--text-muted", text_mut),
        #("transition", "background 0.2s ease, color 0.2s ease"),
      ]),
    ],
    [
      div(
        [
          styles([
            #("max-width", "1100px"),
            #("margin", "0 auto"),
            #("padding", "24px"),
            #("font-family", "system-ui, -apple-system, sans-serif"),
          ]),
        ],
        [
          // Top Studio Header
          render_studio_header(model),
          // Master Bar (Volume, Tempo, Pointers, Auto-Sync)
          render_master_bar(model),
          // Mode Switcher Tabs (Voice Studio, Pattern Sequencer, Delay Matrix, KSynth)
          render_mode_switcher(model),
          // Notification Alert
          render_notification_banner(model),
          // Universal Live Skode Command Input & Output Terminal
          render_skode_command_entry(model, skode_cmd),
          // Mode-specific Canvas
          case model.editor_mode {
            ModeVoices -> render_voice_studio(model)
            ModePatterns -> render_pattern_sequencer(model)
            ModeDelays -> render_delay_matrix(model)
            ModeMacros -> render_macro_studio(model)
            ModeKSynth -> render_ksynth_studio(model)
            ModeAudioMidi -> render_audio_midi_studio(model)
            ModeFiles -> render_files_studio(model)
            ModeStreams -> render_streams_studio(model)
          },
          // Footer
          render_studio_footer(model),
        ],
      ),
    ],
  )
}

// -----------------------------------------------------------------------------
// App Entry
// -----------------------------------------------------------------------------

pub fn main() {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)
}
