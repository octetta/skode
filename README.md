# skode

[![Hex Package](https://img.shields.io/hexpm/v/skode.svg)](https://hex.pm/packages/skode)
[![HexDocs](https://img.shields.io/badge/hex-docs-purple.svg)](https://hexdocs.pm/skode/)
[![Engine Alignment](https://img.shields.io/badge/skred-v0.85.0-ff69b4.svg)](https://github.com/octetta/pulp)
[![BEAM](https://img.shields.io/badge/BEAM-Erlang%20%7C%20Elixir%20%7C%20Gleam%20%7C%20LFE%20%7C%20erlua-a30535.svg)](https://erlang.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Type-safe AST, parser, and canonical serializer for **Skode**—the live-coding and musical command language of the [Skred audio engine](https://github.com/octetta/pulp).

Written in pure Gleam with zero C/NIF dependencies. Runs natively on both the **Erlang BEAM VM** and **JavaScript** runtimes.

---

## Production Applications & Dogfooding

`skode` is battle-tested in production across three flagship open-source audio applications:

* **[Skode Voice Editor](https://octetta.github.io/skode/)**: An interactive browser-based synthesizer voice designer built with Lustre 5. It dogfoods `skode/voice`, `skode/diff`, and `skode/transport/wasm` for reactive parameter diffing and zero-latency Web Audio preview.
* **[Mod-to-Skode Tracker Studio](https://octetta.github.io/mod-to-skode/)** ([GitHub: octetta/mod-to-skode](https://github.com/octetta/mod-to-skode)): A heavy-duty Amiga / ProTracker MOD file converter and player. It tests `skode` under heavy load with dense multi-thousand-row song arrangements, relying on the AST, canonical printer, and `skode/transport/wasm` across both browser environments and standalone native CLI binaries (compiled via QuickJS).
* **[Sid-to-Skode Studio](https://octetta.github.io/sid-to-skode/)** ([GitHub: octetta/sid-to-skode](https://github.com/octetta/sid-to-skode)): An authentic Commodore 64 MOS 6581/8580 SID converter and chiptune player. It converts rapid 50 Hz register write streams into delta-compressed Skode sequences, dogfooding `skode`'s AST and `skode/transport/wasm` dispatch.

---

## Installation

### Gleam
```bash
gleam add skode
```
Or in `gleam.toml`:
```toml
[dependencies]
skode = ">= 0.3.0 and < 1.0.0"
```

### Elixir (`mix.exs`)
```elixir
def deps do
  [
    {:skode, "~> 0.3.0"}
  ]
end
```

### Erlang (`rebar.config`)
```erlang
{deps, [
    {skode, "0.3.0"}
]}.
```

### LFE (Lisp Flavoured Erlang)
Add to your project's `rebar.config`:
```erlang
{deps, [
    {skode, "0.3.0"}
]}.
```

---

## Polyglot BEAM Quick Start

Because `skode` compiles directly to standard BEAM bytecode (`.beam`), all functions and tagged tuples are first-class citizens across all BEAM languages.

### 1. Gleam
```gleam
import skode

pub fn main() {
  // Parse Skode string into a list of Chunk records
  let program = skode.parse_program("v0 w15 f440 a-6 l1; [lead] puts")

  // Construct AST programmatically
  let step = skode.Step(
    ops: [skode.Voice(0), skode.Freq(440.0), skode.Amp(-6.0), skode.Level(1.0)],
    at: 12,
  )

  // Serialize back to canonical Skode string
  let script = skode.op_to_string(step)
  // => "[v0 f440 a-6 l1] x12"
}
```

### 2. Elixir
```elixir
# Parse Skode code into tagged tuples
chunks = :skode.parse_program("v0 w301 n60 l1; [bass] wt 100")

# Inspect structured chunks: [{:chunk, ops, remark}]
# Ops are tagged tuples: {:voice, 0}, {:note, 60, :none}, {:amp, -6.0}, etc.
[first_chunk | _] = chunks

# Serialize AST back to canonical Skode text
iodata = :skode.program_to_string(chunks)
# => "v0 w301 n60 l1\n[bass] wt 100"

# Check versions
"0.3.0"  = :skode.version()
"0.85.0" = :skode.pulp_version()
```

### 3. Erlang
```erlang
%% Parse a Skode script binary
Chunks = skode:parse_program(<<"v0 f440 l1; [lead] puts">>),

%% Transform or inspect tagged tuples
%% Chunks = [{chunk, [{voice, 0}, {freq, 440.0}, {level, 1.0}], none}, ...]

%% Format canonically and stream over UDP to a local Skred synthesizer
SkodeBin = skode:program_to_string(Chunks),
gen_udp:send(Socket, "127.0.0.1", 7000, SkodeBin).
```

### 4. LFE (Lisp Flavoured Erlang)
```lfe
;; Parse Skode binary into AST chunks
(set chunks (: skode parse_program #"v0 n60 l1"))

;; Serialize AST chunks back to Skode string
(set code (: skode program_to_string chunks))

;; Access engine alignment version
(set pulp-ver (: skode pulp_version))
```

### 5. erlua (Lua on the BEAM)
If you run Lua scripts inside the Erlang VM via `erlua`:
```lua
-- Access the compiled Erlang module
local skode = erlang.skode

-- Parse Skode script
local chunks = skode.parse_program("v0 w301 n60 l1")

-- Re-serialize canonical Skode
local text = skode.program_to_string(chunks)
print("Generated Skode: " .. text)
```

---

## BEAM Data Mapping Reference

Gleam's algebraic data types map to straightforward Erlang tagged tuples:

| Gleam AST Type | Erlang / Elixir Tuple Representation |
| :--- | :--- |
| `Chunk(ops, remark)` | `{chunk, OpsList, None \| {some, <<"comment">>}}` |
| `Voice(0)` | `{voice, 0}` |
| `Note(60, None)` | `{note, 60, none}` |
| `Note(60, Some(12.5))` | `{note, 60, {some, 12.5}}` |
| `Freq(440.0)` | `{freq, 440.0}` |
| `Amp(-6.0)` | `{amp, -6.0}` |
| `Level(1.0)` | `{level, 1.0}` |
| `Glide(0.02, None)` | `{glide, 0.02, none}` |
| `Glide(0.0, None)` (bare `g`) | `{glide, 0.0, none}` |
| `Step(ops, 12)` | `{step, OpsList, 12}` |
| `Generic(Command(atom, ...))` | `{generic, {command, <<"atom">>, Args, Array, String}}` |

---

## Engine State Domain Models

In addition to the raw wire-protocol parser and AST, `skode` provides structured, typed domain models for managing synthesizer state in UI editors (like [Lustre](https://github.com/hayleigh-dot-dev/lustre)) and distributed BEAM processes:

* **`skode/voice`**: Normalized `Voice` document model (Oscillator, Envelope, Filter, Mix, Modulation, Links), default patches (`voice.default(0)`), full serialization (`to_skode`), and reactive delta diffing (`diff_skode`) for real-time slider updates.
* **`skode/global`**: Global engine settings including **Master Volume (`V`)** in dB with linear conversion, master tempo and clock (`M`), downbeat reference pattern (`yp`), and the 4 delay lines.
* **`skode/delay`**: Pulp's 4 stereo delay lines (`DL`, `DD`, `DF`, `DP`, `DG`, `DS`), millisecond timing calculations, and feedback gain curves.
* **`skode/pattern`**: Sequencer patterns (`y`), clock divider modulo (`%`), step programming (`[code] x<step>`), and playback states (`z`).
* **`skode/param`**: Physical unit bounds checking, clamping, frequency/note math (`midi_to_hz`), and decibel conversions (`db_to_linear`).

### Example: Reactive Voice & Master Volume Diffs (for Lustre / LiveView)

```gleam
import skode/global
import skode/voice

pub fn demo() {
  // 1. Create default voice 0
  let v0 = voice.default(0)

  // 2. Tweak cutoff in UI (e.g. slider moves to 1250 Hz)
  let v1 = voice.Voice(..v0, filter: voice.Filter(..v0.filter, cutoff_hz: 1250.0))

  // 3. Compute surgical delta command to stream to engine
  voice.diff_skode(v0, v1)
  // => ["v0 k1250"]

  // 4. Adjust Master Volume (V)
  let g0 = global.default()
  let g1 = global.set_master_volume_db(g0, -3.5)
  global.diff_skode(g0, g1)
  // => ["V -3.5"]
}
```

---

## Web Voice Editor & Live Synthesis

`skode` includes an interactive browser-based sound design editor built with [Lustre](https://github.com/hayleigh-dot-dev/lustre) and powered directly by an embedded WebAssembly build of the Skred audio engine.

- **[Live Web Editor Demo](https://octetta.github.io/skode/)**

### Running the Editor Locally

```bash
make serve
```

This compiles the Lustre JavaScript application, bundles the WASM synthesis engine, and starts a local web server at `http://localhost:8000`.

---

## Engine Transports

`skode` provides zero-friction transports for interacting directly with Pulp's `mini-skred` engine across different runtime environments:

### 1. UDP Transport (BEAM: Gleam / Elixir / Erlang)
Streams commands to `mini-skred` over UDP (port `7000` by default, enabled via `SKRED_UDP=ON` in Pulp). Zero native dependencies, complete crash isolation, and distributed across local or network machines.

```gleam
import skode
import skode/transport/udp

pub fn main() {
  // Open ephemeral client socket
  let assert Ok(sock) = udp.open()

  // Stream raw commands
  let assert Ok(Nil) = udp.send(sock, "v0 w1 f440 a-6 T")

  // Or send structured AST programs
  let program = skode.parse_program("v0 f880 T; [lead] puts")
  let assert Ok(Nil) = udp.send_program_default(sock, program)

  udp.close(sock)
}
```

In Elixir:
```elixir
{:ok, sock} = :skode@transport@udp.open()
:ok = :skode@transport@udp.send(sock, "v0 f440 a-6 T")
:skode@transport@udp.close(sock)
```

### 2. Erlang Port Subprocess Transport (BEAM)
Launches and supervises `mini-skred` directly as an external OS process over stdin/stdout lines, allowing standard OTP supervisors to monitor its lifecycle and restart on failure:

```gleam
import skode/transport/port

pub fn main() {
  let assert Ok(p) = port.spawn_default()
  let assert Ok(Nil) = port.send_text(p, "v0 n60 l1")
  port.close(p)
}
```

### 3. WebAssembly Transport (JavaScript / Browser / Lustre)
Directly calls the native C DSP engine compiled to WebAssembly (`skred_api.js` + `skred_api.wasm`) in browser and Web Audio environments:

```gleam
import skode/transport/wasm

pub fn play() {
  case wasm.is_available() {
    True -> {
      let assert Ok(Nil) = wasm.start_default()
      let assert Ok(Nil) = wasm.send_text("v0 n60 T")
    }
    False -> Nil
  }
}
```

---

## Publishing to Hex.pm

To publish a release to Hex.pm:

```bash
# 1. Verify tests pass on both Erlang and JavaScript targets
gleam test --target erlang
gleam test --target javascript

# 2. Build and preview HexDocs
gleam docs build

# 3. Publish to Hex.pm
gleam publish
```

---

## License

MIT License · Copyright (c) 2026 Joseph Ellis Stewart / Octetta ([LICENSE](LICENSE))
