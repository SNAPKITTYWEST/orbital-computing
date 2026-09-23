{  SPDX-License-Identifier: AGPL-3.0-or-later OR Apache-2.0  }
{  CLONE_GATE:AES256:8af5447260f8b9c3ef4dd60b1151f569a1715e5099f5f77c4b41f98b48859f43  }
{
  Orbital Hardware Abstraction Layer
  ===================================
  Deterministic hardware interfaces for orbital computing stack.
  Supports CPU, memory, storage, timers, sensors, accelerators, watchdog,
  power, thermal, and communication subsystems.

  All interfaces use deterministic, cycle-accurate abstractions.
  No platform-specific code beyond sealed FFI boundary.
}

unit OrbitalHardware;

{$mode objfpc}
{$H+}
{$J-}  { Const strings }
{$inline on}
{$assertions on}

interface

uses
  SysUtils, Classes, SyncObjs;

const
  { Hardware constants }
  ORBITAL_MAX_CPU_FREQ = 2400000000;    { 2.4 GHz }
  ORBITAL_MIN_CPU_FREQ = 400000000;     { 400 MHz }
  ORBITAL_CPU_CACHE_LINE = 64;
  ORBITAL_MEMORY_PAGE_SIZE = 4096;
  ORBITAL_MAX_MEMORY = 2147483648;      { 2 GB }
  ORBITAL_STORAGE_BLOCK_SIZE = 512;
  ORBITAL_TIMER_RESOLUTION = 1000;      { 1 us ticks }
  ORBITAL_MAX_SENSORS = 32;
  ORBITAL_MAX_ACCELERATORS = 8;
  ORBITAL_THERMAL_ZONES = 4;
  ORBITAL_POWER_DOMAINS = 6;

type
  { Hardware result codes }
  THardwareResult = (
    hwrSuccess,
    hwrInvalidParameter,
    hwrMemoryError,
    hwrTimeoutError,
    hwrDeviceError,
    hwrNotInitialized,
    hwrAlreadyInitialized,
    hwrOverflow,
    hwrUnderflow,
    hwrCrcError
  );

  { CPU frequency scaling modes }
  TCpuScalingMode = (
    csmPerformance,
    csmBalanced,
    csmPowerSave,
    csmCustom
  );

  { Memory access patterns }
  TMemoryAccessPattern = (
    mapSequential,
    mapRandom,
    mapStride,
    mapBurst
  );

  { Storage operation types }
  TStorageOperation = (
    soRead,
    soWrite,
    soAppend,
    soVerify
  );

  { Power states }
  TPowerState = (
    psPoweredOn,
    psLowPower,
    psSleep,
    psHibernation,
    psOff
  );

  { Thermal states }
  TThermalState = (
    tsNormal,
    tsWarning,
    tsCritical,
    tsThermalShutdown
  );

  { Sensor types }
  TSensorType = (
    stTemperature,
    stVoltage,
    stCurrent,
    stPressure,
    stRadiation,
    stAcceleration,
    stMagneticField,
    stCustom
  );

  { Accelerator types }
  TAcceleratorType = (
    atCrypto,
    atSignalProcessing,
    atMatrixOps,
    atFFT,
    atCustom
  );

  { CPU operation result }
  TCpuOpResult = record
    Cycles: QWord;
    CacheHits: QWord;
    CacheMisses: QWord;
    Stalls: QWord;
    Result: THardwareResult;
  end;

  { Memory statistics }
  TMemoryStats = record
    TotalAllocated: QWord;
    TotalFreed: QWord;
    CurrentUsage: QWord;
    PeakUsage: QWord;
    Fragmentation: Double;
    AccessCount: QWord;
    Result: THardwareResult;
  end;

  { Storage block metadata }
  TStorageBlock = record
    BlockId: QWord;
    Offset: QWord;
    Size: QWord;
    Checksum: QWord;
    Timestamp: QWord;
    IsValid: Boolean;
  end;

  { Timer state }
  TTimerState = record
    CurrentTime: QWord;
    Frequency: QWord;
    IsRunning: Boolean;
    ImmutableSince: QWord;
  end;

  { Sensor reading }
  TSensorReading = record
    SensorId: Integer;
    SensorType: TSensorType;
    Value: Double;
    Unit: String[31];
    Timestamp: QWord;
    Quality: Byte;  { 0-100 }
    IsValid: Boolean;
  end;

  { Accelerator job }
  TAcceleratorJob = record
    JobId: QWord;
    AcceleratorId: Integer;
    JobType: TAcceleratorType;
    InputBuffer: Pointer;
    OutputBuffer: Pointer;
    InputSize: QWord;
    OutputSize: QWord;
    Priority: Byte;
    IsComplete: Boolean;
    Result: THardwareResult;
  end;

  { Power state info }
  TPowerInfo = record
    CurrentState: TPowerState;
    VoltageV: Double;
    CurrentMA: Double;
    PowerW: Double;
    EfficiencyPercent: Double;
    BatteryPercent: Integer;
    TimeToEmpty: Integer;  { seconds }
  end;

  { Thermal info }
  TThermalInfo = record
    ZoneId: Integer;
    TemperatureC: Double;
    TargetTempC: Double;
    ThrottleLevel: Byte;  { 0-100 }
    State: TThermalState;
    FanSpeedPercent: Byte;
    CoolingPower: Double;
  end;

  { Communication frame }
  TCommFrame = record
    FrameId: QWord;
    SourceId: Byte;
    DestinationId: Byte;
    FrameType: Byte;
    PayloadSize: Word;
    Payload: array[0..1023] of Byte;
    Checksum: QWord;
    Timestamp: QWord;
    IsValid: Boolean;
  end;

  { CPU Interface - sealed }
  ICpuInterface = interface
    function SetFrequency(Frequency: QWord; Mode: TCpuScalingMode): THardwareResult;
    function GetFrequency: QWord;
    function GetCycleCount: QWord;
    function SetCoreMask(Mask: QWord): THardwareResult;
    function GetCoreCount: Integer;
    function ExecuteAtomic(const Operation: String): TCpuOpResult;
    function ResetStatistics: THardwareResult;
  end;

  { Memory Interface - sealed }
  IMemoryInterface = interface
    function AllocateBounded(Size: QWord; Flags: Byte): Pointer;
    function DeallocateBounded(Ptr: Pointer): THardwareResult;
    function ReadBounded(Source: Pointer; var Dest; Size: QWord): THardwareResult;
    function WriteBounded(const Source; Dest: Pointer; Size: QWord): THardwareResult;
    function VerifyIntegrity(Ptr: Pointer; Size: QWord): Boolean;
    function GetStatistics: TMemoryStats;
    function SetAccessPattern(Pattern: TMemoryAccessPattern): THardwareResult;
  end;

  { Storage Interface - append-only }
  IStorageInterface = interface
    function Append(const Data; Size: QWord; var BlockId: QWord): THardwareResult;
    function Read(BlockId: QWord; var Data; MaxSize: QWord): THardwareResult;
    function Verify(BlockId: QWord): Boolean;
    function GetBlockInfo(BlockId: QWord): TStorageBlock;
    function GetTotalBlocks: QWord;
    function Compact: THardwareResult;
  end;

  { Timer Interface - monotonic }
  ITimerInterface = interface
    procedure Start;
    procedure Stop;
    function GetElapsedUs: QWord;
    function GetElapsedMs: QWord;
    function GetElapsedSeconds: QWord;
    function GetState: TTimerState;
    procedure SealTime;
    function IsTimeSealed: Boolean;
  end;

  { Sensor Interface - frame-based }
  ISensorInterface = interface
    function RegisterSensor(SensorType: TSensorType; var SensorId: Integer): THardwareResult;
    function ReadSensor(SensorId: Integer): TSensorReading;
    function ReadFrame(var Sensors: array of TSensorReading): Integer;
    function StartFrameCapture(IntervalUs: QWord): THardwareResult;
    function StopFrameCapture: THardwareResult;
    function GetFrameCount: QWord;
  end;

  { Accelerator Interface - optional }
  IAcceleratorInterface = interface
    function RegisterAccelerator(AccType: TAcceleratorType; var AccId: Integer): THardwareResult;
    function SubmitJob(Job: TAcceleratorJob; var JobId: QWord): THardwareResult;
    function PollJob(JobId: QWord): TAcceleratorJob;
    function WaitForJob(JobId: QWord; TimeoutUs: QWord): THardwareResult;
    function CancelJob(JobId: QWord): THardwareResult;
    function GetAcceleratorCount: Integer;
  end;

  { Watchdog Interface }
  IWatchdogInterface = interface
    function Enable(TimeoutMs: QWord): THardwareResult;
    function Disable: THardwareResult;
    function Kick: THardwareResult;
    function IsRunning: Boolean;
    function GetTimeRemaining: QWord;
  end;

  { Power State Interface }
  IPowerInterface = interface
    function GetPowerInfo: TPowerInfo;
    function SetPowerState(NewState: TPowerState): THardwareResult;
    function GetPowerState: TPowerState;
    function GetPowerHistory(var History: array of TPowerInfo): Integer;
    function RequestPerformanceMode: THardwareResult;
    function RequestLowPowerMode: THardwareResult;
  end;

  { Thermal State Interface }
  IThermalInterface = interface
    function GetThermalInfo(ZoneId: Integer): TThermalInfo;
    function GetThermalHistory(ZoneId: Integer; var History: array of TThermalInfo): Integer;
    function SetThrottleLevel(ZoneId: Integer; Level: Byte): THardwareResult;
    function GetCriticalTemp: Double;
    function GetThrottleTemp: Double;
    function EnableThermalShutdown(TempC: Double): THardwareResult;
  end;

  { Communication Interface }
  ICommInterface = interface
    function SendFrame(const Frame: TCommFrame): THardwareResult;
    function ReceiveFrame(var Frame: TCommFrame; TimeoutUs: QWord): THardwareResult;
    function GetFrameQueue: Integer;
    function ClearFrameQueue: THardwareResult;
    function SetCommMode(Mode: Byte): THardwareResult;
    function GetSignalStrength: Integer;  { -100..0 dBm }
  end;

  { Hardware Manager - coordinates all subsystems }
  THardwareManager = class sealed
  private
    FCpuInterface: ICpuInterface;
    FMemoryInterface: IMemoryInterface;
    FStorageInterface: IStorageInterface;
    FTimerInterface: ITimerInterface;
    FSensorInterface: ISensorInterface;
    FAcceleratorInterface: IAcceleratorInterface;
    FWatchdogInterface: IWatchdogInterface;
    FPowerInterface: IPowerInterface;
    FThermalInterface: IThermalInterface;
    FCommInterface: ICommInterface;
    FLock: TCriticalSection;
    FInitialized: Boolean;

  public
    constructor Create;
    destructor Destroy; override;

    function Initialize: THardwareResult;
    function Finalize: THardwareResult;
    function IsInitialized: Boolean;

    function GetCpuInterface: ICpuInterface;
    function GetMemoryInterface: IMemoryInterface;
    function GetStorageInterface: IStorageInterface;
    function GetTimerInterface: ITimerInterface;
    function GetSensorInterface: ISensorInterface;
    function GetAcceleratorInterface: IAcceleratorInterface;
    function GetWatchdogInterface: IWatchdogInterface;
    function GetPowerInterface: IPowerInterface;
    function GetThermalInterface: IThermalInterface;
    function GetCommInterface: ICommInterface;

    function DiagnosticsReport: String;
  end;

var
  HardwareManager: THardwareManager;

implementation

{ THardwareManager }

constructor THardwareManager.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FInitialized := False;
end;

destructor THardwareManager.Destroy;
begin
  if FInitialized then
    Finalize;
  FLock.Free;
  inherited Destroy;
end;

function THardwareManager.Initialize: THardwareResult;
begin
  FLock.Acquire;
  try
    if FInitialized then
      Exit(hwrAlreadyInitialized);

    { Initialize all subsystems }
    { Implementation deferred to simulator }

    FInitialized := True;
    Result := hwrSuccess;
  finally
    FLock.Release;
  end;
end;

function THardwareManager.Finalize: THardwareResult;
begin
  FLock.Acquire;
  try
    if not FInitialized then
      Exit(hwrNotInitialized);

    { Shutdown all subsystems }
    FInitialized := False;
    Result := hwrSuccess;
  finally
    FLock.Release;
  end;
end;

function THardwareManager.IsInitialized: Boolean;
begin
  FLock.Acquire;
  try
    Result := FInitialized;
  finally
    FLock.Release;
  end;
end;

function THardwareManager.GetCpuInterface: ICpuInterface;
begin
  Result := FCpuInterface;
end;

function THardwareManager.GetMemoryInterface: IMemoryInterface;
begin
  Result := FMemoryInterface;
end;

function THardwareManager.GetStorageInterface: IStorageInterface;
begin
  Result := FStorageInterface;
end;

function THardwareManager.GetTimerInterface: ITimerInterface;
begin
  Result := FTimerInterface;
end;

function THardwareManager.GetSensorInterface: ISensorInterface;
begin
  Result := FSensorInterface;
end;

function THardwareManager.GetAcceleratorInterface: IAcceleratorInterface;
begin
  Result := FAcceleratorInterface;
end;

function THardwareManager.GetWatchdogInterface: IWatchdogInterface;
begin
  Result := FWatchdogInterface;
end;

function THardwareManager.GetPowerInterface: IPowerInterface;
begin
  Result := FPowerInterface;
end;

function THardwareManager.GetThermalInterface: IThermalInterface;
begin
  Result := FThermalInterface;
end;

function THardwareManager.GetCommInterface: ICommInterface;
begin
  Result := FCommInterface;
end;

function THardwareManager.DiagnosticsReport: String;
var
  Report: TStringList;
begin
  Report := TStringList.Create;
  try
    Report.Add('=== Orbital Hardware Diagnostics ===');
    Report.Add(Format('Initialized: %s', [BoolToStr(FInitialized)]));
    Report.Add(Format('Max Memory: %d bytes', [ORBITAL_MAX_MEMORY]));
    Report.Add(Format('CPU Frequency Range: %d - %d Hz',
      [ORBITAL_MIN_CPU_FREQ, ORBITAL_MAX_CPU_FREQ]));
    Report.Add(Format('Memory Page Size: %d bytes', [ORBITAL_MEMORY_PAGE_SIZE]));
    Report.Add(Format('Storage Block Size: %d bytes', [ORBITAL_STORAGE_BLOCK_SIZE]));
    Report.Add(Format('Timer Resolution: %d us', [ORBITAL_TIMER_RESOLUTION]));
    Report.Add(Format('Max Sensors: %d', [ORBITAL_MAX_SENSORS]));
    Report.Add(Format('Max Accelerators: %d', [ORBITAL_MAX_ACCELERATORS]));
    Report.Add(Format('Thermal Zones: %d', [ORBITAL_THERMAL_ZONES]));
    Report.Add(Format('Power Domains: %d', [ORBITAL_POWER_DOMAINS]));

    Result := Report.Text;
  finally
    Report.Free;
  end;
end;

initialization
  HardwareManager := THardwareManager.Create;

finalization
  if Assigned(HardwareManager) then
    FreeAndNil(HardwareManager);

end.
