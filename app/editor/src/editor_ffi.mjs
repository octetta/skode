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
  cutoff: 5000,
  q: 0.707,
  attack: 0.01,
  decay: 0.1,
  sustain: 0.8,
  release: 0.2,
  level: 1.0,
};

function ensureAudioContext() {
  if (!audioCtx) {
    const AudioContextClass = window.AudioContext || window.webkitAudioContext;
    if (AudioContextClass) {
      audioCtx = new AudioContextClass();
    }
  }
  if (audioCtx && audioCtx.state === "suspended") {
    audioCtx.resume();
  }
  return audioCtx;
}

function midiToFreq(note) {
  return 440 * Math.pow(2, (note - 69) / 12);
}

function parseAndUpdateParams(cmd) {
  // Tokenize by spaces and update cached voice parameters
  const tokens = cmd.trim().split(/\s+/);
  for (const tok of tokens) {
    // Strip leading voice prefix if present (e.g. 0k1500 -> k1500)
    const m = tok.match(/^(?:\d+)?([a-zA-Z_]+)([-+]?[0-9]*\.?[0-9]+)?$/);
    if (!m) continue;
    const op = m[1];
    const val = m[2] !== undefined ? parseFloat(m[2]) : NaN;

    switch (op) {
      case "w":
        if (!isNaN(val)) voiceParams.wave = Math.round(val);
        break;
      case "k":
        if (!isNaN(val)) voiceParams.cutoff = val;
        break;
      case "q":
        if (!isNaN(val)) voiceParams.q = val;
        break;
      case "a":
        if (!isNaN(val)) voiceParams.attack = Math.max(0.001, val);
        break;
      case "d":
        if (!isNaN(val)) voiceParams.decay = Math.max(0.001, val);
        break;
      case "s":
        if (!isNaN(val)) voiceParams.sustain = Math.max(0.0, Math.min(1.0, val));
        break;
      case "r":
        if (!isNaN(val)) voiceParams.release = Math.max(0.001, val);
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

  // Master voice gain node
  const gainNode = ctx.createGain();
  gainNode.gain.setValueAtTime(0.0001, now);
  gainNode.gain.exponentialRampToValueAtTime(Math.max(0.0001, voiceParams.level * 0.4), now + attack);
  gainNode.gain.exponentialRampToValueAtTime(
    Math.max(0.0001, voiceParams.level * 0.4 * sustain),
    now + attack + decay
  );
  gainNode.gain.setValueAtTime(
    Math.max(0.0001, voiceParams.level * 0.4 * sustain),
    now + holdTime
  );
  gainNode.gain.exponentialRampToValueAtTime(0.0001, now + holdTime + release);

  // Filter node
  const filterNode = ctx.createBiquadFilter();
  filterNode.type = "lowpass";
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
// Command Dispatch Bridge
// -----------------------------------------------------------------------------

export function send_skode_command(cmd) {
  const win = typeof window !== "undefined" ? window : globalThis;

  parseAndUpdateParams(cmd);

  const isTrigger = /(?:^|\s)(?:T|l1|trigger)(?:\s|$)/i.test(cmd);

  // 1. Native WASM / Global bridge if present
  if (typeof win.skred_command === "function") {
    win.skred_command(cmd);
    if (isTrigger && typeof win.skred_trigger_voice === "function") {
      win.skred_trigger_voice(0, 1.0);
    }
    return 0;
  }
  if (win.Module && typeof win.Module.ccall === "function") {
    try {
      win.Module.ccall("skred_command", "number", ["string"], [cmd]);
      if (isTrigger && typeof win.Module._skred_trigger_voice === "function") {
        win.Module._skred_trigger_voice(0, 1.0);
      }
      return 0;
    } catch (e) {
      console.warn("Error calling WASM skred_command:", e);
    }
  }

  // 2. Standalone Web Audio Synth fallback for immediate playback
  if (isTrigger) {
    playWebAudioNote();
  }

  console.log("[skode dispatch]:", cmd);
  return 0;
}
