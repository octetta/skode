// JavaScript FFI Bridge for skode_editor
// Handles clipboard copying and optional Skred WASM / WebSocket command execution.

export function copy_to_clipboard(text) {
  if (navigator && navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(text).catch(err => {
      console.warn("Failed to copy clipboard:", err);
    });
  } else {
    console.log("[skode-editor] Copy to clipboard:", text);
  }
}

export function send_skode_command(cmd) {
  const win = typeof window !== "undefined" ? window : globalThis;
  if (typeof win.skred_command === "function") {
    return win.skred_command(cmd);
  }
  if (win.Module && typeof win.Module.ccall === "function") {
    try {
      return win.Module.ccall("skred_command", "number", ["string"], [cmd]);
    } catch (e) {
      console.warn("Error calling WASM skred_command:", e);
    }
  }
  console.log("[skode dispatch]:", cmd);
  return 0;
}
