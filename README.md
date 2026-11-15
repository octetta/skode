# skode

[![Hex Package](https://img.shields.io/hexpm/v/skode.svg)](https://hex.pm/packages/skode)
[![HexDocs](https://img.shields.io/badge/hex-docs-purple.svg)](https://hexdocs.pm/skode/)
[![Engine Alignment](https://img.shields.io/badge/skred-v0.84.0-ff69b4.svg)](https://github.com/octetta/pulp)
[![BEAM](https://img.shields.io/badge/BEAM-Erlang%20%7C%20Elixir%20%7C%20Gleam%20%7C%20LFE%20%7C%20erlua-a30535.svg)](https://erlang.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Type-safe AST, parser, and canonical serializer for **Skode**—the live-coding and musical command language of the [Skred audio engine](https://github.com/octetta/pulp).

Written in pure Gleam with zero C/NIF dependencies. Runs natively on both the **Erlang BEAM VM** and **JavaScript** runtimes.

---

## Installation

### Gleam
```bash
gleam add skode
```
Or in `gleam.toml`:
```toml
[dependencies]
skode = ">= 0.1.0 and < 1.0.0"
```

### Elixir (`mix.exs`)
```elixir
def deps do
  [
    {:skode, "~> 0.1.0"}
  ]
end
```

### Erlang (`rebar.config`)
```erlang
{deps, [
    {skode, "0.1.0"}
]}.
```

### LFE (Lisp Flavoured Erlang)
Add to your project's `rebar.config`:
```erlang
{deps, [
    {skode, "0.1.0"}
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
"0.1.0"  = :skode.version()
"0.84.0" = :skode.pulp_version()
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
