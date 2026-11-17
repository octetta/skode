//// WebAssembly transport for communicating with the embedded Skred / Pulp audio engine in JavaScript.
////
//// Interacts directly with the WebAssembly C-API (`_skred_start`, `skred_command`, `skred_log`, `_skred_stop`)
//// exposed by `skred_api.js` and `skred_api.wasm`.

import skode

// -----------------------------------------------------------------------------
// JavaScript Target Implementation
// -----------------------------------------------------------------------------

@target(javascript)
/// Check if the Pulp WebAssembly Module is currently loaded and available.
@external(javascript, "../../skode_wasm_ffi.mjs", "wasm_is_available")
pub fn is_available() -> Bool

@target(javascript)
/// Boot the WebAudio synthesis loop and start the native C DSP engine.
@external(javascript, "../../skode_wasm_ffi.mjs", "wasm_start")
pub fn start(frames: Int, voices: Int) -> Result(Nil, String)

@target(javascript)
/// Start the engine with standard interactive defaults (128 frames, 16 voices).
pub fn start_default() -> Result(Nil, String) {
  start(128, 16)
}

@target(javascript)
/// Execute a Skode command string on the WASM engine, returning the engine's log/output buffer.
@external(javascript, "../../skode_wasm_ffi.mjs", "wasm_exec")
pub fn exec(command: String) -> Result(String, String)

@target(javascript)
/// Send a raw line of Skode text directly to the native engine without capturing output.
@external(javascript, "../../skode_wasm_ffi.mjs", "wasm_send")
pub fn send_text(command: String) -> Result(Nil, String)

@target(javascript)
/// Stop the audio engine and pause WebAudio rendering.
@external(javascript, "../../skode_wasm_ffi.mjs", "wasm_stop")
pub fn stop() -> Nil

// -----------------------------------------------------------------------------
// Erlang / BEAM Target Fallback
// -----------------------------------------------------------------------------

@target(erlang)
pub fn is_available() -> Bool {
  False
}

@target(erlang)
pub fn start(_frames: Int, _voices: Int) -> Result(Nil, String) {
  Error("WASM transport is only supported on JavaScript/Web runtimes")
}

@target(erlang)
pub fn start_default() -> Result(Nil, String) {
  Error("WASM transport is only supported on JavaScript/Web runtimes")
}

@target(erlang)
pub fn exec(_command: String) -> Result(String, String) {
  Error("WASM transport is only supported on JavaScript/Web runtimes")
}

@target(erlang)
pub fn send_text(_command: String) -> Result(Nil, String) {
  Error("WASM transport is only supported on JavaScript/Web runtimes")
}

@target(erlang)
pub fn stop() -> Nil {
  Nil
}

// -----------------------------------------------------------------------------
// Shared High-Level Helpers
// -----------------------------------------------------------------------------

/// Execute a list of AST `Op`s canonically formatted, returning engine output.
pub fn exec_ops(ops: List(skode.Op)) -> Result(String, String) {
  exec(skode.ops_to_string(ops))
}

/// Execute a single AST `Chunk`, returning engine output.
pub fn exec_chunk(chunk: skode.Chunk) -> Result(String, String) {
  exec(skode.chunk_to_string(chunk))
}

/// Execute an entire AST program (`List(Chunk)`), returning engine output.
pub fn exec_program(program: List(skode.Chunk)) -> Result(String, String) {
  exec(skode.program_to_string(program))
}

/// Send a list of AST `Op`s canonically formatted to the WASM engine.
pub fn send_ops(ops: List(skode.Op)) -> Result(Nil, String) {
  send_text(skode.ops_to_string(ops))
}

/// Send a single AST `Chunk` to the WASM engine.
pub fn send_chunk(chunk: skode.Chunk) -> Result(Nil, String) {
  send_text(skode.chunk_to_string(chunk))
}

/// Send an entire AST program (`List(Chunk)`) to the WASM engine.
pub fn send_program(program: List(skode.Chunk)) -> Result(Nil, String) {
  send_text(skode.program_to_string(program))
}
