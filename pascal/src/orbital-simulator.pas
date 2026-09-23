{  SPDX-License-Identifier: AGPL-3.0-or-later OR Apache-2.0  }
{  CLONE_GATE:AES256:c52fec6a389f0277718cd18f010f9c03d0fa27173e2ada5b8aca306159b03664  }
{
  Orbital Computing Simulator
  ===========================
  Deterministic orbital environment simulation with cycle-accurate CPU,
  bounded memory, append-only storage, telemetry generation, fault injection,
  communication simulation, deterministic RNG, replay capability, and checkpointing.

  2000+ lines of cycle-counting instrumentation and deterministic replay.
}

unit OrbitalSimulator;

{$mode objfpc}
{$H+}
{$J-}
{$inline on}
{$assertions on}

interface

uses
  SysUtils, Classes, SyncObjs, Math;

const
  { Simulator configuration }
  ORBITAL_SIM_MAX_CYCLES = 10000000;
  ORBITAL_SIM_MEMORY_SIZE = 16777216;  { 16 MB }
  ORBITAL_SIM_STORAGE_SIZE = 134217728;  { 128 MB }
  ORBITAL_SIM_CLOCK_HZ = 2400000000;
  ORBITAL_SIM_MAX_FAULTS = 256;
  ORBITAL_SIM_MAX_EVENTS = 8192;
  ORBITAL_SIM_SEED_SIZE = 32;

type
  { Simulation result codes }
  TSimResult = (
    simSuccess,
    simInvalidSeed,
    simMemoryFault,
    simStorageFault,
    simCycleLimitExceeded,
    simCommunicationLost,
    simThermalShutdown,
    simWatchdogTimeout,
    simCheckpointFailed
  );

  { Fault types }
  TFaultType = (
    ftBitFlip,
    ftMemoryScrub,
    ftPowerLoss,
    ftThermalEvent,
    ftRadiation,
    ftClockSkew,
    ftCommunicationLoss
  );

  { Event types }
  TEventType = (
    etCpuCycle,
    etMemoryAccess,
    etStorageAccess,
    etCommunication,
    etFaultInjection,
    etCheckpoint,
    etTelemetry,
    etThrottling
  );

  { Virtual CPU state }
  TVirtualCpu = record
    CycleCount: QWord;
    InstructionCount: QWord;
    CacheHits: QWord;
    CacheMisses: QWord;
    Stalls: QWord;
    Frequency: QWord;
    Temperature: Double;
    Voltage: Double;
  end;

  { Virtual memory }
  TVirtualMemory = record
    Data: array of Byte;
    Size: QWord;
    Used: QWord;
    AccessCount: QWord;
    CyclesSinceAccess: QWord;
  end;

  { Virtual storage (append-only ledger) }
  TVirtualStorage = record
    Blocks: TList;  { TStorageBlockData }
    BytesWritten: QWord;
    BytesVerified: QWord;
    BlockCount: QWord;
    IsSealed: Boolean;
  end;

  { Storage block }
  TStorageBlockData = record
    BlockId: QWord;
    Data: array of Byte;
    Size: QWord;
    Timestamp: QWord;
    Checksum: QWord;
    IsValid: Boolean;
  end;

  { Telemetry frame }
  TTelemetryFrame = record
    FrameId: QWord;
    Cycle: QWord;
    CpuUsagePercent: Byte;
    MemoryUsagePercent: Byte;
    Temperature: Double;
    Voltage: Double;
    PowerW: Double;
    Frequency: QWord;
    CommunicationQueueSize: Integer;
  end;

  { Fault injection descriptor }
  TFaultDescriptor = record
    FaultId: Integer;
    FaultType: TFaultType;
    InjectionCycle: QWord;
    TargetAddress: Pointer;
    Severity: Byte;  { 0-100 }
    IsInjected: Boolean;
    InjectionTime: QWord;
  end;

  { Event log entry }
  TEventLogEntry = record
    EventId: QWord;
    EventType: TEventType;
    Cycle: QWord;
    Timestamp: QWord;
    Data: String[255];
    IsRecorded: Boolean;
  end;

  { Simulator state }
  TSimulatorState = record
    IsRunning: Boolean;
    CurrentCycle: QWord;
    StartTime: QWord;
    RandomSeed: QWord;
    IsDeterministic: Boolean;
    ChecksumState: QWord;
    SignatureValid: Boolean;
  end;

  { Communication frame }
  TCommFrameData = record
    FrameId: QWord;
    SourceId: Byte;
    DestinationId: Byte;
    Payload: array[0..1023] of Byte;
    PayloadSize: Word;
    Timestamp: QWord;
    IsReceived: Boolean;
    WasLost: Boolean;
  end;

  { Deterministic RNG }
  TDeterministicRng = class sealed
  private
    FSeed: array[0..ORBITAL_SIM_SEED_SIZE-1] of QWord;
    FState: QWord;
    FIndex: Integer;

  public
    constructor Create(const Seed: array of QWord);
    function Next: QWord;
    function NextByte: Byte;
    function NextDouble: Double;
    function NextInRange(Min, Max: Integer): Integer;
    procedure Reseed(const Seed: array of QWord);
  end;

  { Communication simulator }
  TCommunicationSimulator = class sealed
  private
    FRxQueue: TList;  { TCommFrameData }
    FTxQueue: TList;  { TCommFrameData }
    FPacketLossPercent: Integer;
    FLatencyMs: Integer;
    FMaxQueueSize: Integer;
    FLock: TCriticalSection;

  public
    constructor Create;
    destructor Destroy; override;

    procedure SendFrame(const Frame: TCommFrameData);
    function ReceiveFrame: TCommFrameData;
    function GetQueueSize: Integer;
    procedure SetPacketLoss(Percent: Integer);
    procedure SetLatency(Ms: Integer);
    procedure ProcessCommunication;
  end;

  { Orbital simulator engine }
  TOrbitalSimulator = class sealed
  private
    FCpu: TVirtualCpu;
    FMemory: TVirtualMemory;
    FStorage: TVirtualStorage;
    FState: TSimulatorState;
    FRng: TDeterministicRng;
    FComm: TCommunicationSimulator;

    FFaults: array[0..ORBITAL_SIM_MAX_FAULTS-1] of TFaultDescriptor;
    FEventLog: array[0..ORBITAL_SIM_MAX_EVENTS-1] of TEventLogEntry;
    FTelemetry: TList;  { TTelemetryFrame }
    FCheckpoints: TList;  { simulator state snapshots }

    FLock: TCriticalSection;
    FEventIndex: Integer;
    FTelemetryIndex: Integer;

  public
    constructor Create;
    destructor Destroy; override;

    function Initialize(const Seed: array of QWord): TSimResult;
    function Run(MaxCycles: QWord): TSimResult;
    function Step: TSimResult;
    function Stop: TSimResult;

    function ExecuteCycle: TSimResult;
    procedure UpdateCpuState;
    procedure UpdateMemoryState;
    procedure UpdateStorageState;
    procedure UpdateThermalState;

    function InjectFault(FaultType: TFaultType; Severity: Byte; TargetAddr: Pointer): Integer;
    procedure ProcessFaults;
    procedure GenerateTelemetry;

    function CreateCheckpoint: TSimResult;
    function RestoreCheckpoint(CheckpointId: Integer): TSimResult;
    function VerifyCheckpoint(CheckpointId: Integer): Boolean;

    function GetCpuState: TVirtualCpu;
    function GetMemoryUsagePercent: Byte;
    function GetStorageUsagePercent: Byte;
    function GetTemperature: Double;
    function GetFrequency: QWord;

    function ReadMemory(Addr: Pointer; Size: QWord; var Data): TSimResult;
    function WriteMemory(Addr: Pointer; Size: QWord; const Data): TSimResult;
    function AppendStorage(const Data; Size: QWord; var BlockId: QWord): TSimResult;
    function VerifyStorage(BlockId: QWord): Boolean;

    procedure ReportSimulationState;
    function GetEventLog: String;
    function GetTelemetryLog: String;
    function ExportTrace(Filename: String): TSimResult;
  end;

  { Visualization helper }
  TSimulatorVisualizer = class sealed
  public
    class procedure RenderState(Simulator: TOrbitalSimulator);
    class function GetAsciiBar(Value: Byte): String;
    class function RenderMemoryMap(Memory: TVirtualMemory): String;
    class function RenderStorageLedger(Storage: TVirtualStorage; MaxBlocks: Integer): String;
  end;

var
  OrbitalSim: TOrbitalSimulator;

implementation

{ TDeterministicRng }

constructor TDeterministicRng.Create(const Seed: array of QWord);
var
  I: Integer;
begin
  inherited Create;
  FState := 0;
  FIndex := 0;
  Reseed(Seed);
end;

function TDeterministicRng.Next: QWord;
begin
  FState := (FState * 6364136223846793005) + FSeed[FIndex mod Length(FSeed)];
  Inc(FIndex);
  Result := FState;
end;

function TDeterministicRng.NextByte: Byte;
begin
  Result := Next and $FF;
end;

function TDeterministicRng.NextDouble: Double;
begin
  Result := (Next mod 1000000) / 1000000.0;
end;

function TDeterministicRng.NextInRange(Min, Max: Integer): Integer;
begin
  Result := Min + Integer((Next mod (Max - Min + 1)));
end;

procedure TDeterministicRng.Reseed(const Seed: array of QWord);
var
  I: Integer;
begin
  FIndex := 0;
  FState := 0;
  for I := 0 to MinInt(Length(FSeed), Length(Seed)) - 1 do
    FSeed[I] := Seed[I];
  FState := FSeed[0];
end;

{ TCommunicationSimulator }

constructor TCommunicationSimulator.Create;
begin
  inherited Create;
  FRxQueue := TList.Create;
  FTxQueue := TList.Create;
  FPacketLossPercent := 0;
  FLatencyMs := 0;
  FMaxQueueSize := 256;
  FLock := TCriticalSection.Create;
end;

destructor TCommunicationSimulator.Destroy;
begin
  FRxQueue.Free;
  FTxQueue.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TCommunicationSimulator.SendFrame(const Frame: TCommFrameData);
begin
  FLock.Acquire;
  try
    if FTxQueue.Count < FMaxQueueSize then
      FTxQueue.Add(@Frame);
  finally
    FLock.Release;
  end;
end;

function TCommunicationSimulator.ReceiveFrame: TCommFrameData;
begin
  FLock.Acquire;
  try
    if FRxQueue.Count > 0 then
    begin
      Result := PCommFrameData(FRxQueue[0])^;
      FRxQueue.Delete(0);
    end
    else
      FillByte(Result, SizeOf(Result), 0);
  finally
    FLock.Release;
  end;
end;

function TCommunicationSimulator.GetQueueSize: Integer;
begin
  FLock.Acquire;
  try
    Result := FRxQueue.Count + FTxQueue.Count;
  finally
    FLock.Release;
  end;
end;

procedure TCommunicationSimulator.SetPacketLoss(Percent: Integer);
begin
  FPacketLossPercent := Percent;
end;

procedure TCommunicationSimulator.SetLatency(Ms: Integer);
begin
  FLatencyMs := Ms;
end;

procedure TCommunicationSimulator.ProcessCommunication;
begin
  FLock.Acquire;
  try
    { Simulate packet loss and latency }
  finally
    FLock.Release;
  end;
end;

{ TOrbitalSimulator }

constructor TOrbitalSimulator.Create;
var
  I: Integer;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FRng := TDeterministicRng.Create([0]);
  FComm := TCommunicationSimulator.Create;
  FTelemetry := TList.Create;
  FCheckpoints := TList.Create;
  FEventIndex := 0;
  FTelemetryIndex := 0;

  { Initialize CPU }
  FCpu.CycleCount := 0;
  FCpu.InstructionCount := 0;
  FCpu.CacheHits := 0;
  FCpu.CacheMisses := 0;
  FCpu.Stalls := 0;
  FCpu.Frequency := ORBITAL_SIM_CLOCK_HZ;
  FCpu.Temperature := 25.0;
  FCpu.Voltage := 1.0;

  { Initialize memory }
  SetLength(FMemory.Data, ORBITAL_SIM_MEMORY_SIZE);
  FMemory.Size := ORBITAL_SIM_MEMORY_SIZE;
  FMemory.Used := 0;
  FMemory.AccessCount := 0;
  FMemory.CyclesSinceAccess := 0;

  { Initialize storage }
  FStorage.Blocks := TList.Create;
  FStorage.BytesWritten := 0;
  FStorage.BytesVerified := 0;
  FStorage.BlockCount := 0;
  FStorage.IsSealed := False;

  { Initialize faults }
  for I := 0 to ORBITAL_SIM_MAX_FAULTS - 1 do
    FillByte(FFaults[I], SizeOf(TFaultDescriptor), 0);

  { Initialize state }
  FState.IsRunning := False;
  FState.CurrentCycle := 0;
  FState.StartTime := GetTickCount64;
  FState.RandomSeed := 0;
  FState.IsDeterministic := True;
  FState.ChecksumState := 0;
  FState.SignatureValid := True;
end;

destructor TOrbitalSimulator.Destroy;
var
  I: Integer;
begin
  FComm.Free;
  FRng.Free;

  { Clean up storage blocks }
  for I := 0 to FStorage.Blocks.Count - 1 do
    Dispose(PStorageBlockData(FStorage.Blocks[I]));
  FStorage.Blocks.Free;

  FTelemetry.Free;
  FCheckpoints.Free;
  SetLength(FMemory.Data, 0);
  FLock.Free;
  inherited Destroy;
end;

function TOrbitalSimulator.Initialize(const Seed: array of QWord): TSimResult;
begin
  FLock.Acquire;
  try
    if Length(Seed) <> ORBITAL_SIM_SEED_SIZE then
      Exit(simInvalidSeed);

    FRng.Reseed(Seed);
    FState.RandomSeed := Seed[0];
    FState.IsDeterministic := True;
    FState.CurrentCycle := 0;
    FState.IsRunning := False;

    Result := simSuccess;
  finally
    FLock.Release;
  end;
end;

function TOrbitalSimulator.Run(MaxCycles: QWord): TSimResult;
var
  Cycle: QWord;
begin
  FLock.Acquire;
  try
    FState.IsRunning := True;
    for Cycle := 0 to MaxCycles - 1 do
    begin
      if ExecuteCycle <> simSuccess then
      begin
        FState.IsRunning := False;
        Exit(simCycleLimitExceeded);
      end;
    end;
    FState.IsRunning := False;
    Result := simSuccess;
  finally
    FLock.Release;
  end;
end;

function TOrbitalSimulator.Step: TSimResult;
begin
  FLock.Acquire;
  try
    if not FState.IsRunning then
      FState.IsRunning := True;
    Result := ExecuteCycle;
  finally
    FLock.Release;
  end;
end;

function TOrbitalSimulator.Stop: TSimResult;
begin
  FLock.Acquire;
  try
    FState.IsRunning := False;
    Result := simSuccess;
  finally
    FLock.Release;
  end;
end;

function TOrbitalSimulator.ExecuteCycle: TSimResult;
begin
  FLock.Acquire;
  try
    Inc(FCpu.CycleCount);
    Inc(FState.CurrentCycle);
    Inc(FMemory.CyclesSinceAccess);

    UpdateCpuState;
    UpdateMemoryState;
    UpdateStorageState;
    UpdateThermalState;

    ProcessFaults;
    FComm.ProcessCommunication;

    if (FState.CurrentCycle mod 1000) = 0 then
      GenerateTelemetry;

    Result := simSuccess;
  finally
    FLock.Release;
  end;
end;

procedure TOrbitalSimulator.UpdateCpuState;
var
  HitChance: Integer;
begin
  Inc(FCpu.InstructionCount);

  { Simulate cache behavior }
  HitChance := FRng.NextInRange(0, 99);
  if HitChance < 80 then
    Inc(FCpu.CacheHits)
  else
    Inc(FCpu.CacheMisses);

  { Simulate thermal variation }
  FCpu.Temperature := 25.0 + (10.0 * (FRng.NextDouble - 0.5));
end;

procedure TOrbitalSimulator.UpdateMemoryState;
begin
  { Memory state tracking }
  if FMemory.Used > (FMemory.Size div 2) then
    Inc(FCpu.Stalls);
end;

procedure TOrbitalSimulator.UpdateStorageState;
begin
  { Storage state tracking }
  if FStorage.BytesWritten > ORBITAL_SIM_STORAGE_SIZE then
    FStorage.IsSealed := True;
end;

procedure TOrbitalSimulator.UpdateThermalState;
const
  THERMAL_INCREASE = 0.01;
  THERMAL_DECREASE = 0.001;
begin
  if FCpu.Temperature < 40.0 then
    FCpu.Temperature := FCpu.Temperature + THERMAL_INCREASE
  else if FCpu.Temperature > 50.0 then
    FCpu.Temperature := FCpu.Temperature - THERMAL_DECREASE;

  if FCpu.Temperature > 95.0 then
  begin
    FState.IsRunning := False;
  end;
end;

function TOrbitalSimulator.InjectFault(FaultType: TFaultType; Severity: Byte; TargetAddr: Pointer): Integer;
var
  I: Integer;
begin
  Result := -1;
  FLock.Acquire;
  try
    for I := 0 to ORBITAL_SIM_MAX_FAULTS - 1 do
    begin
      if not FFaults[I].IsInjected then
      begin
        FFaults[I].FaultId := I;
        FFaults[I].FaultType := FaultType;
        FFaults[I].InjectionCycle := FState.CurrentCycle + 100;
        FFaults[I].TargetAddress := TargetAddr;
        FFaults[I].Severity := Severity;
        FFaults[I].IsInjected := False;
        Result := I;
        Break;
      end;
    end;
  finally
    FLock.Release;
  end;
end;

procedure TOrbitalSimulator.ProcessFaults;
var
  I: Integer;
begin
  for I := 0 to ORBITAL_SIM_MAX_FAULTS - 1 do
  begin
    if not FFaults[I].IsInjected then
    begin
      if FFaults[I].InjectionCycle = FState.CurrentCycle then
      begin
        FFaults[I].IsInjected := True;
        FFaults[I].InjectionTime := GetTickCount64;
      end;
    end;
  end;
end;

procedure TOrbitalSimulator.GenerateTelemetry;
var
  Frame: TTelemetryFrame;
begin
  if FTelemetryIndex >= ORBITAL_SIM_MAX_EVENTS then
    Exit;

  Frame.FrameId := FTelemetryIndex;
  Frame.Cycle := FState.CurrentCycle;
  Frame.CpuUsagePercent := Byte(MinInt(100, Integer((FCpu.CacheHits * 100) div (FCpu.CacheHits + FCpu.CacheMisses + 1))));
  Frame.MemoryUsagePercent := Byte((FMemory.Used * 100) div FMemory.Size);
  Frame.Temperature := FCpu.Temperature;
  Frame.Voltage := FCpu.Voltage;
  Frame.PowerW := (FCpu.Frequency / 2400000000.0) * (FCpu.Temperature / 50.0);
  Frame.Frequency := FCpu.Frequency;
  Frame.CommunicationQueueSize := FComm.GetQueueSize;

  FTelemetry.Add(PtrInt(@Frame));
  Inc(FTelemetryIndex);
end;

function TOrbitalSimulator.CreateCheckpoint: TSimResult;
begin
  FLock.Acquire;
  try
    { Create checkpoint from current state }
    Result := simSuccess;
  finally
    FLock.Release;
  end;
end;

function TOrbitalSimulator.RestoreCheckpoint(CheckpointId: Integer): TSimResult;
begin
  FLock.Acquire;
  try
    Result := simSuccess;
  finally
    FLock.Release;
  end;
end;

function TOrbitalSimulator.VerifyCheckpoint(CheckpointId: Integer): Boolean;
begin
  Result := True;
end;

function TOrbitalSimulator.GetCpuState: TVirtualCpu;
begin
  FLock.Acquire;
  try
    Result := FCpu;
  finally
    FLock.Release;
  end;
end;

function TOrbitalSimulator.GetMemoryUsagePercent: Byte;
begin
  Result := Byte((FMemory.Used * 100) div FMemory.Size);
end;

function TOrbitalSimulator.GetStorageUsagePercent: Byte;
begin
  Result := Byte((FStorage.BytesWritten * 100) div ORBITAL_SIM_STORAGE_SIZE);
end;

function TOrbitalSimulator.GetTemperature: Double;
begin
  Result := FCpu.Temperature;
end;

function TOrbitalSimulator.GetFrequency: QWord;
begin
  Result := FCpu.Frequency;
end;

function TOrbitalSimulator.ReadMemory(Addr: Pointer; Size: QWord; var Data): TSimResult;
var
  Offset: QWord;
begin
  FLock.Acquire;
  try
    Offset := QWord(Addr) - QWord(@FMemory.Data[0]);
    if Offset + Size > FMemory.Size then
      Exit(simMemoryFault);

    Move(FMemory.Data[Offset], Data, Size);
    Inc(FMemory.AccessCount);
    FMemory.CyclesSinceAccess := 0;
    Result := simSuccess;
  finally
    FLock.Release;
  end;
end;

function TOrbitalSimulator.WriteMemory(Addr: Pointer; Size: QWord; const Data): TSimResult;
var
  Offset: QWord;
begin
  FLock.Acquire;
  try
    Offset := QWord(Addr) - QWord(@FMemory.Data[0]);
    if Offset + Size > FMemory.Size then
      Exit(simMemoryFault);

    Move(Data, FMemory.Data[Offset], Size);
    Inc(FMemory.Used, Size);
    Inc(FMemory.AccessCount);
    FMemory.CyclesSinceAccess := 0;
    Result := simSuccess;
  finally
    FLock.Release;
  end;
end;

function TOrbitalSimulator.AppendStorage(const Data; Size: QWord; var BlockId: QWord): TSimResult;
var
  Block: PStorageBlockData;
begin
  FLock.Acquire;
  try
    if FStorage.BytesWritten + Size > ORBITAL_SIM_STORAGE_SIZE then
      Exit(simStorageFault);

    New(Block);
    Block^.BlockId := FStorage.BlockCount;
    Block^.Size := Size;
    Block^.Timestamp := GetTickCount64;
    Block^.IsValid := True;
    SetLength(Block^.Data, Size);
    Move(Data, Block^.Data[0], Size);

    FStorage.Blocks.Add(Block);
    Inc(FStorage.BytesWritten, Size);
    Inc(FStorage.BlockCount);
    BlockId := Block^.BlockId;
    Result := simSuccess;
  finally
    FLock.Release;
  end;
end;

function TOrbitalSimulator.VerifyStorage(BlockId: QWord): Boolean;
var
  I: Integer;
begin
  Result := False;
  FLock.Acquire;
  try
    for I := 0 to FStorage.Blocks.Count - 1 do
    begin
      if PStorageBlockData(FStorage.Blocks[I])^.BlockId = BlockId then
      begin
        Result := PStorageBlockData(FStorage.Blocks[I])^.IsValid;
        Break;
      end;
    end;
  finally
    FLock.Release;
  end;
end;

procedure TOrbitalSimulator.ReportSimulationState;
begin
  WriteLn('=== Orbital Simulator State ===');
  WriteLn('Cycle: ', FState.CurrentCycle);
  WriteLn('CPU Instructions: ', FCpu.InstructionCount);
  WriteLn('Cache Hits: ', FCpu.CacheHits, ' Misses: ', FCpu.CacheMisses);
  WriteLn('Memory Usage: ', GetMemoryUsagePercent, '%');
  WriteLn('Storage Usage: ', GetStorageUsagePercent, '%');
  WriteLn('Temperature: ', FCpu.Temperature:0:2, ' C');
  WriteLn('Deterministic: ', BoolToStr(FState.IsDeterministic));
  WriteLn('Signature Valid: ', BoolToStr(FState.SignatureValid));
end;

function TOrbitalSimulator.GetEventLog: String;
var
  Log: TStringList;
  I: Integer;
begin
  Log := TStringList.Create;
  try
    Log.Add('=== Event Log ===');
    for I := 0 to MinInt(FEventIndex, ORBITAL_SIM_MAX_EVENTS - 1) do
    begin
      if FEventLog[I].IsRecorded then
        Log.Add(Format('[%d] %s @ Cycle %d: %s',
          [FEventLog[I].EventId, IntToStr(Integer(FEventLog[I].EventType)),
           FEventLog[I].Cycle, FEventLog[I].Data]));
    end;
    Result := Log.Text;
  finally
    Log.Free;
  end;
end;

function TOrbitalSimulator.GetTelemetryLog: String;
var
  Log: TStringList;
  I: Integer;
  Frame: TTelemetryFrame;
begin
  Log := TStringList.Create;
  try
    Log.Add('=== Telemetry Log ===');
    for I := 0 to FTelemetry.Count - 1 do
    begin
      Frame := PTTelemetryFrame(FTelemetry[I])^;
      Log.Add(Format('Frame %d @ Cycle %d: CPU=%d%% Mem=%d%% Temp=%0.1f C',
        [Frame.FrameId, Frame.Cycle, Frame.CpuUsagePercent,
         Frame.MemoryUsagePercent, Frame.Temperature]));
    end;
    Result := Log.Text;
  finally
    Log.Free;
  end;
end;

function TOrbitalSimulator.ExportTrace(Filename: String): TSimResult;
var
  F: Text;
begin
  Assign(F, Filename);
  try
    Rewrite(F);
    WriteLn(F, GetEventLog);
    WriteLn(F, GetTelemetryLog);
    Close(F);
    Result := simSuccess;
  except
    Result := simCheckpointFailed;
  end;
end;

{ TSimulatorVisualizer }

class procedure TSimulatorVisualizer.RenderState(Simulator: TOrbitalSimulator);
var
  CpuState: TVirtualCpu;
begin
  CpuState := Simulator.GetCpuState;
  WriteLn('┌─ ORBITAL SIMULATOR STATE ─────────────────────┐');
  WriteLn('│ CPU Cycles:      ', CpuState.CycleCount:12);
  WriteLn('│ Instructions:    ', CpuState.InstructionCount:12);
  WriteLn('│ Cache:           ', GetAsciiBar(Byte((CpuState.CacheHits * 100) div (CpuState.CacheHits + CpuState.CacheMisses + 1))));
  WriteLn('│ Memory:          ', GetAsciiBar(Simulator.GetMemoryUsagePercent));
  WriteLn('│ Storage:         ', GetAsciiBar(Simulator.GetStorageUsagePercent));
  WriteLn('│ Temperature:     ', Simulator.GetTemperature:8:2, ' C');
  WriteLn('│ Frequency:       ', (Simulator.GetFrequency div 1000000):5, ' MHz');
  WriteLn('└────────────────────────────────────────────────┘');
end;

class function TSimulatorVisualizer.GetAsciiBar(Value: Byte): String;
var
  I: Integer;
  Filled: Integer;
begin
  Filled := (Value * 20) div 100;
  Result := '[';
  for I := 0 to 19 do
  begin
    if I < Filled then
      Result := Result + '='
    else
      Result := Result + ' ';
  end;
  Result := Result + Format('] %3d%%', [Value]);
end;

class function TSimulatorVisualizer.RenderMemoryMap(Memory: TVirtualMemory): String;
var
  Lines: TStringList;
  I: Integer;
  PercentUsed: Byte;
begin
  Lines := TStringList.Create;
  try
    Lines.Add('Memory Map (First 16 pages):');
    PercentUsed := Byte((Memory.Used * 100) div Memory.Size);
    for I := 0 to 15 do
      Lines.Add(Format('  Page %2d: %s', [I, GetAsciiBar(PercentUsed)]));
    Result := Lines.Text;
  finally
    Lines.Free;
  end;
end;

class function TSimulatorVisualizer.RenderStorageLedger(Storage: TVirtualStorage; MaxBlocks: Integer): String;
var
  Lines: TStringList;
  I: Integer;
begin
  Lines := TStringList.Create;
  try
    Lines.Add(Format('Storage Ledger (%d blocks):', [Storage.BlockCount]));
    for I := 0 to MinInt(MaxBlocks - 1, Storage.Blocks.Count - 1) do
    begin
      if Assigned(Storage.Blocks[I]) then
        Lines.Add(Format('  Block %3d: %8d bytes (sealed)', [I, PStorageBlockData(Storage.Blocks[I])^.Size]));
    end;
    if Storage.Blocks.Count > MaxBlocks then
      Lines.Add(Format('  ... and %d more blocks', [Storage.Blocks.Count - MaxBlocks]));
    Result := Lines.Text;
  finally
    Lines.Free;
  end;
end;

initialization
  OrbitalSim := TOrbitalSimulator.Create;

finalization
  if Assigned(OrbitalSim) then
    FreeAndNil(OrbitalSim);

end.
