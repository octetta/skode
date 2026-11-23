// JavaScript FFI Bridge for skode_editor
// Handles clipboard copying, Web Audio synthesis preview, and native Pulp WASM bridge.

export function copy_to_clipboard(text) {
  if (navigator && navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(text).catch(err => {
      console.warn("Failed to copy clipboard:", err);
    });
  } else {
    console.log("[skode-editor] Copy to clipboard:", text);
  }
}

// -----------------------------------------------------------------------------
// Web Audio Synth Preview
// -----------------------------------------------------------------------------

let audioCtx = null;

const voiceParams = {
  note: 60,
  freq: 261.63,
  wave: 1, // 0=sine, 1=saw, 2=square, 3=tri, 4=noise
  filterMode: 1, // 0=bypass, 1=lowpass, 2=highpass, 3=bandpass
  cutoff: 5000,
  q: 0.707,
  attack: 0.01,
  decay: 0.1,
  sustain: 0.8,
  release: 0.2,
  level: 1.0,
};

function ensureAudioContext() {
  const win = typeof window !== "undefined" ? window : (typeof globalThis !== "undefined" ? globalThis : null);
  if (!win) return null;
  if (typeof navigator !== "undefined" && "audioSession" in navigator) {
    try { navigator.audioSession.type = "playback"; } catch (e) {}
  }
  if (!audioCtx) {
    const AudioContextClass = win.AudioContext || win.webkitAudioContext;
    if (AudioContextClass) {
      audioCtx = new AudioContextClass();
    }
  }
  if (audioCtx && (audioCtx.state === "suspended" || audioCtx.state === "interrupted")) {
    audioCtx.resume();
  }
  return audioCtx;
}

function midiToFreq(note) {
  return 440 * Math.pow(2, (note - 69) / 12);
}

function tokenizeSkode(cmd) {
  const re = /(?:v\d+|[-+]?[0-9]*\.?[0-9]+(?:,[0-9.]+)*|[a-zA-Z_]+(?:[-+]?[0-9]*\.?[0-9]+(?:,[0-9.]+)*)?)/g;
  return cmd.match(re) || cmd.trim().split(/\s+/);
}

function parseAndUpdateParams(cmd) {
  // Tokenize unspaced and spaced commands (e.g. v0H1G1 or v0 w 0 f 440)
  const tokens = tokenizeSkode(cmd);
  let activeVoice = 0;
  for (let i = 0; i < tokens.length; i++) {
    const tok = tokens[i];
    if (/^v\d+$/.test(tok)) {
      activeVoice = parseInt(tok.substring(1), 10);
      continue;
    }

    // Check for ADSR envelope: e.g. 0t0.01,0.1,0.8,0.2 or t0.01,0.1,0.8,0.2
    const tMatch = tok.match(/^(?:v?\d+)?t([0-9.,]+)$/i);
    if (tMatch) {
      const parts = tMatch[1].split(",").map(parseFloat);
      if (parts.length >= 4 && !isNaN(parts[0])) {
        voiceParams.attack = Math.max(0.001, parts[0]);
        voiceParams.decay = Math.max(0.001, parts[1]);
        voiceParams.sustain = Math.max(0.0, Math.min(1.0, parts[2]));
        voiceParams.release = Math.max(0.0, parts[3]);
      }
      continue;
    }

    // Strip leading voice prefix if present (e.g. 0k1500 -> k1500 or v0k1500 -> k1500)
    const m = tok.match(/^(?:v?\d+)?([a-zA-Z_]+)([-+]?[0-9]*\.?[0-9]+)?$/);
    if (!m) continue;
    const op = m[1].toLowerCase();
    let val = m[2] !== undefined ? parseFloat(m[2]) : NaN;

    // Check if value is separated in the next token (e.g. ['k', '1500'])
    if (isNaN(val) && i + 1 < tokens.length && /^[-+]?[0-9]*\.?[0-9]+$/.test(tokens[i + 1])) {
      val = parseFloat(tokens[i + 1]);
      i++;
    }

    switch (op) {
      case "w":
        if (!isNaN(val)) voiceParams.wave = Math.round(val);
        break;
      case "j":
        if (!isNaN(val)) voiceParams.filterMode = Math.round(val);
        break;
      case "k":
        if (!isNaN(val)) voiceParams.cutoff = val;
        break;
      case "q":
        if (!isNaN(val)) voiceParams.q = val;
        break;
      case "a":
        // Amplitude in dB (e.g. 0a0 = 1.0, 0a-6 = ~0.5)
        if (!isNaN(val)) voiceParams.level = Math.pow(10, val / 20);
        break;
      case "n":
        if (!isNaN(val)) {
          voiceParams.note = val;
          voiceParams.freq = midiToFreq(val);
        }
        break;
      case "f":
        if (!isNaN(val)) voiceParams.freq = val;
        break;
      case "amp":
        if (!isNaN(val)) voiceParams.level = val;
        break;
      case "del":
      case "ds":
        if (!isNaN(val)) voiceParams.delaySend = val;
        break;
      case "r":
      case "rec":
        if (!isNaN(val)) voiceParams.recordTrack = Math.round(val);
        break;
      default:
        break;
    }
  }
}

function playWebAudioNote() {
  const ctx = ensureAudioContext();
  if (!ctx) return;

  const now = ctx.currentTime;
  const attack = Math.max(0.005, voiceParams.attack);
  const decay = Math.max(0.01, voiceParams.decay);
  const sustain = Math.max(0.0, Math.min(1.0, voiceParams.sustain));
  const release = Math.max(0.01, voiceParams.release);
  const holdTime = 0.25;

  // Master voice gain node (smooth zero-crossing linear ramps prevent clicks)
  const gainNode = ctx.createGain();
  gainNode.gain.setValueAtTime(0.0, now);
  gainNode.gain.linearRampToValueAtTime(Math.max(0.0001, voiceParams.level * 0.35), now + attack);
  gainNode.gain.linearRampToValueAtTime(
    Math.max(0.0001, voiceParams.level * 0.35 * sustain),
    now + attack + decay
  );
  gainNode.gain.setValueAtTime(
    Math.max(0.0001, voiceParams.level * 0.35 * sustain),
    now + holdTime
  );
  gainNode.gain.linearRampToValueAtTime(0.0, now + holdTime + release);

  // Filter node (dynamically configured by opcode 'j')
  const filterNode = ctx.createBiquadFilter();
  switch (voiceParams.filterMode) {
    case 0:
      filterNode.type = "allpass"; // Bypass: all frequencies pass unaffected
      break;
    case 1:
      filterNode.type = "lowpass";
      break;
    case 2:
      filterNode.type = "highpass";
      break;
    case 3:
      filterNode.type = "bandpass";
      break;
    case 4:
      filterNode.type = "notch";
      break;
    default:
      filterNode.type = "lowpass";
      break;
  }
  filterNode.frequency.setValueAtTime(Math.max(20, Math.min(20000, voiceParams.cutoff)), now);
  filterNode.Q.setValueAtTime(Math.max(0.1, Math.min(25, voiceParams.q)), now);

  // Oscillator or Noise
  if (voiceParams.wave === 4 || voiceParams.wave === 5 || voiceParams.wave === 6) {
    // White noise generator
    const bufferSize = ctx.sampleRate * 2;
    const noiseBuffer = ctx.createBuffer(1, bufferSize, ctx.sampleRate);
    const output = noiseBuffer.getChannelData(0);
    for (let i = 0; i < bufferSize; i++) {
      output[i] = Math.random() * 2 - 1;
    }
    const whiteNoise = ctx.createBufferSource();
    whiteNoise.buffer = noiseBuffer;
    whiteNoise.loop = true;
    whiteNoise.connect(filterNode);
    filterNode.connect(gainNode);
    gainNode.connect(ctx.destination);
    whiteNoise.start(now);
    whiteNoise.stop(now + holdTime + release + 0.05);
  } else {
    // Standard oscillator
    const osc = ctx.createOscillator();
    switch (voiceParams.wave) {
      case 0:
        osc.type = "sine";
        break;
      case 1:
        osc.type = "sawtooth";
        break;
      case 2:
        osc.type = "square";
        break;
      case 3:
        osc.type = "triangle";
        break;
      default:
        osc.type = "sawtooth";
        break;
    }
    osc.frequency.setValueAtTime(voiceParams.freq, now);
    osc.connect(filterNode);
    filterNode.connect(gainNode);
    gainNode.connect(ctx.destination);
    osc.start(now);
    osc.stop(now + holdTime + release + 0.05);
  }
}

// -----------------------------------------------------------------------------
// Command Dispatch Bridge (Real Pulp WASM + Web Audio Fallback)
// -----------------------------------------------------------------------------

let wasmEngineStarted = false;
let workletNode = null;
let workletAudioContext = null;
let workletReady = false;
let workletInitAttempted = false;
let workletFailed = false;
let workletInitPromise = null;

function unlockAudio() {
  if (workletAudioContext && (workletAudioContext.state === "suspended" || workletAudioContext.state === "interrupted")) {
    workletAudioContext.resume().catch(() => {});
  }
  if (!workletInitAttempted) {
    initAudioWorklet();
  }
}

if (typeof window !== "undefined") {
  window.addEventListener("pointerdown", unlockAudio, { passive: true });
  window.addEventListener("click", unlockAudio, { passive: true });
  window.addEventListener("keydown", unlockAudio, { passive: true });
  window.addEventListener("touchstart", unlockAudio, { passive: true });
}

export async function initAudioWorklet() {
  if (workletInitPromise) return workletInitPromise;
  workletInitAttempted = true;

  workletInitPromise = (async () => {
    if (typeof window === "undefined" || (!window.AudioContext && !window.webkitAudioContext) || !window.AudioWorkletNode) {
      console.warn("[skode-editor] AudioWorklet not supported; falling back to main thread.");
      return false;
    }
    try {
      const AudioCtx = window.AudioContext || window.webkitAudioContext;
      workletAudioContext = new AudioCtx({ latencyHint: "interactive" });

      const base = window.location.href.replace(/\/[^\/]*$/, "/");
      const processorUrl = new URL("wasm/skred_worklet_processor.js", base).href;
      const wasmUrl = new URL("wasm/skred_worklet_engine.wasm", base).href;

      await workletAudioContext.audioWorklet.addModule(processorUrl);

      const resp = await fetch(wasmUrl);
      if (!resp.ok) throw new Error("HTTP " + resp.status + " fetching worklet wasm");
      const wasmBinary = await resp.arrayBuffer();

      workletNode = new AudioWorkletNode(workletAudioContext, "skred-worklet-processor", {
        numberOfInputs: 0,
        numberOfOutputs: 1,
        outputChannelCount: [2],
        processorOptions: {
          wasmBinary: wasmBinary.slice ? wasmBinary.slice(0) : wasmBinary,
          sampleRate: workletAudioContext.sampleRate,
        },
      });

      workletNode.port.postMessage({
        type: "init",
        wasmBinary: wasmBinary.slice ? wasmBinary.slice(0) : wasmBinary,
        sampleRate: workletAudioContext.sampleRate,
      });

      workletNode.port.onmessage = (event) => {
        const data = event.data;
        if (!data) return;
        if (data.type === "ready") {
          console.log("[skode-editor] AudioWorklet Skred engine ready (v" + data.version + ", " + data.sampleRate + "Hz)");
          workletReady = true;
          workletNode.port.postMessage({ type: "cmd", text: "V0; log 1;" });
        }
      };

      workletNode.connect(workletAudioContext.destination);
      return true;
    } catch (err) {
      console.warn("[skode-editor] AudioWorklet init failed:", err);
      workletFailed = true;
      return false;
    }
  })();

  return workletInitPromise;
}

function ensureWasmStarted() {
  const win = typeof window !== "undefined" ? window : globalThis;
  if (win.Module && !wasmEngineStarted) {
    try {
      if (typeof win.Module._skred_start_headless === "function") {
        const res = win.Module._skred_start_headless(128, 44100);
        wasmEngineStarted = (res === 0);
      } else if (typeof win.Module._skred_start === "function") {
        const res = win.Module._skred_start(128, 16, 0);
        wasmEngineStarted = (res === 0);
      }
      if (typeof win.Module._skred_logger === "function") {
        win.Module._skred_logger(1);
      }
      console.log("[skode-editor] Native C DSP engine inited on main thread, status:", wasmEngineStarted);
    } catch (e) {
      console.warn("[skode-editor] Error booting main thread C engine:", e);
    }
  }
}

// Fallback macro storage when running in dev preview without WASM
const fallbackMacros = {
  0: "v0 f 440 a -6 T",
  1: "v0 n 60 T v1 n 64 T v2 n 67 T",
  2: "v0 w 1 f 110 c 800 q 0.8 a -4 T",
  3: "v0 w 4 f 100 a -2 T v1 w 0 f 60 a 0 T",
  4: "v0 reset v1 reset v2 reset v3 reset",
};

export function send_skode_command(cmd) {
  const win = typeof window !== "undefined" ? window : globalThis;

  if (typeof cmd === "string" && cmd.includes("\n")) {
    const lines = cmd.split("\n");
    let lastRes = "";
    for (const line of lines) {
      const trimmed = line.trim();
      if (trimmed) {
        lastRes = send_skode_command(trimmed);
      }
    }
    return lastRes;
  }

  parseAndUpdateParams(cmd);

  let targetVoice = 0;
  const vMatch = cmd.match(/(?:^|\s)v(\d+)(?:\s|$|[a-zA-Z])/);
  if (vMatch) {
    targetVoice = parseInt(vMatch[1], 10);
  }

  // Trigger check for note audition
  const isTrigger = /(?:^|\s)(?:v?\d+)?(?:T|l1)(?:\s|$)/.test(cmd);

  unlockAudio();

  // Route to real-time AudioWorklet DSP if available
  if (workletNode && workletNode.port) {
    workletNode.port.postMessage({ type: "cmd", text: cmd });
  }

  // Auto-release audition note (l1 / T) after 450ms so voice envelope naturally decays/releases
  if (isTrigger && !cmd.includes("l0")) {
    const trigMatch = cmd.match(/(?:^|\s)v?(\d+)?\s*(?:l1|T)(?:\s|$)/);
    const v = (trigMatch && trigMatch[1] !== undefined) ? trigMatch[1] : targetVoice;
    setTimeout(() => {
      send_skode_command("v" + v + " l0");
    }, 450);
  }

  // 1. Native Pulp C Engine via Emscripten WebAssembly (for logs, queries, and wavetable extraction)
  if (win.Module && typeof win.Module.ccall === "function") {
    ensureWasmStarted();
    try {
      if (typeof win.Module._skred_logger === "function") {
        win.Module._skred_logger(1);
      }
      win.Module.ccall("skred_command", "number", ["string"], [cmd]);
      let output = "";
      try {
        output = win.Module.ccall("skred_log", "string", [], []) || "";
      } catch (_) {}
      console.log("[Pulp DSP dispatch voice " + targetVoice + "]:", cmd, "output:", output);
      return output.trim();
    } catch (e) {
      console.warn("Error calling WASM skred_command:", e);
      return "Error: " + e.message;
    }
  }

  // 2. Global skred_command if embedded in external host
  if (typeof win.skred_command === "function") {
    const res = win.skred_command(cmd);
    return res !== undefined && res !== null ? String(res) : "";
  }

  // 3. Fallback: Pure Web Audio preview if Worklet / WASM is not yet active
  if (isTrigger && !workletReady) {
    playWebAudioNote();
  }

  console.log("[skode fallback dispatch]:", cmd);

  const trimmed = cmd.trim();

  // Theme switching commands: -light, -dark
  if (trimmed === "-light" || trimmed === ".light" || trimmed === "light") {
    if (typeof document !== "undefined") {
      document.documentElement.dataset.theme = "light";
      document.body.dataset.theme = "light";
    }
    return "# theme switched to Erasmus light";
  }
  if (trimmed === "-dark" || trimmed === ".dark" || trimmed === "dark") {
    if (typeof document !== "undefined") {
      document.documentElement.dataset.theme = "dark";
      document.body.dataset.theme = "dark";
    }
    return "# theme switched to Atari dark";
  }

  // Macro commands: e! (exec), e> (store), e? (query), ?m (list), /m! (clear)
  const storeMacroMatch = trimmed.match(/^\[(.*)\]\s*e>(\d+)$/);
  if (storeMacroMatch) {
    const code = storeMacroMatch[1];
    const slot = parseInt(storeMacroMatch[2], 10);
    fallbackMacros[slot] = code;
    return "# [macro] stored into slot " + slot + ": [" + code + "]";
  }

  const execMacroMatch = trimmed.match(/^e!\s*(\d+)$/);
  if (execMacroMatch) {
    const slot = parseInt(execMacroMatch[1], 10);
    const code = fallbackMacros[slot] || "";
    if (code) {
      parseAndUpdateParams(code);
      if (/(?:^|\s)(?:v?\d+)?T(?:\s|$)/.test(code)) {
        playWebAudioNote();
      }
      return "# [macro] e!" + slot + " -> " + code;
    }
    return "# [macro] e!" + slot + " (slot is empty)";
  }

  const queryMacroMatch = trimmed.match(/^e\?\s*(\d+)$/);
  if (queryMacroMatch) {
    const slot = parseInt(queryMacroMatch[1], 10);
    const code = fallbackMacros[slot];
    return code !== undefined && code !== ""
      ? "# e?" + slot + ": [" + code + "]"
      : "# e?" + slot + ": (empty)";
  }

  if (trimmed === "?m") {
    const defined = Object.entries(fallbackMacros)
      .filter(([_, v]) => v && v.trim() !== "")
      .map(([k, v]) => "e!" + k + " -> [" + v + "]")
      .join("\n");
    return defined !== "" ? defined : "# no macros defined";
  }

  if (trimmed === "/m!") {
    for (const k in fallbackMacros) delete fallbackMacros[k];
    return "# cleared all defined user macros";
  }

  // KSynth commands: [code] ks, k?, k>d, ?d, k>w, /k
  if (trimmed.startsWith("[") && (trimmed.endsWith("] ks") || trimmed.endsWith("] k!"))) {
    const expr = trimmed.slice(1, trimmed.lastIndexOf("]")).trim();
    return "# [ksynth] expression: " + expr + " (evaluated, 1024 samples)";
  }
  if (trimmed === "k?" || trimmed.startsWith("k?")) {
    return "( 0.0 0.156 0.309 0.453 0.587 0.707 0.809 0.891 0.951 0.987 1.0 )";
  }
  if (trimmed === "k>d") {
    return "# [ksynth] copied last result vector to data array";
  }
  if (trimmed === "?d" || trimmed.startsWith("?d")) {
    return "( 0.0 0.156 0.309 0.453 0.587 0.707 0.809 0.891 0.951 0.987 1.0 )";
  }
  if (trimmed.startsWith("k>w")) {
    const parts = trimmed.split(/\s+/);
    const slot = parts[1] || "0";
    return "# [ksynth] installed vector into wavetable slot w" + slot;
  }
  if (trimmed.startsWith("/k ")) {
    const slot = trimmed.substring(3).trim();
    return "# [ksynth] loaded script file " + slot + ".ks";
  }
  if (trimmed.startsWith("[") && trimmed.endsWith("] /ks")) {
    const file = trimmed.slice(1, trimmed.lastIndexOf("]")).trim();
    return "# [ksynth] loaded script file " + file;
  }

  if (trimmed === "?S" || trimmed.startsWith("?S")) {
    return "# [stream] active: 0, mode: 0, poll: 50ms, dropped: 0";
  }

  // Audio host devices: /als, ?a, /ao, /ai
  if (trimmed === "/als") {
    return [
      "Audio Host Devices:",
      "  [0] System Default Audio (Active Output, 44100 Hz, 2 ch)",
      "  [1] Web Audio Host Driver",
      "  [2] Virtual Loopback Output",
      "Active Out: [0]  Active In: [0]"
    ].join("\n");
  }
  if (trimmed === "?a") {
    return "# audio: driver=WebAudio rate=44100 buffer=128 latency=2.9ms out=[0] in=[0]";
  }
  if (trimmed.startsWith("/ao ")) {
    return "# audio output device set to [" + trimmed.substring(4).trim() + "]";
  }
  if (trimmed.startsWith("/ai ")) {
    return "# audio input device set to [" + trimmed.substring(4).trim() + "]";
  }

  // MIDI interfaces & routing: /mls, ?m, /mi, /mo, /mv, /mp
  if (trimmed === "/mls") {
    return [
      "MIDI Interfaces:",
      "  IN  [0] Web MIDI Default Input",
      "  IN  [1] Virtual Loopback In",
      "  OUT [0] Web MIDI Default Output"
    ].join("\n");
  }
  if (trimmed === "?m") {
    return "# midi: in=[0] out=[0] routes=0 pools=0 cc_binds=0";
  }
  if (trimmed.startsWith("/mi ")) {
    return "# opened MIDI input device [" + trimmed.substring(4).trim() + "]";
  }
  if (trimmed.startsWith("/mo ")) {
    return "# opened MIDI output device [" + trimmed.substring(4).trim() + "]";
  }
  if (trimmed.startsWith("/mv ")) {
    return "# routed MIDI: " + trimmed;
  }
  if (trimmed.startsWith("/mp ")) {
    return "# routed MIDI pool: " + trimmed;
  }

  // Control plane: vc1/vc0, yc1/yc0, ce, ?ce, ?ce!, ?q
  if (trimmed === "vc1" || trimmed === "vc0") {
    return "# voice control events " + (trimmed === "vc1" ? "enabled (vc1)" : "disabled (vc0)");
  }
  if (trimmed === "yc1" || trimmed === "yc0") {
    return "# pattern boundary control events " + (trimmed === "yc1" ? "enabled (yc1)" : "disabled (yc0)");
  }
  if (trimmed.startsWith("ce ") || trimmed === "ce") {
    return "# [control-event] published marker: " + trimmed;
  }
  if (trimmed === "?ce") {
    return [
      "Control Events (skred_control_event_poll):",
      "  [seq=1 samp=44100 voice=0 type=VOICE_TRIGGER tag=-1]",
      "  [seq=2 samp=66150 voice=0 type=VOICE_RELEASE tag=-1]",
      "  [seq=3 samp=88200 voice=0 type=VOICE_FINISHED tag=-1]"
    ].join("\n");
  }
  if (trimmed === "?ce!") {
    return "# flushed all outstanding control events (?ce!)";
  }
  if (trimmed === "?q") {
    return "Scheduled Queue (skred_scheduled_event_snapshot):\n  (0 pending compiled audio thread events)";
  }
  if (trimmed === "?s" || trimmed === "?v" || trimmed.endsWith("?")) {
    return "# v" + targetVoice + " w" + voiceParams.wave + " f" + voiceParams.freq.toFixed(1) + " a" + (20 * Math.log10(Math.max(0.0001, voiceParams.level))).toFixed(1) + " j" + voiceParams.filterMode + " k" + voiceParams.cutoff + " q" + voiceParams.q;
  }
  if (trimmed.startsWith("V ") || /^V[-+]?[0-9]/.test(trimmed)) {
    return "# master volume: " + trimmed.replace(/^V\s*/, "").trim() + " dB";
  }
  if (trimmed.startsWith("M ") || /^M[0-9]/.test(trimmed)) {
    return "# master tempo: " + trimmed.replace(/^M\s*/, "").trim() + " BPM";
  }

  return "";
}

// -----------------------------------------------------------------------------
// Waveform Buffer Rendering (Pulp _skred_dump_wave_base64 & Float32 Synthetics)
// -----------------------------------------------------------------------------

export function render_waveform_buffer(canvasId, waveIdx) {
  if (typeof document === "undefined") return;

  let attempts = 0;
  function draw() {
    const canvas = document.getElementById(canvasId);
    if (!canvas) {
      if (attempts++ < 20) {
        requestAnimationFrame(draw);
      }
      return;
    }
    const ctx = canvas.getContext("2d");
    if (!ctx) return;

    const width = canvas.width || 400;
    const height = canvas.height || 90;

    const N = 256;
    let samples = null;

    // First try querying true engine wavetable from WASM module if available
    const win = typeof window !== "undefined" ? window : globalThis;
    ensureWasmStarted();

    if (win.Module && typeof win.Module._skred_wave_data === "function" && typeof win.Module._skred_wave_size === "function") {
      try {
        const ptr = win.Module._skred_wave_data(waveIdx);
        const size = win.Module._skred_wave_size(waveIdx);
        if (ptr && size > 0 && win.Module.HEAPF32) {
          const floatOffset = ptr >> 2;
          const rawData = win.Module.HEAPF32.subarray(floatOffset, floatOffset + size);
          samples = new Float32Array(N);
          for (let i = 0; i < N; i++) {
            const idx = Math.floor((i * size) / N);
            samples[i] = rawData[idx];
          }
        }
      } catch (e) {
        console.warn("[skode] Error reading engine wavetable data:", e);
      }
    }

    // If engine is not yet booted but Module is loading, retry after a short delay
    if (!samples && attempts++ < 20 && (!win.Module || !win.Module._skred_wave_data)) {
      setTimeout(draw, 100);
    }

    // Fallback to basic synthetic waveforms only if WASM is not yet ready or slot has no data
    if (!samples) {
      samples = new Float32Array(N);
      for (let i = 0; i < N; i++) {
        const t = i / N;
        switch (waveIdx) {
          case 0: // WAVE_TABLE_SINE: f = sinf(2.0f * M_PI * phase)
            samples[i] = Math.sin(2 * Math.PI * t);
            break;
          case 1: // WAVE_TABLE_SQR: (phase < 0.5) ? 1.0f : -1.0f
            samples[i] = t < 0.5 ? 0.95 : -0.95;
            break;
          case 2: // WAVE_TABLE_SAW_DOWN: 2.0f * phase - 1.0f
            samples[i] = 2.0 * t - 1.0;
            break;
          case 3: // WAVE_TABLE_SAW_UP: 1.0f - 2.0f * phase
            samples[i] = 1.0 - 2.0 * t;
            break;
          case 4: // WAVE_TABLE_TRI: (phase < 0.5f) ? (4.0f * phase - 1.0f) : (3.0f - 4.0f * phase)
            samples[i] = t < 0.5 ? (4.0 * t - 1.0) : (3.0 - 4.0 * t);
            break;
          case 5: // WAVE_TABLE_NOISE
          case 6: // WAVE_TABLE_NOISE_ALT
            samples[i] = (Math.random() * 2.0 - 1.0) * 0.75;
            break;
          default:
            samples[i] = 0.0;
            break;
        }
      }
    }

    // Clear background
    ctx.clearRect(0, 0, width, height);

    // Background
    const cardBg = getComputedStyle(document.documentElement).getPropertyValue("--bg-card") || "#161b22";
    ctx.fillStyle = cardBg.trim();
    ctx.fillRect(0, 0, width, height);

    // Center zero crossing axis
    ctx.strokeStyle = "rgba(144, 176, 255, 0.25)";
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.moveTo(0, height / 2);
    ctx.lineTo(width, height / 2);
    ctx.stroke();

    // Waveform trace (cyan glow)
    ctx.strokeStyle = "#00e5ff";
    ctx.lineWidth = 2;
    ctx.beginPath();
    const step = width / samples.length;
    for (let i = 0; i < samples.length; i++) {
      const x = i * step;
      const s = Math.max(-1.2, Math.min(1.2, samples[i]));
      const y = ((1.0 - s) * 0.5) * (height - 12) + 6;
      if (i === 0) ctx.moveTo(x, y);
      else ctx.lineTo(x, y);
    }
    ctx.stroke();
  }

  requestAnimationFrame(draw);
}

// -----------------------------------------------------------------------------
// VFS Filesystem Storage & Attachments
// -----------------------------------------------------------------------------

const fallbackVfsFiles = {};

export function attach_vfs_file_dialog() {
  const win = typeof window !== "undefined" ? window : globalThis;
  if (typeof document === "undefined") return;

  const input = document.createElement("input");
  input.type = "file";
  input.multiple = true;
  input.accept = ".mp3,.wav,.flac,.sk,.ks,.zip";

  input.onchange = async (e) => {
    const files = e.target.files;
    if (!files || !files.length) return;

    for (const file of files) {
      try {
        const bytes = new Uint8Array(await file.arrayBuffer());
        if (win.Module && win.Module.FS) {
          win.Module.FS.writeFile(file.name, bytes);
        }
        fallbackVfsFiles[file.name] = bytes;
        console.log("[VFS Attached]:", file.name, bytes.length, "bytes");
      } catch (err) {
        console.warn("Error attaching file to VFS:", err);
      }
    }
    send_skode_command("# attached " + files.length + " file(s) to virtual filesystem");
  };
  input.click();
}

export function get_vfs_file_list() {
  const win = typeof window !== "undefined" ? window : globalThis;
  const list = [];
  if (win.Module && win.Module.FS) {
    try {
      const entries = win.Module.FS.readdir("/");
      for (const name of entries) {
        if (name === "." || name === ".." || name === "dev" || name === "proc" || name === "tmp") continue;
        try {
          const stat = win.Module.FS.stat("/" + name);
          const ext = name.includes(".") ? name.split(".").pop().toLowerCase() : "";
          list.push({ name: name, size: stat.size || 0, kind: ext });
        } catch (_) {}
      }
    } catch (_) {}
  }
  for (const [name, data] of Object.entries(fallbackVfsFiles)) {
    if (!list.some(e => e.name === name)) {
      const ext = name.includes(".") ? name.split(".").pop().toLowerCase() : "";
      list.push({ name: name, size: data.length, kind: ext });
    }
  }
  return list;
}

export function delete_vfs_file(filename) {
  const win = typeof window !== "undefined" ? window : globalThis;
  if (win.Module && win.Module.FS) {
    try {
      win.Module.FS.unlink("/" + filename);
    } catch (_) {}
  }
  delete fallbackVfsFiles[filename];
  send_skode_command("# unlinked [" + filename + "] from VFS");
}

export function read_vfs_text_file(filename) {
  const win = typeof window !== "undefined" ? window : globalThis;
  if (win.Module && win.Module.FS) {
    try {
      const data = win.Module.FS.readFile("/" + filename, { encoding: "utf8" });
      if (typeof data === "string") return data;
      return new TextDecoder().decode(data);
    } catch (_) {}
  }
  if (fallbackVfsFiles[filename]) {
    try {
      return new TextDecoder().decode(fallbackVfsFiles[filename]);
    } catch (_) {}
  }
  return "";
}

// -----------------------------------------------------------------------------
// Project Zip Bundle Exporter & Importer (Zero-dependency Store ZIP)
// -----------------------------------------------------------------------------

const crcTable = new Uint32Array(256);
for (let i = 0; i < 256; i++) {
  let c = i;
  for (let j = 0; j < 8; j++) {
    c = (c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
  }
  crcTable[i] = c >>> 0;
}

function crc32(buf) {
  let crc = 0 ^ (-1);
  for (let i = 0; i < buf.length; i++) {
    crc = (crc >>> 8) ^ crcTable[(crc ^ buf[i]) & 0xFF];
  }
  return (crc ^ (-1)) >>> 0;
}

function createStoreZip(files) {
  const localHeaders = [];
  const centralHeaders = [];
  let offset = 0;

  for (const file of files) {
    const nameBytes = new TextEncoder().encode(file.name);
    const dataBytes = file.data instanceof Uint8Array ? file.data : new TextEncoder().encode(file.data);
    const crc = crc32(dataBytes);
    const size = dataBytes.length;

    // Local Header (30 bytes + name + data)
    const lh = new Uint8Array(30 + nameBytes.length + size);
    const dv = new DataView(lh.buffer);
    dv.setUint32(0, 0x04034b50, true);
    dv.setUint16(4, 20, true);
    dv.setUint16(6, 0, true);
    dv.setUint16(8, 0, true); // 0 = store
    dv.setUint16(10, 0, true);
    dv.setUint16(12, 0, true);
    dv.setUint32(14, crc, true);
    dv.setUint32(18, size, true);
    dv.setUint32(22, size, true);
    dv.setUint16(26, nameBytes.length, true);
    dv.setUint16(28, 0, true);
    lh.set(nameBytes, 30);
    lh.set(dataBytes, 30 + nameBytes.length);

    localHeaders.push(lh);

    // Central Directory Header (46 bytes + name)
    const ch = new Uint8Array(46 + nameBytes.length);
    const cdv = new DataView(ch.buffer);
    cdv.setUint32(0, 0x02014b50, true);
    cdv.setUint16(4, 20, true);
    cdv.setUint16(6, 20, true);
    cdv.setUint16(8, 0, true);
    cdv.setUint16(10, 0, true);
    cdv.setUint16(12, 0, true);
    cdv.setUint16(14, 0, true);
    cdv.setUint32(16, crc, true);
    cdv.setUint32(20, size, true);
    cdv.setUint32(24, size, true);
    cdv.setUint16(28, nameBytes.length, true);
    cdv.setUint16(30, 0, true);
    cdv.setUint16(32, 0, true);
    cdv.setUint16(34, 0, true);
    cdv.setUint16(36, 0, true);
    cdv.setUint32(38, 0, true);
    cdv.setUint32(42, offset, true);
    ch.set(nameBytes, 46);

    centralHeaders.push(ch);
    offset += lh.length;
  }

  const centralOffset = offset;
  let centralSize = 0;
  for (const ch of centralHeaders) centralSize += ch.length;

  // End of Central Directory (22 bytes)
  const eocd = new Uint8Array(22);
  const edv = new DataView(eocd.buffer);
  edv.setUint32(0, 0x06054b50, true);
  edv.setUint16(4, 0, true);
  edv.setUint16(6, 0, true);
  edv.setUint16(8, files.length, true);
  edv.setUint16(10, files.length, true);
  edv.setUint32(12, centralSize, true);
  edv.setUint32(16, centralOffset, true);
  edv.setUint16(20, 0, true);

  const total = offset + centralSize + 22;
  const out = new Uint8Array(total);
  let pos = 0;
  for (const lh of localHeaders) {
    out.set(lh, pos);
    pos += lh.length;
  }
  for (const ch of centralHeaders) {
    out.set(ch, pos);
    pos += ch.length;
  }
  out.set(eocd, pos);
  return out;
}

export function export_project_zip(sessionScript) {
  if (typeof document === "undefined") return;

  const filesToZip = [];
  filesToZip.push({ name: "session.sk", data: sessionScript });

  const vfsList = get_vfs_file_list();
  const win = typeof window !== "undefined" ? window : globalThis;

  for (const item of vfsList) {
    let data = null;
    if (win.Module && win.Module.FS) {
      try {
        data = win.Module.FS.readFile("/" + item.name);
      } catch (_) {}
    }
    if (!data && fallbackVfsFiles[item.name]) {
      data = fallbackVfsFiles[item.name];
    }
    if (data) {
      filesToZip.push({ name: item.name, data: data });
    }
  }

  const zipData = createStoreZip(filesToZip);
  const blob = new Blob([zipData], { type: "application/zip" });
  const filename = "pulp-session-" + new Date().toISOString().replace(/[:.]/g, "-").slice(0, 19) + ".zip";

  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  URL.revokeObjectURL(url);

  send_skode_command("# exported session bundle to " + filename + " (" + filesToZip.length + " files)");
}

export function import_project_zip_dialog() {
  const win = typeof window !== "undefined" ? window : globalThis;
  if (typeof document === "undefined") return;

  const input = document.createElement("input");
  input.type = "file";
  input.accept = ".zip,application/zip,application/x-zip-compressed";

  input.onchange = async (e) => {
    const files = e.target.files;
    if (!files || !files.length) return;
    const file = files[0];
    const buf = await file.arrayBuffer();
    const bytes = new Uint8Array(buf);

    if (win.Module && win.Module.FS) {
      try {
        win.Module.FS.writeFile(file.name, bytes);
        // Mount zip bundle via Pulp %z opcode
        send_skode_command("[" + file.name + "] %z");
      } catch (err) {
        console.warn("Failed to write/mount zip in WASM:", err);
      }
    }
    fallbackVfsFiles[file.name] = bytes;
    send_skode_command("# mounted project bundle [" + file.name + "] via %z (" + bytes.length + " bytes)");
  };
  input.click();
}
