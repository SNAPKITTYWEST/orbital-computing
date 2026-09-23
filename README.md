# orbital-computing

[![License: AGPL-3.0-or-later OR Apache-2.0](https://img.shields.io/badge/license-AGPL--3.0--or--later%20OR%20Apache--2.0-blue.svg)](LICENSE-AGPL)
[![Rust](https://img.shields.io/badge/Rust-1.75%2B-orange.svg)](https://www.rust-lang.org/)
[![Free Pascal](https://img.shields.io/badge/Free_Pascal-3.2%2B-blue.svg)](https://www.freepascal.org/)
[![Open Dylan](https://img.shields.io/badge/Open_Dylan-2023.1%2B-purple.svg)](https://opendylan.org/)
[![Self](https://img.shields.io/badge/Self-4.5%2B-teal.svg)](https://selflanguage.org/)
[![CLONE_GATE](https://img.shields.io/badge/CLONE__GATE-AES256-black.svg)]()

**Orbital computing substrate** — 8-crate Rust workspace, Free Pascal simulation stack, Dylan Keplerian engine, Self/Morphic UI, and a live browser-based mission control frontend.

---

## Live Frontend

> **[→ Open Orbital View](https://snapkittywest.github.io/orbital-computing/frontend/visual-workplace.html)**

Animated 2D solar system: 19 bodies, perspective-tilted orbit rings, asteroid belt, Kuiper belt, cockpit frame, Earth telemetry panel, radar, layer toggles.

---

## Repository Layout

```
orbital-computing/
├── rust/                        # 8-crate Rust workspace (5,380 LOC)
│   ├── orbital-core/            # Core types, orbital mechanics primitives
│   ├── orbital-memory/          # Memory management, allocation
│   ├── orbital-runtime/         # Execution engine, task lifecycle
│   ├── orbital-scheduler/       # Task scheduling, priority queues
│   ├── orbital-ledger/          # Append-only ledger, audit trail
│   ├── orbital-telemetry/       # Metrics, tracing, observability
│   ├── orbital-verification/    # Invariant checks, formal contracts
│   └── orbital-communication/   # Inter-node messaging, protocols
├── pascal/                      # Free Pascal stack (3,494 LOC)
│   ├── src/orbital-hardware.pas # Hardware abstraction layer
│   ├── src/orbital-memory.pas   # Memory model, segment management
│   ├── src/orbital-runtime.pas  # Runtime environment
│   ├── src/orbital-simulator.pas# Full orbital mission simulator
│   ├── src/orbital-ffi.pas      # FFI bridge to Rust crates
│   └── src/orbital-main.pas     # Entry point
├── minikran/                    # MINIKRAN kernel (task lifecycle, WORM ledger)
├── frontend/
│   ├── visual-workplace.html    # Browser mission control UI (open standalone)
│   ├── orbital-view.self        # Self/Morphic solar system UI
│   ├── orbital-engine.dylan     # Dylan Keplerian math engine
│   └── ui.dylan                 # Dylan UI object model
├── simulator/RUST_FFI_GUIDE.md  # Pascal ↔ Rust FFI integration guide
└── ARCHITECTURE.md              # Full system architecture
```

---

## Rust Workspace

```bash
cd rust
cargo build --release
cargo test
```

Eight crates compose the orbital substrate:

| Crate | LOC | Purpose |
|-------|-----|---------|
| `orbital-core` | 819 | Core types, orbital mechanics |
| `orbital-memory` | 812 | Memory management, GC |
| `orbital-runtime` | 856 | Execution engine |
| `orbital-scheduler` | 623 | Task scheduling |
| `orbital-ledger` | 628 | Append-only audit ledger |
| `orbital-telemetry` | 495 | Metrics + tracing |
| `orbital-verification` | 533 | Invariant enforcement |
| `orbital-communication` | 614 | Inter-node protocols |

---

## Pascal Stack

```bash
cd pascal
bash build.sh          # Linux/macOS
build.bat              # Windows
# or: lazbuild orbital.lpi
```

---

## Self / Morphic UI

Load in a Self 4.5 world with `ui1` morphs:

```
_RunScript frontend/orbital-view.self
```

Renders a live animated solar system with 9 bodies, orbit rings, layer toggles, Earth info panel, and a 50ms animation loop.

---

## Dylan Engine

Keplerian orbit math with multiple dispatch:

```bash
dylan-compiler -build frontend/orbital-engine.lid
```

Exports `position-at-time`, `distance-au`, `orbital-period`, `earth-body` — feeds `positionAtTime:` in the Self UI via C FFI.
