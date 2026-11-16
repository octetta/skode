# Skode Voice Editor

A reactive web interface built with **Lustre 5** and **Gleam** for real-time visualization and parameter control of the **Pulp 0.85.0** audio engine.

## Overview

The editor is fully integrated with the code-generated schema models emitted by `tools/mksynth.c`:
- **Schema-Driven Data Models**: Operates on `skode/gen/voice_gen.gleam` (`VoiceState`) and clamps parameters using `skode/gen/param_gen.gleam`.
- **Differential Streaming**: Computes precise Skode text commands on state changes using `skode/gen/diff_gen.gleam` (`diff_voice_skode`) to transmit delta changes over WASM/IPC/WebSocket without full serialization overhead.
- **Bi-directional Formatter Integration**: Live view of formatted voice state using `to_skode`.
- **Prescriptive Modular Tabs**:
  - **Oscillator**: Wave tables (including ESQ-1, PRNG noise, DWG), tune, coarse/fine pitch, pitch mode, portamento, hard sync master/slave assignments.
  - **Filter**: Filter type (Biquad/Moog ladder), cutoff, resonance, filter envelopes, tracking.
  - **Envelope & Mix**: Amp attack/decay/sustain/release, amp bend, levels, smoother smoothing.
  - **Modulation**: LFO waveforms, rates, depths, matrix routing.
  - **Links & Sync**: Hard sync links, FM routing, ring mod, audio input routing.

## Running Locally

Run the local server script:

```bash
./serve.sh [port]   # defaults to 8000
```

Then open `http://localhost:8000` in any modern web browser.

## Integration Modes

1. **Standalone / Copy Mode**:
   - Tweak sliders and knobs visually.
   - Click **"Copy Skode"** or **"Copy All"** to paste the generated Skode commands into `mini-skred`, terminal repl, or your score files.
2. **Embedded WASM / Bridge Mode**:
   - If embedded in a page with `window.skred_command(cmd)` or Emscripten's `Module.ccall`, the editor automatically dispatches diff opcodes directly to the C audio engine in real time with sub-millisecond response.
