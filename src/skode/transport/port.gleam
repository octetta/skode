//// Erlang Port transport for supervising and communicating with `mini-skred`
//// as an external OS process over stdin/stdout.
////
//// Spawns the native C engine under the BEAM's standard Port interface,
//// allowing OTP supervisors to monitor its lifecycle and automatically restart
//// it if the engine crashes.

import skode

pub type PortProcess

// -----------------------------------------------------------------------------
// Erlang / BEAM Target Implementation
// -----------------------------------------------------------------------------

@target(erlang)
/// Spawn mini-skred or an engine binary with custom arguments.
@external(erlang, "skode_transport_ffi", "port_spawn")
pub fn spawn(
  executable_path: String,
  args: List(String),
) -> Result(PortProcess, String)

@target(erlang)
/// Send a line of raw Skode text down stdin to the engine.
@external(erlang, "skode_transport_ffi", "port_send")
pub fn send_text(port: PortProcess, data: String) -> Result(Nil, String)

@target(erlang)
/// Terminate the supervised port process.
@external(erlang, "skode_transport_ffi", "port_close")
pub fn close(port: PortProcess) -> Nil

// -----------------------------------------------------------------------------
// JavaScript Target Fallback
// -----------------------------------------------------------------------------

@target(javascript)
pub fn spawn(
  _executable_path: String,
  _args: List(String),
) -> Result(PortProcess, String) {
  Error("Port transport is only supported on the Erlang/BEAM target")
}

@target(javascript)
pub fn send_text(_port: PortProcess, _data: String) -> Result(Nil, String) {
  Error("Port transport is only supported on the Erlang/BEAM target")
}

@target(javascript)
pub fn close(_port: PortProcess) -> Nil {
  Nil
}

// -----------------------------------------------------------------------------
// Shared High-Level Helpers
// -----------------------------------------------------------------------------

/// Spawn `mini-skred` found on PATH or current directory with default args.
pub fn spawn_default() -> Result(PortProcess, String) {
  spawn("mini-skred", [])
}

/// Send a list of AST `Op`s canonically formatted to the engine port.
pub fn send_ops(port: PortProcess, ops: List(skode.Op)) -> Result(Nil, String) {
  send_text(port, skode.ops_to_string(ops))
}

/// Send a single AST `Chunk` to the engine port.
pub fn send_chunk(
  port: PortProcess,
  chunk: skode.Chunk,
) -> Result(Nil, String) {
  send_text(port, skode.chunk_to_string(chunk))
}

/// Send an entire AST program (`List(Chunk)`) to the engine port.
pub fn send_program(
  port: PortProcess,
  program: List(skode.Chunk),
) -> Result(Nil, String) {
  send_text(port, skode.program_to_string(program))
}
