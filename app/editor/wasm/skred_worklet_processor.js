// Standalone Single-Threaded Skred AudioWorkletProcessor
// Runs the pure DSP engine on the browser's real-time audio thread
// Completely isolated from UI rendering, GC pauses, and main-thread load
// Zero SharedArrayBuffer requirement — 100% compatible with itch.io iframes

import createModule from "./skred_worklet_engine.js";

class SkredWorkletProcessor extends AudioWorkletProcessor {
  constructor(options) {
    super(options);
    this.module = null;
    this.leftPtr = 0;
    this.rightPtr = 0;
    this.ready = false;
    this.commandQueue = [];
    this.sampleRate = (options && options.processorOptions && options.processorOptions.sampleRate) || 48000;
    this.cmdBufferPtr = 0;
    this.cmdBufferSize = 4096;

    this.port.onmessage = (event) => {
      this.handleMessage(event.data);
    };

    const initialBinary = options && options.processorOptions && options.processorOptions.wasmBinary;
    this.init(initialBinary);
  }

  async init(wasmBinary) {
    try {
      const moduleConfig = {};
      if (wasmBinary) {
        moduleConfig.wasmBinary = wasmBinary;
      } else {
        moduleConfig.locateFile = (path) => {
          return new URL(path, import.meta.url).href;
        };
      }
      this.module = await createModule(moduleConfig);
      const startRes = this.module._skred_start_headless(128, Math.floor(this.sampleRate));
      this.leftPtr = this.module._malloc(128 * 4);
      this.rightPtr = this.module._malloc(128 * 4);
      this.cmdBufferPtr = this.module._malloc(this.cmdBufferSize);
      this.ready = (startRes === 0);

      this.port.postMessage({
        type: "ready",
        version: this.getVersion(),
        sampleRate: this.sampleRate,
      });

      // Drain any commands queued before initialization completed
      while (this.commandQueue.length > 0) {
        const cmd = this.commandQueue.shift();
        this.executeCommand(cmd);
      }
    } catch (err) {
      console.error("[SkredWorklet] Initialization error:", err);
      this.port.postMessage({ type: "error", error: String(err) });
    }
  }

  getVersion() {
    if (!this.module || typeof this.module._skred_version !== "function") return "1.3.7";
    try {
      const ptr = this.module._skred_version();
      return ptr ? this.module.UTF8ToString(ptr) : "1.3.7";
    } catch (e) {
      return "1.3.7";
    }
  }

  handleMessage(data) {
    if (!data) return;
    if (data.type === "cmd") {
      if (this.ready) {
        this.executeCommand(data.text);
      } else {
        this.commandQueue.push(data.text);
      }
    } else if (data.type === "init" && !this.ready) {
      this.init(data.wasmBinary);
    }
  }

  executeCommand(cmd) {
    if (!this.module || !cmd) return;
    try {
      this.module.stringToUTF8(cmd, this.cmdBufferPtr, this.cmdBufferSize);
      this.module._skred_command(this.cmdBufferPtr);
    } catch (err) {
      console.error("[SkredWorklet] Command error:", err);
    }
  }

  process(inputs, outputs, parameters) {
    if (!this.ready || !this.module) {
      return true;
    }

    // Drain queued commands
    while (this.commandQueue.length > 0) {
      const cmd = this.commandQueue.shift();
      this.executeCommand(cmd);
    }

    const output = outputs[0];
    if (!output || output.length === 0) return true;

    const outLeft = output[0];
    const outRight = output[1] || output[0];
    const frameCount = outLeft.length;

    if (frameCount === 128) {
      this.module._skred_process_stereo(this.leftPtr, this.rightPtr, 128);
      const heap = this.module.HEAPF32;
      const leftIdx = this.leftPtr >> 2;
      const rightIdx = this.rightPtr >> 2;
      for (let i = 0; i < 128; i++) {
        outLeft[i] = heap[leftIdx + i];
        outRight[i] = heap[rightIdx + i];
      }
    } else {
      let offset = 0;
      while (offset < frameCount) {
        const chunk = Math.min(128, frameCount - offset);
        this.module._skred_process_stereo(this.leftPtr, this.rightPtr, chunk);
        const heap = this.module.HEAPF32;
        const leftIdx = this.leftPtr >> 2;
        const rightIdx = this.rightPtr >> 2;
        for (let i = 0; i < chunk; i++) {
          outLeft[offset + i] = heap[leftIdx + i];
          outRight[offset + i] = heap[rightIdx + i];
        }
        offset += chunk;
      }
    }

    return true;
  }
}

registerProcessor("skred-worklet-processor", SkredWorkletProcessor);
