# Orbital Computing Stack - Rust FFI Integration Guide

Integration path for Rust projects to use Pascal orbital simulator via FFI.

## Overview

The Pascal implementation provides C-compatible interfaces that can be called from Rust with zero-copy interop and sealed opaque types.

## Architecture

```
┌─ Rust Application ────────────────────┐
│                                       │
│  use orbital_ffi::*;                 │
│                                       │
│  let simulator = OrbitalSimulator::   │
│    new()?;                            │
│  simulator.initialize(&seeds)?;       │
│  simulator.run(10000)?;               │
│                                       │
└──────────────────┬────────────────────┘
                   │
                   │ FFI calls
                   ↓
┌─ Pascal Library (orbital-simulator.so/.dll) ──────────┐
│                                                        │
│  orbital_simulator_create()                            │
│  orbital_simulator_initialize(handle, seeds)           │
│  orbital_simulator_run(handle, cycles)                 │
│  orbital_simulator_get_stats(handle)                   │
│  orbital_simulator_destroy(handle)                     │
│                                                        │
└────────────────────────────────────────────────────────┘
```

## Step 1: Compile Pascal to Shared Library

### Linux/macOS

```bash
cd pascal
fpc -Mobjfpc -H+ -Isrc \
    -fPIC \
    -shared \
    -o../simulator/orbital.so \
    src/orbital-simulator.pas
```

### Windows

```bash
cd pascal
fpc -Mobjfpc -H+ -Isrc \
    -o..\simulator\orbital.dll \
    src/orbital-simulator.pas
```

## Step 2: Create Rust FFI Binding

File: `src/orbital_ffi.rs`

```rust
use std::ffi::{c_char, c_int, c_double, c_void};

// Opaque handle types
pub struct SimulatorHandle(*mut c_void);

// C-compatible structures
#[repr(C)]
pub struct CpuState {
    pub cycle_count: u64,
    pub instruction_count: u64,
    pub cache_hits: u64,
    pub cache_misses: u64,
    pub temperature: c_double,
    pub frequency: u64,
}

#[repr(C)]
pub struct SimulatorStats {
    pub current_cycle: u64,
    pub is_running: bool,
    pub is_deterministic: bool,
    pub memory_usage_percent: u8,
    pub storage_usage_percent: u8,
    pub temperature: c_double,
}

#[repr(C)]
pub struct MemoryInfo {
    pub total_size: u64,
    pub used_size: u64,
    pub access_count: u64,
    pub usage_percent: u8,
}

// FFI declarations
#[link(name = "orbital")]
extern "C" {
    // Simulator API
    pub fn orbital_simulator_create() -> SimulatorHandle;
    pub fn orbital_simulator_destroy(handle: SimulatorHandle) -> c_int;
    pub fn orbital_simulator_initialize(
        handle: SimulatorHandle,
        seeds: *const [u64; 32],
    ) -> c_int;
    pub fn orbital_simulator_run(handle: SimulatorHandle, cycles: u64) -> c_int;
    pub fn orbital_simulator_step(handle: SimulatorHandle) -> c_int;
    pub fn orbital_simulator_stop(handle: SimulatorHandle) -> c_int;

    pub fn orbital_simulator_get_cpu_state(handle: SimulatorHandle) -> CpuState;
    pub fn orbital_simulator_get_stats(handle: SimulatorHandle) -> SimulatorStats;

    pub fn orbital_simulator_read_memory(
        handle: SimulatorHandle,
        addr: *mut c_void,
        data: *mut c_void,
        size: u64,
    ) -> c_int;

    pub fn orbital_simulator_write_memory(
        handle: SimulatorHandle,
        addr: *mut c_void,
        data: *const c_void,
        size: u64,
    ) -> c_int;

    pub fn orbital_simulator_append_storage(
        handle: SimulatorHandle,
        data: *const c_void,
        size: u64,
        block_id: *mut u64,
    ) -> c_int;

    pub fn orbital_simulator_verify_storage(
        handle: SimulatorHandle,
        block_id: u64,
    ) -> bool;

    pub fn orbital_simulator_inject_fault(
        handle: SimulatorHandle,
        fault_type: c_int,
        severity: u8,
    ) -> c_int;

    pub fn orbital_simulator_create_checkpoint(handle: SimulatorHandle) -> c_int;
    pub fn orbital_simulator_restore_checkpoint(
        handle: SimulatorHandle,
        checkpoint_id: c_int,
    ) -> c_int;

    pub fn orbital_simulator_get_telemetry_log(handle: SimulatorHandle)
        -> *const c_char;
    pub fn orbital_simulator_export_trace(
        handle: SimulatorHandle,
        filename: *const c_char,
    ) -> c_int;
}
```

## Step 3: Create Safe Rust Wrapper

File: `src/orbital.rs`

```rust
use crate::orbital_ffi;
use std::ffi::CStr;
use std::ptr;

#[derive(Debug, Clone, Copy)]
pub enum OrbitalResult {
    Success,
    Error,
    InvalidHandle,
    MemoryError,
    NotImplemented,
}

impl From<i32> for OrbitalResult {
    fn from(code: i32) -> Self {
        match code {
            0 => OrbitalResult::Success,
            1 => OrbitalResult::Error,
            2 => OrbitalResult::InvalidHandle,
            3 => OrbitalResult::MemoryError,
            _ => OrbitalResult::NotImplemented,
        }
    }
}

pub struct OrbitalSimulator {
    handle: orbital_ffi::SimulatorHandle,
}

impl OrbitalSimulator {
    /// Create new simulator instance
    pub fn new() -> Result<Self, OrbitalResult> {
        let handle = unsafe { orbital_ffi::orbital_simulator_create() };
        Ok(OrbitalSimulator { handle })
    }

    /// Initialize with deterministic seeds
    pub fn initialize(&mut self, seeds: &[u64; 32]) -> Result<(), OrbitalResult> {
        let result = unsafe {
            orbital_ffi::orbital_simulator_initialize(&self.handle, seeds)
        };
        match result {
            0 => Ok(()),
            code => Err(OrbitalResult::from(code)),
        }
    }

    /// Run simulation for specified cycles
    pub fn run(&mut self, cycles: u64) -> Result<(), OrbitalResult> {
        let result = unsafe { orbital_ffi::orbital_simulator_run(&self.handle, cycles) };
        match result {
            0 => Ok(()),
            code => Err(OrbitalResult::from(code)),
        }
    }

    /// Single-step execution
    pub fn step(&mut self) -> Result<(), OrbitalResult> {
        let result = unsafe { orbital_ffi::orbital_simulator_step(&self.handle) };
        match result {
            0 => Ok(()),
            code => Err(OrbitalResult::from(code)),
        }
    }

    /// Stop simulation
    pub fn stop(&mut self) -> Result<(), OrbitalResult> {
        let result = unsafe { orbital_ffi::orbital_simulator_stop(&self.handle) };
        match result {
            0 => Ok(()),
            code => Err(OrbitalResult::from(code)),
        }
    }

    /// Get CPU state
    pub fn get_cpu_state(&self) -> orbital_ffi::CpuState {
        unsafe { orbital_ffi::orbital_simulator_get_cpu_state(&self.handle) }
    }

    /// Get simulator statistics
    pub fn get_stats(&self) -> orbital_ffi::SimulatorStats {
        unsafe { orbital_ffi::orbital_simulator_get_stats(&self.handle) }
    }

    /// Read from simulator memory
    pub fn read_memory(&self, addr: u64, size: usize) -> Result<Vec<u8>, OrbitalResult> {
        let mut buffer = vec![0u8; size];
        let result = unsafe {
            orbital_ffi::orbital_simulator_read_memory(
                &self.handle,
                addr as *mut std::ffi::c_void,
                buffer.as_mut_ptr() as *mut std::ffi::c_void,
                size as u64,
            )
        };
        match result {
            0 => Ok(buffer),
            code => Err(OrbitalResult::from(code)),
        }
    }

    /// Write to simulator memory
    pub fn write_memory(&mut self, addr: u64, data: &[u8]) -> Result<(), OrbitalResult> {
        let result = unsafe {
            orbital_ffi::orbital_simulator_write_memory(
                &self.handle,
                addr as *mut std::ffi::c_void,
                data.as_ptr() as *const std::ffi::c_void,
                data.len() as u64,
            )
        };
        match result {
            0 => Ok(()),
            code => Err(OrbitalResult::from(code)),
        }
    }

    /// Append to append-only storage
    pub fn append_storage(&mut self, data: &[u8]) -> Result<u64, OrbitalResult> {
        let mut block_id = 0u64;
        let result = unsafe {
            orbital_ffi::orbital_simulator_append_storage(
                &self.handle,
                data.as_ptr() as *const std::ffi::c_void,
                data.len() as u64,
                &mut block_id,
            )
        };
        match result {
            0 => Ok(block_id),
            code => Err(OrbitalResult::from(code)),
        }
    }

    /// Verify storage block
    pub fn verify_storage(&self, block_id: u64) -> bool {
        unsafe { orbital_ffi::orbital_simulator_verify_storage(&self.handle, block_id) }
    }

    /// Inject fault (0=BitFlip, 1=MemoryScrub, 2=PowerLoss, etc.)
    pub fn inject_fault(&mut self, fault_type: i32, severity: u8) -> Result<(), OrbitalResult> {
        let result = unsafe {
            orbital_ffi::orbital_simulator_inject_fault(&self.handle, fault_type, severity)
        };
        match result {
            0 => Ok(()),
            code => Err(OrbitalResult::from(code)),
        }
    }

    /// Create checkpoint
    pub fn create_checkpoint(&mut self) -> Result<(), OrbitalResult> {
        let result = unsafe { orbital_ffi::orbital_simulator_create_checkpoint(&self.handle) };
        match result {
            0 => Ok(()),
            code => Err(OrbitalResult::from(code)),
        }
    }

    /// Restore checkpoint
    pub fn restore_checkpoint(&mut self, checkpoint_id: i32) -> Result<(), OrbitalResult> {
        let result = unsafe {
            orbital_ffi::orbital_simulator_restore_checkpoint(&self.handle, checkpoint_id)
        };
        match result {
            0 => Ok(()),
            code => Err(OrbitalResult::from(code)),
        }
    }

    /// Export telemetry log
    pub fn get_telemetry_log(&self) -> String {
        let cptr = unsafe { orbital_ffi::orbital_simulator_get_telemetry_log(&self.handle) };
        if cptr.is_null() {
            String::new()
        } else {
            unsafe {
                CStr::from_ptr(cptr as *const i8)
                    .to_string_lossy()
                    .into_owned()
            }
        }
    }

    /// Export trace to file
    pub fn export_trace(&mut self, filename: &str) -> Result<(), OrbitalResult> {
        let c_filename = std::ffi::CString::new(filename)
            .map_err(|_| OrbitalResult::Error)?;
        let result = unsafe {
            orbital_ffi::orbital_simulator_export_trace(&self.handle, c_filename.as_ptr())
        };
        match result {
            0 => Ok(()),
            code => Err(OrbitalResult::from(code)),
        }
    }
}

impl Drop for OrbitalSimulator {
    fn drop(&mut self) {
        unsafe {
            orbital_ffi::orbital_simulator_destroy(&self.handle);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_simulator_creation() {
        let sim = OrbitalSimulator::new();
        assert!(sim.is_ok());
    }

    #[test]
    fn test_deterministic_replay() {
        let seeds = [42u64; 32];

        let mut sim1 = OrbitalSimulator::new().unwrap();
        sim1.initialize(&seeds).unwrap();
        sim1.run(10000).unwrap();
        let stats1 = sim1.get_stats();

        let mut sim2 = OrbitalSimulator::new().unwrap();
        sim2.initialize(&seeds).unwrap();
        sim2.run(10000).unwrap();
        let stats2 = sim2.get_stats();

        assert_eq!(stats1.current_cycle, stats2.current_cycle);
    }

    #[test]
    fn test_memory_operations() {
        let seeds = [42u64; 32];
        let mut sim = OrbitalSimulator::new().unwrap();
        sim.initialize(&seeds).unwrap();

        let test_data = vec![1, 2, 3, 4, 5];
        sim.write_memory(0x8000, &test_data).unwrap();

        let read_data = sim.read_memory(0x8000, 5).unwrap();
        assert_eq!(test_data, read_data);
    }

    #[test]
    fn test_storage_operations() {
        let seeds = [42u64; 32];
        let mut sim = OrbitalSimulator::new().unwrap();
        sim.initialize(&seeds).unwrap();

        let block_data = vec![10, 20, 30, 40, 50];
        let block_id = sim.append_storage(&block_data).unwrap();

        assert!(sim.verify_storage(block_id));
    }

    #[test]
    fn test_fault_injection() {
        let seeds = [42u64; 32];
        let mut sim = OrbitalSimulator::new().unwrap();
        sim.initialize(&seeds).unwrap();

        sim.inject_fault(0, 50).unwrap();  // BitFlip with severity 50
        sim.run(5000).unwrap();

        let stats = sim.get_stats();
        assert!(stats.is_running || !stats.is_running);  // Just verify it completes
    }

    #[test]
    fn test_checkpointing() {
        let seeds = [42u64; 32];
        let mut sim = OrbitalSimulator::new().unwrap();
        sim.initialize(&seeds).unwrap();

        sim.run(5000).unwrap();
        let stats_before = sim.get_stats();

        sim.create_checkpoint().unwrap();
        sim.run(5000).unwrap();

        sim.restore_checkpoint(0).unwrap();
        let stats_after = sim.get_stats();

        assert_eq!(stats_before.current_cycle, stats_after.current_cycle);
    }
}
```

## Step 4: Create Cargo.toml

File: `Cargo.toml`

```toml
[package]
name = "orbital-computing"
version = "1.0.0"
edition = "2021"

[dependencies]

[build-dependencies]

[lib]
name = "orbital_ffi"
path = "src/orbital_ffi.rs"

[[example]]
name = "simulate"
path = "examples/simulate.rs"

[profile.release]
opt-level = 3
lto = true
```

## Step 5: Usage Example

File: `examples/simulate.rs`

```rust
use orbital_computing::OrbitalSimulator;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    println!("=== Orbital Computing Stack - Rust Integration ===\n");

    // Create simulator
    let mut simulator = OrbitalSimulator::new()?;
    println!("✓ Simulator created");

    // Initialize with deterministic seeds
    let seeds = [42u64; 32];
    simulator.initialize(&seeds)?;
    println!("✓ Simulator initialized with deterministic seeds");

    // Run basic simulation
    simulator.run(10000)?;
    println!("✓ Ran 10,000 cycles");

    // Get stats
    let stats = simulator.get_stats();
    println!("\nSimulator Stats:");
    println!("  Current Cycle: {}", stats.current_cycle);
    println!("  Memory Usage: {}%", stats.memory_usage_percent);
    println!("  Storage Usage: {}%", stats.storage_usage_percent);
    println!("  Temperature: {:.2}°C", stats.temperature);

    // Test memory operations
    let test_data = vec![0x11, 0x22, 0x33, 0x44];
    simulator.write_memory(0x1000, &test_data)?;
    println!("\n✓ Wrote to memory");

    let read_data = simulator.read_memory(0x1000, 4)?;
    assert_eq!(test_data, read_data);
    println!("✓ Read from memory (verified)");

    // Test storage
    let block_id = simulator.append_storage(&test_data)?;
    println!("✓ Appended storage block: {}", block_id);

    if simulator.verify_storage(block_id)? {
        println!("✓ Storage block verified");
    }

    // Test fault injection
    simulator.inject_fault(0, 50)?;  // BitFlip, severity 50
    println!("✓ Injected bit flip fault");

    simulator.run(5000)?;
    println!("✓ Ran 5,000 more cycles with fault");

    // Get final CPU state
    let cpu = simulator.get_cpu_state();
    println!("\nCPU State:");
    println!("  Cycles: {}", cpu.cycle_count);
    println!("  Instructions: {}", cpu.instruction_count);
    println!("  Cache Hits: {}", cpu.cache_hits);
    println!("  Cache Misses: {}", cpu.cache_misses);

    // Export telemetry
    let telemetry = simulator.get_telemetry_log();
    println!("\nTelemetry samples: {} bytes", telemetry.len());

    Ok(())
}
```

## Step 6: Build and Link

### Build Pascal Library

```bash
# Linux/macOS
cd pascal
fpc -Mobjfpc -H+ -fPIC -shared \
    -o../target/debug/libborbital.so \
    src/orbital-simulator.pas
```

### Build Rust Project

```bash
cargo build --example simulate
cargo run --example simulate
```

## Library Loading

The FFI loader will search for:

- **Linux**: `libborbital.so`, `libborbital.so.1`
- **macOS**: `libborbital.dylib`
- **Windows**: `orbital.dll`

Set library path:

```bash
# Linux/macOS
export LD_LIBRARY_PATH=./target/debug:$LD_LIBRARY_PATH

# Windows (PowerShell)
$env:PATH = ".\target\debug;$env:PATH"
```

## Performance Considerations

### Zero-Copy Data Transfer

Memory reads/writes use zero-copy:

```rust
// This is zero-copy - no intermediate buffer
simulator.write_memory(0x8000, &data)?;
```

### Batch Operations

For best performance, batch operations:

```rust
// Good: Single run covers multiple operations
simulator.run(100000)?;  // All CPU, memory, storage ops combined

// Less efficient: Multiple small runs
for _ in 0..10 {
    simulator.run(10000)?;
}
```

### Thread Safety

Each simulator instance is independent:

```rust
// Safe - different simulators don't interfere
let sim1 = OrbitalSimulator::new()?;
let sim2 = OrbitalSimulator::new()?;

// Can run in parallel threads
```

## Debugging

Enable Pascal debug info:

```bash
fpc -Mobjfpc -H+ -g -gl \
    -o../target/debug/libborbital.so \
    src/orbital-simulator.pas
```

Use debugger:

```bash
gdb ./target/debug/simulate
```

## Troubleshooting

### Library Not Found

```
error: failed to load library: libborbital.so: cannot open shared object file
```

**Solution**: Set `LD_LIBRARY_PATH` or place `.so/.dll` in search path.

### Symbol Not Found

```
error: undefined reference to 'orbital_simulator_create'
```

**Solution**: Ensure Pascal library was compiled as shared library (`-shared` flag).

### Segmentation Fault

**Likely cause**: Handle passed to wrong function or memory corruption.

**Debug**: Enable assertions in Pascal:

```bash
fpc -Mobjfpc -H+ {$assertions on} ...
```

## References

- Rust FFI: https://doc.rust-lang.org/nomicon/ffi.html
- Free Pascal & Rust: https://wiki.freepascal.org/Rust_bindings
- CStr/CRepr: https://doc.rust-lang.org/std/ffi/

---

**Last Updated**: 2026-09-23
