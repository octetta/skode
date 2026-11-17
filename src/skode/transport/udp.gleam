//// UDP transport for communicating with the Skred / Pulp audio engine on the BEAM.
////
//// Pulp's `mini-skred` engine listens on UDP port 7000 by default (when built
//// with `SKRED_UDP=ON`). This transport allows any Gleam, Elixir, Erlang, or LFE
//// process on the BEAM to stream commands with zero C/NIF dependencies.

import skode

pub type UdpSocket

pub const default_host = "127.0.0.1"

pub const default_port = 7000

// -----------------------------------------------------------------------------
// Erlang / BEAM Target Implementation
// -----------------------------------------------------------------------------

@target(erlang)
/// Open an ephemeral client UDP socket.
@external(erlang, "skode_transport_ffi", "udp_open")
pub fn open() -> Result(UdpSocket, String)

@target(erlang)
/// Open a UDP socket bound to a specific local port.
@external(erlang, "skode_transport_ffi", "udp_open_port")
pub fn open_port(port: Int) -> Result(UdpSocket, String)

@target(erlang)
/// Close an open UDP socket.
@external(erlang, "skode_transport_ffi", "udp_close")
pub fn close(socket: UdpSocket) -> Nil

@target(erlang)
/// Low-level send of raw string payload to host:port.
@external(erlang, "skode_transport_ffi", "udp_send")
pub fn send_text(
  socket: UdpSocket,
  host: String,
  port: Int,
  data: String,
) -> Result(Nil, String)

// -----------------------------------------------------------------------------
// JavaScript Target Fallback
// -----------------------------------------------------------------------------

@target(javascript)
pub fn open() -> Result(UdpSocket, String) {
  Error("UDP transport is only supported on the Erlang/BEAM target")
}

@target(javascript)
pub fn open_port(_port: Int) -> Result(UdpSocket, String) {
  Error("UDP transport is only supported on the Erlang/BEAM target")
}

@target(javascript)
pub fn close(_socket: UdpSocket) -> Nil {
  Nil
}

@target(javascript)
pub fn send_text(
  _socket: UdpSocket,
  _host: String,
  _port: Int,
  _data: String,
) -> Result(Nil, String) {
  Error("UDP transport is only supported on the Erlang/BEAM target")
}

// -----------------------------------------------------------------------------
// Shared High-Level Helpers
// -----------------------------------------------------------------------------

/// Send raw string to the default Pulp host and port (127.0.0.1:7000).
pub fn send(socket: UdpSocket, data: String) -> Result(Nil, String) {
  send_text(socket, default_host, default_port, data)
}

/// Send a list of AST `Op`s canonically formatted to host:port.
pub fn send_ops(
  socket: UdpSocket,
  host: String,
  port: Int,
  ops: List(skode.Op),
) -> Result(Nil, String) {
  send_text(socket, host, port, skode.ops_to_string(ops))
}

/// Send a list of AST `Op`s to the default Pulp host and port (127.0.0.1:7000).
pub fn send_ops_default(
  socket: UdpSocket,
  ops: List(skode.Op),
) -> Result(Nil, String) {
  send(socket, skode.ops_to_string(ops))
}

/// Send a single AST `Chunk` to host:port.
pub fn send_chunk(
  socket: UdpSocket,
  host: String,
  port: Int,
  chunk: skode.Chunk,
) -> Result(Nil, String) {
  send_text(socket, host, port, skode.chunk_to_string(chunk))
}

/// Send a single AST `Chunk` to the default Pulp host and port (127.0.0.1:7000).
pub fn send_chunk_default(
  socket: UdpSocket,
  chunk: skode.Chunk,
) -> Result(Nil, String) {
  send(socket, skode.chunk_to_string(chunk))
}

/// Send an entire AST program (`List(Chunk)`) to host:port.
pub fn send_program(
  socket: UdpSocket,
  host: String,
  port: Int,
  program: List(skode.Chunk),
) -> Result(Nil, String) {
  send_text(socket, host, port, skode.program_to_string(program))
}

/// Send an entire AST program (`List(Chunk)`) to the default Pulp host and port.
pub fn send_program_default(
  socket: UdpSocket,
  program: List(skode.Chunk),
) -> Result(Nil, String) {
  send(socket, skode.program_to_string(program))
}
