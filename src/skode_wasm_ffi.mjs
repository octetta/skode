// JavaScript FFI Bridge for Pulp WebAssembly Engine
import { Ok, Error } from "../prelude.mjs";

let engineStarted = false;

function getGlobal() {
  return typeof window !== "undefined"
    ? window
    : typeof globalThis !== "undefined"
    ? globalThis
    : null;
}

export function wasm_is_available() {
  const g = getGlobal();
  return Boolean(
    g &&
      g.Module &&
      (typeof g.Module._skred_start === "function" ||
        typeof g.Module.ccall === "function")
  );
}

export function wasm_start(frames, voices) {
  const g = getGlobal();
  if (!g || !g.Module) {
    return new Error("Pulp WebAssembly Module not found on global scope");
  }
  try {
    if (typeof g.Module._skred_start === "function" && !engineStarted) {
      g.Module._skred_start(frames, voices, 0);
      engineStarted = true;
    }
    if (typeof g.Module._skred_logger === "function") {
      g.Module._skred_logger(1);
    }
    return new Ok(undefined);
  } catch (err) {
    return new Error(String(err));
  }
}

export function wasm_exec(cmd) {
  const g = getGlobal();
  if (!g || !g.Module || typeof g.Module.ccall !== "function") {
    return new Error("Pulp WebAssembly Module not available");
  }
  try {
    if (!engineStarted && typeof g.Module._skred_start === "function") {
      g.Module._skred_start(128, 16, 0);
      engineStarted = true;
    }
    if (typeof g.Module._skred_logger === "function") {
      g.Module._skred_logger(1);
    }
    if (typeof cmd === "string" && cmd.includes("\n")) {
      const lines = cmd.split("\n");
      const outputs = [];
      for (const line of lines) {
        const trimmed = line.trim();
        if (trimmed) {
          g.Module.ccall("skred_command", "number", ["string"], [trimmed]);
          try {
            const out = g.Module.ccall("skred_log", "string", [], []);
            if (out && out.trim()) outputs.push(out.trim());
          } catch (_) {}
        }
      }
      return new Ok(outputs.join("\n"));
    } else {
      g.Module.ccall("skred_command", "number", ["string"], [cmd]);
      let output = "";
      try {
        output = g.Module.ccall("skred_log", "string", [], []) || "";
      } catch (_) {}
      return new Ok(output.trim());
    }
  } catch (err) {
    return new Error(String(err));
  }
}

export function wasm_send(cmd) {
  const res = wasm_exec(cmd);
  if (res.isOk && res.isOk()) {
    return new Ok(undefined);
  } else if (res instanceof Error) {
    return res;
  }
  return new Ok(undefined);
}

export function wasm_stop() {
  const g = getGlobal();
  if (g && g.Module && typeof g.Module._skred_stop === "function") {
    try {
      g.Module._skred_stop();
      engineStarted = false;
    } catch (_) {}
  }
  return undefined;
}
