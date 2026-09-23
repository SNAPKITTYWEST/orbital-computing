{  SPDX-License-Identifier: AGPL-3.0-or-later OR Apache-2.0  }
{  CLONE_GATE:AES256:0835efdf190609d335eceaed143e605993cafac9c2a3ffc3afd7d8395aaa30fb  }
{
  Orbital FFI Bridge for Rust Integration
  =======================================
  C-compatible interface for Rust FFI.
  All opaque handles and sealed types.
}

unit OrbitalFfi;

{$mode objfpc}
{$H+}
{$packrecords c}
{$assertions on}

interface

type
  { Opaque handles }
  THardwareHandle = type Pointer;
  TMemoryHandle = type Pointer;
  TRuntimeHandle = type Pointer;
  TSimulatorHandle = type Pointer;

  { Result codes (C-compatible) }
  TOrbitalResult = (
    orbSuccess = 0,
    orbError = 1,
    orbInvalidHandle = 2,
    orbMemoryError = 3,
    orbNotImplemented = 4
  );

  { C-compatible seed array }
  TSeedArray = record
    Seeds: array[0..31] of QWord;
  end;

  { C-compatible CPU state }
  TCpuStateC = record
    CycleCount: QWord;
    InstructionCount: QWord;
    CacheHits: QWord;
    CacheMisses: QWord;
    Temperature: Double;
    Frequency: QWord;
  end;

  { C-compatible memory info }
  TMemoryInfoC = record
    TotalSize: QWord;
    UsedSize: QWord;
    AccessCount: QWord;
    UsagePercent: Byte;
  end;

  { C-compatible simulator stats }
  TSimulatorStatsC = record
    CurrentCycle: QWord;
    IsRunning: Boolean;
    IsDeterministic: Boolean;
    MemoryUsagePercent: Byte;
    StorageUsagePercent: Byte;
    Temperature: Double;
  end;

{ Hardware API }
function orbital_hardware_initialize: TOrbitalResult; cdecl; external name 'orbital_hardware_initialize';
function orbital_hardware_finalize: TOrbitalResult; cdecl; external name 'orbital_hardware_finalize';
function orbital_hardware_diagnostics: PChar; cdecl; external name 'orbital_hardware_diagnostics';

{ Memory API }
function orbital_memory_allocate(Size: QWord): Pointer; cdecl; external name 'orbital_memory_allocate';
function orbital_memory_deallocate(Ptr: Pointer): TOrbitalResult; cdecl; external name 'orbital_memory_deallocate';
function orbital_memory_read(Addr: Pointer; var Data; Size: QWord): TOrbitalResult; cdecl; external name 'orbital_memory_read';
function orbital_memory_write(Addr: Pointer; const Data; Size: QWord): TOrbitalResult; cdecl; external name 'orbital_memory_write';
function orbital_memory_verify(Addr: Pointer; Size: QWord): Boolean; cdecl; external name 'orbital_memory_verify';
function orbital_memory_get_info: TMemoryInfoC; cdecl; external name 'orbital_memory_get_info';

{ Runtime API }
function orbital_runtime_initialize: TRuntimeHandle; cdecl; external name 'orbital_runtime_initialize';
function orbital_runtime_hash(const Data; Size: QWord): PChar; cdecl; external name 'orbital_runtime_hash';
function orbital_runtime_sign(const Data; Size: QWord): PChar; cdecl; external name 'orbital_runtime_sign';
function orbital_runtime_verify(const Data; Size: QWord; const Signature: PChar): Boolean; cdecl; external name 'orbital_runtime_verify';

{ Simulator API }
function orbital_simulator_create: TSimulatorHandle; cdecl; external name 'orbital_simulator_create';
function orbital_simulator_destroy(Handle: TSimulatorHandle): TOrbitalResult; cdecl; external name 'orbital_simulator_destroy';
function orbital_simulator_initialize(Handle: TSimulatorHandle; const Seeds: TSeedArray): TOrbitalResult; cdecl; external name 'orbital_simulator_initialize';
function orbital_simulator_run(Handle: TSimulatorHandle; Cycles: QWord): TOrbitalResult; cdecl; external name 'orbital_simulator_run';
function orbital_simulator_step(Handle: TSimulatorHandle): TOrbitalResult; cdecl; external name 'orbital_simulator_step';
function orbital_simulator_stop(Handle: TSimulatorHandle): TOrbitalResult; cdecl; external name 'orbital_simulator_stop';

function orbital_simulator_get_cpu_state(Handle: TSimulatorHandle): TCpuStateC; cdecl; external name 'orbital_simulator_get_cpu_state';
function orbital_simulator_get_stats(Handle: TSimulatorHandle): TSimulatorStatsC; cdecl; external name 'orbital_simulator_get_stats';

function orbital_simulator_read_memory(Handle: TSimulatorHandle; Addr: Pointer; var Data; Size: QWord): TOrbitalResult; cdecl; external name 'orbital_simulator_read_memory';
function orbital_simulator_write_memory(Handle: TSimulatorHandle; Addr: Pointer; const Data; Size: QWord): TOrbitalResult; cdecl; external name 'orbital_simulator_write_memory';

function orbital_simulator_append_storage(Handle: TSimulatorHandle; const Data; Size: QWord; var BlockId: QWord): TOrbitalResult; cdecl; external name 'orbital_simulator_append_storage';
function orbital_simulator_verify_storage(Handle: TSimulatorHandle; BlockId: QWord): Boolean; cdecl; external name 'orbital_simulator_verify_storage';

function orbital_simulator_inject_fault(Handle: TSimulatorHandle; FaultType: Integer; Severity: Byte): TOrbitalResult; cdecl; external name 'orbital_simulator_inject_fault';

function orbital_simulator_create_checkpoint(Handle: TSimulatorHandle): TOrbitalResult; cdecl; external name 'orbital_simulator_create_checkpoint';
function orbital_simulator_restore_checkpoint(Handle: TSimulatorHandle; CheckpointId: Integer): TOrbitalResult; cdecl; external name 'orbital_simulator_restore_checkpoint';

function orbital_simulator_get_telemetry_log(Handle: TSimulatorHandle): PChar; cdecl; external name 'orbital_simulator_get_telemetry_log';
function orbital_simulator_export_trace(Handle: TSimulatorHandle; Filename: PChar): TOrbitalResult; cdecl; external name 'orbital_simulator_export_trace';

implementation

end.
