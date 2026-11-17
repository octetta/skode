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

export function wasm_send(cmd) {
  const g = getGlobal();
  if (!g || !g.Module || typeof g.Module.ccall !== "function") {
    return new Error("Pulp WebAssembly Module not available");
  }
  try {
    if (!engineStarted && typeof g.Module._skred_start === "function") {
      g.Module._skred_start(128, 16, 0);
      engineStarted = true;
    }
    g.Module.ccall("skred_command", "number", ["string"], [cmd]);
    return new Ok(undefined);
  } catch (err) {
    return new Error(String(err));
  }
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
