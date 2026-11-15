# skode

[![Package Version](https://img.shields.io/badge/version-v0.1.0-blue.svg)](gleam.toml)
[![Aligned with Skred](https://img.shields.io/badge/skred-v0.84.0-ff69b4.svg)](https://github.com/octetta/pulp)
[![Gleam](https://img.shields.io/badge/language-Gleam-ffaff3.svg)](https://gleam.run/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Typed AST, parser, and canonical printer for **Skode**—the music sequencing and live-coding command language for the [Skred audio engine](https://github.com/octetta/pulp).

---

## Features

- **Strict Type-Safety**: Rich algebraic types for Skode commands (`Voice`, `Note`, `Freq`, `Amp`, `Level`, `Pan`, `Wave`, `Mode`, `Loop`, `Glide`, `Slew`, `Step`, `Defer`, `MacroDef`, and extensible `Generic(Command)`).
- **Exact C-Lexer State Machine Alignment**: Follows `parts/ands.c` in `octetta/pulp`, respecting delimiter rules, blank tolerances on defers (`+-n`, `~n`), sentinel floats (`.`, `-`), and string brackets (`[...]`).
- **Canonical Serialization**: Prints idiomatic, compact Skode code without float notation bugs (suppresses scientific notation and strips redundant decimal tails).
- **Round-Trip Guaranteed**: Verified round-trip parsing and printing across complex tracker conversions, pattern lines, macros, and link arrays.
- **Version Tracking**: Exports package version (`skode.version`) and aligned engine version (`skode.pulp_version`).

---

## Installation

Add `skode` to your `gleam.toml`:

```toml
[dependencies]
skode = { git = "https://github.com/octetta/skode.git", branch = "main" }
```

---

## Quick Tour

### 1. Parsing Skode Code to AST
```gleam
import skode

let program = skode.parse_program("v0 w15 f440 a-6 l1; [lead] puts")
// => [
//      Chunk([Voice(0), Wave(15), Freq(440.0), Amp(-6.0), Level(1.0)], None),
//      Chunk([Puts("lead")], None),
//    ]
```

### 2. Constructing Skode AST & Serializing
```gleam
import skode

let step =
  skode.Step(
    ops: [
      skode.Voice(0),
      skode.Wave(301),
      skode.Note(midi: 60, cents: None),
      skode.Amp(-8.0),
      skode.Level(1.0),
    ],
    at: 12,
  )

skode.op_to_string(step)
// => "[v0 w301 n60 a-8 l1] x12"
```

### 3. Checking Versions
```gleam
import skode

skode.version       // "0.1.0"
skode.pulp_version  // "0.84.0"
```

---

## License

MIT License · Copyright (c) 2026 Joseph Ellis Stewart / Octetta
