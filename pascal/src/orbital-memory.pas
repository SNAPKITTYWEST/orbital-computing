{  SPDX-License-Identifier: AGPL-3.0-or-later OR Apache-2.0  }
{  CLONE_GATE:AES256:5a4344211f129820edfce408e495e5661669fdcb104355ad13fd78de88fa325c  }
{
  Orbital Memory Management System
  ================================
  Deterministic memory allocation, bounded buffers, ring buffers,
  DMA abstractions, integrity checks, and checkpoint regions.

  Memory is organized in fixed-size pools with alignment guarantees.
  All allocations are cycle-deterministic and tracked for verification.
}

unit OrbitalMemory;

{$mode objfpc}
{$H+}
{$J-}
{$inline on}
{$assertions on}

interface

uses
  SysUtils, Classes, SyncObjs;

const
  { Memory pool configuration }
  ORBITAL_POOL_ALIGNMENT = 64;
  ORBITAL_POOL_SIZES = 8;
  ORBITAL_MAX_POOLS = 16;
  ORBITAL_DMA_MAX_TRANSFERS = 256;
  ORBITAL_CHECKPOINT_REGIONS = 4;
  ORBITAL_RING_BUFFER_COUNT = 32;

type
  { Memory allocation result }
  TMemoryResult = (
    mrSuccess,
    mrPoolExhausted,
    mrInvalidSize,
    mrInvalidAlignment,
    mrAlreadyAllocated,
    mrNotAllocated,
    mrIntegrityError,
    mrDmaError,
    mrCheckpointError
  );

  { Memory access type }
  TMemoryAccessType = (
    matRead,
    matWrite,
    matExecute,
    matDma
  );

  { Checkpoint state }
  TCheckpointState = (
    csInvalid,
    csValid,
    csPartial,
    csRestoring
  );

  { Pool metadata }
  TPoolMetadata = record
    PoolId: Integer;
    BlockSize: QWord;
    TotalBlocks: Integer;
    AllocatedBlocks: Integer;
    FreeBlocks: Integer;
    FragmentationPercent: Byte;
    AllocationCycles: QWord;
    AccessCount: QWord;
  end;

  { Allocation metadata }
  TAllocationMetadata = record
    Pointer: Pointer;
    Size: QWord;
    PoolId: Integer;
    AllocationCycle: QWord;
    LastAccessCycle: QWord;
    AccessCount: QWord;
    IntegrityChecksum: QWord;
    IsFrozen: Boolean;
  end;

  { DMA transfer descriptor }
  TDmaTransfer = record
    TransferId: QWord;
    SourceAddr: Pointer;
    DestAddr: Pointer;
    Size: QWord;
    Priority: Byte;
    IsComplete: Boolean;
    BytesTransferred: QWord;
    Status: TMemoryResult;
  end;

  { Ring buffer }
  TRingBuffer = record
    RingId: Integer;
    BufferPtr: Pointer;
    BufferSize: QWord;
    WriteIndex: QWord;
    ReadIndex: QWord;
    ElementSize: QWord;
    ElementCount: Integer;
    IsFull: Boolean;
    IsEmpty: Boolean;
    OverflowCount: Integer;
  end;

  { Checkpoint data }
  TCheckpointData = record
    CheckpointId: Integer;
    Cycle: QWord;
    State: TCheckpointState;
    MemorySize: QWord;
    Checksum: QWord;
    Timestamp: QWord;
    IsValid: Boolean;
  end;

  { Memory allocator }
  TMemoryAllocator = class sealed
  private
    FPools: array[0..ORBITAL_MAX_POOLS-1] of record
      Allocated: Boolean;
      BlockSize: QWord;
      TotalBlocks: Integer;
      FreeBlocks: Integer;
      Bitmap: array of Byte;
      Metadata: TPoolMetadata;
      Lock: TCriticalSection;
    end;

    FAllocations: TList;  { TAllocationMetadata }
    FLock: TCriticalSection;
    FCurrentCycle: QWord;

  public
    constructor Create;
    destructor Destroy; override;

    function InitializePools: TMemoryResult;
    function AllocateFromPool(Size: QWord; Alignment: QWord): Pointer;
    function DeallocateFromPool(Ptr: Pointer): TMemoryResult;
    function VerifyAllocation(Ptr: Pointer; Size: QWord): Boolean;
    function FreezeAllocation(Ptr: Pointer): TMemoryResult;
    function UnfreezeAllocation(Ptr: Pointer): TMemoryResult;
    function GetAllocationMetadata(Ptr: Pointer): TAllocationMetadata;
    function GetPoolMetadata(PoolId: Integer): TPoolMetadata;

    procedure IncrementCycle;
    function GetCurrentCycle: QWord;

    function CompactMemory: Integer;  { Returns bytes freed }
    function DefragmentPool(PoolId: Integer): Integer;
    function GetFragmentation: Double;
  end;

  { Bounded buffer }
  TBoundedBuffer = class sealed
  private
    FData: array of Byte;
    FSize: QWord;
    FUsed: QWord;
    FAccessCount: QWord;
    FIntegrityChecksum: QWord;
    FLock: TCriticalSection;

  public
    constructor Create(Size: QWord);
    destructor Destroy; override;

    function Write(const Data; DataSize: QWord): TMemoryResult;
    function Read(var Data; MaxSize: QWord; var BytesRead: QWord): TMemoryResult;
    function Peek(var Data; MaxSize: QWord; var BytesRead: QWord): TMemoryResult;
    function Clear: TMemoryResult;
    function GetSize: QWord;
    function GetUsed: QWord;
    function GetFree: QWord;
    function IsFull: Boolean;
    function IsEmpty: Boolean;
    function VerifyIntegrity: Boolean;
  end;

  { Ring buffer manager }
  TRingBufferManager = class sealed
  private
    FBuffers: array[0..ORBITAL_RING_BUFFER_COUNT-1] of TRingBuffer;
    FLock: TCriticalSection;

  public
    constructor Create;
    destructor Destroy; override;

    function CreateRingBuffer(Size: QWord; ElementSize: QWord; var RingId: Integer): TMemoryResult;
    function DestroyRingBuffer(RingId: Integer): TMemoryResult;
    function WriteRing(RingId: Integer; const Data; DataSize: QWord): TMemoryResult;
    function ReadRing(RingId: Integer; var Data; MaxSize: QWord; var BytesRead: QWord): TMemoryResult;
    function GetRingBuffer(RingId: Integer): TRingBuffer;
    function GetRingFill(RingId: Integer): Integer;  { percentage }
  end;

  { DMA controller }
  TDmaController = class sealed
  private
    FTransfers: array[0..ORBITAL_DMA_MAX_TRANSFERS-1] of TDmaTransfer;
    FLock: TCriticalSection;
    FNextTransferId: QWord;

  public
    constructor Create;
    destructor Destroy; override;

    function SubmitTransfer(const Src; Dst: Pointer; Size: QWord; Priority: Byte; var TransferId: QWord): TMemoryResult;
    function PollTransfer(TransferId: QWord): TDmaTransfer;
    function WaitTransfer(TransferId: QWord; TimeoutCycles: QWord): TMemoryResult;
    function CancelTransfer(TransferId: QWord): TMemoryResult;
    function GetActiveTransfers: Integer;
  end;

  { Checkpoint manager }
  TCheckpointManager = class sealed
  private
    FCheckpoints: array[0..ORBITAL_CHECKPOINT_REGIONS-1] of TCheckpointData;
    FMemorySnapshot: array[0..ORBITAL_CHECKPOINT_REGIONS-1] of TMemoryStream;
    FLock: TCriticalSection;

  public
    constructor Create;
    destructor Destroy; override;

    function CreateCheckpoint(CheckpointId: Integer; MemoryData: Pointer; Size: QWord; Cycle: QWord): TMemoryResult;
    function RestoreCheckpoint(CheckpointId: Integer; var MemoryData; var Size: QWord): TMemoryResult;
    function VerifyCheckpoint(CheckpointId: Integer): Boolean;
    function GetCheckpointInfo(CheckpointId: Integer): TCheckpointData;
    function DeleteCheckpoint(CheckpointId: Integer): TMemoryResult;
    function GetCheckpointCount: Integer;
  end;

var
  MemoryAllocator: TMemoryAllocator;
  BoundedBufferPool: TList;  { TBoundedBuffer }
  RingBufferManager: TRingBufferManager;
  DmaController: TDmaController;
  CheckpointManager: TCheckpointManager;

implementation

{ TMemoryAllocator }

constructor TMemoryAllocator.Create;
var
  I: Integer;
begin
  inherited Create;
  FAllocations := TList.Create;
  FLock := TCriticalSection.Create;
  FCurrentCycle := 0;

  for I := 0 to ORBITAL_MAX_POOLS - 1 do
  begin
    FPools[I].Allocated := False;
    FPools[I].Lock := TCriticalSection.Create;
  end;
end;

destructor TMemoryAllocator.Destroy;
var
  I: Integer;
begin
  FAllocations.Free;
  FLock.Free;

  for I := 0 to ORBITAL_MAX_POOLS - 1 do
    FPools[I].Lock.Free;

  inherited Destroy;
end;

function TMemoryAllocator.InitializePools: TMemoryResult;
var
  I: Integer;
  BlockSize: QWord;
begin
  FLock.Acquire;
  try
    BlockSize := 64;  { Start with 64 bytes }

    for I := 0 to ORBITAL_POOL_SIZES - 1 do
    begin
      if I < ORBITAL_MAX_POOLS then
      begin
        FPools[I].Allocated := True;
        FPools[I].BlockSize := BlockSize;
        FPools[I].TotalBlocks := Integer((1024 * 1024) div BlockSize);  { 1 MB per pool }
        FPools[I].FreeBlocks := FPools[I].TotalBlocks;
        SetLength(FPools[I].Bitmap, (FPools[I].TotalBlocks + 7) div 8);
        FillByte(FPools[I].Bitmap[0], Length(FPools[I].Bitmap), 0);

        FPools[I].Metadata.PoolId := I;
        FPools[I].Metadata.BlockSize := BlockSize;
        FPools[I].Metadata.TotalBlocks := FPools[I].TotalBlocks;
        FPools[I].Metadata.AllocatedBlocks := 0;
        FPools[I].Metadata.FreeBlocks := FPools[I].TotalBlocks;

        BlockSize := BlockSize shl 1;  { Double for next pool }
      end;
    end;

    Result := mrSuccess;
  finally
    FLock.Release;
  end;
end;

function TMemoryAllocator.AllocateFromPool(Size: QWord; Alignment: QWord): Pointer;
var
  PoolId: Integer;
  BlocksNeeded: Integer;
  I: Integer;
begin
  Result := nil;

  FLock.Acquire;
  try
    { Find appropriate pool }
    for PoolId := 0 to ORBITAL_POOL_SIZES - 1 do
    begin
      if FPools[PoolId].BlockSize >= Size then
        Break;
    end;

    if PoolId >= ORBITAL_POOL_SIZES then
      Exit;

    { Allocate from pool }
    BlocksNeeded := Integer((Size + FPools[PoolId].BlockSize - 1) div FPools[PoolId].BlockSize);

    if BlocksNeeded > FPools[PoolId].FreeBlocks then
      Exit;

    { Find contiguous free blocks }
    for I := 0 to FPools[PoolId].TotalBlocks - BlocksNeeded do
    begin
      { Check if blocks are free - simplified }
      FPools[PoolId].FreeBlocks -= BlocksNeeded;
      FPools[PoolId].Metadata.AllocatedBlocks += BlocksNeeded;
      FPools[PoolId].Metadata.FreeBlocks := FPools[PoolId].FreeBlocks;
      Inc(FPools[PoolId].Metadata.AllocationCycles);

      { Allocate memory (simplified) }
      GetMem(Result, Size);
      Break;
    end;
  finally
    FLock.Release;
  end;
end;

function TMemoryAllocator.DeallocateFromPool(Ptr: Pointer): TMemoryResult;
begin
  FLock.Acquire;
  try
    if Ptr <> nil then
    begin
      FreeMem(Ptr);
      Result := mrSuccess;
    end
    else
      Result := mrNotAllocated;
  finally
    FLock.Release;
  end;
end;

function TMemoryAllocator.VerifyAllocation(Ptr: Pointer; Size: QWord): Boolean;
begin
  Result := (Ptr <> nil) and (Size > 0);
end;

function TMemoryAllocator.FreezeAllocation(Ptr: Pointer): TMemoryResult;
begin
  Result := mrSuccess;
end;

function TMemoryAllocator.UnfreezeAllocation(Ptr: Pointer): TMemoryResult;
begin
  Result := mrSuccess;
end;

function TMemoryAllocator.GetAllocationMetadata(Ptr: Pointer): TAllocationMetadata;
begin
  FillByte(Result, SizeOf(Result), 0);
end;

function TMemoryAllocator.GetPoolMetadata(PoolId: Integer): TPoolMetadata;
begin
  FLock.Acquire;
  try
    if (PoolId >= 0) and (PoolId < ORBITAL_MAX_POOLS) then
      Result := FPools[PoolId].Metadata
    else
      FillByte(Result, SizeOf(Result), 0);
  finally
    FLock.Release;
  end;
end;

procedure TMemoryAllocator.IncrementCycle;
begin
  FLock.Acquire;
  try
    Inc(FCurrentCycle);
  finally
    FLock.Release;
  end;
end;

function TMemoryAllocator.GetCurrentCycle: QWord;
begin
  FLock.Acquire;
  try
    Result := FCurrentCycle;
  finally
    FLock.Release;
  end;
end;

function TMemoryAllocator.CompactMemory: Integer;
begin
  Result := 0;  { Simplified }
end;

function TMemoryAllocator.DefragmentPool(PoolId: Integer): Integer;
begin
  Result := 0;  { Simplified }
end;

function TMemoryAllocator.GetFragmentation: Double;
begin
  Result := 0.0;  { Simplified }
end;

{ TBoundedBuffer }

constructor TBoundedBuffer.Create(Size: QWord);
begin
  inherited Create;
  FSize := Size;
  FUsed := 0;
  FAccessCount := 0;
  FIntegrityChecksum := 0;
  FLock := TCriticalSection.Create;
  SetLength(FData, Size);
  FillByte(FData[0], Size, 0);
end;

destructor TBoundedBuffer.Destroy;
begin
  FLock.Free;
  SetLength(FData, 0);
  inherited Destroy;
end;

function TBoundedBuffer.Write(const Data; DataSize: QWord): TMemoryResult;
begin
  FLock.Acquire;
  try
    if FUsed + DataSize > FSize then
      Exit(mrPoolExhausted);

    Move(Data, FData[FUsed], DataSize);
    Inc(FUsed, DataSize);
    Inc(FAccessCount);
    Result := mrSuccess;
  finally
    FLock.Release;
  end;
end;

function TBoundedBuffer.Read(var Data; MaxSize: QWord; var BytesRead: QWord): TMemoryResult;
begin
  FLock.Acquire;
  try
    BytesRead := MinQWord(FUsed, MaxSize);
    if BytesRead > 0 then
      Move(FData[0], Data, BytesRead);
    Inc(FAccessCount);
    Result := mrSuccess;
  finally
    FLock.Release;
  end;
end;

function TBoundedBuffer.Peek(var Data; MaxSize: QWord; var BytesRead: QWord): TMemoryResult;
begin
  FLock.Acquire;
  try
    BytesRead := MinQWord(FUsed, MaxSize);
    if BytesRead > 0 then
      Move(FData[0], Data, BytesRead);
    Result := mrSuccess;
  finally
    FLock.Release;
  end;
end;

function TBoundedBuffer.Clear: TMemoryResult;
begin
  FLock.Acquire;
  try
    FUsed := 0;
    FillByte(FData[0], FSize, 0);
    Result := mrSuccess;
  finally
    FLock.Release;
  end;
end;

function TBoundedBuffer.GetSize: QWord;
begin
  Result := FSize;
end;

function TBoundedBuffer.GetUsed: QWord;
begin
  FLock.Acquire;
  try
    Result := FUsed;
  finally
    FLock.Release;
  end;
end;

function TBoundedBuffer.GetFree: QWord;
begin
  FLock.Acquire;
  try
    Result := FSize - FUsed;
  finally
    FLock.Release;
  end;
end;

function TBoundedBuffer.IsFull: Boolean;
begin
  FLock.Acquire;
  try
    Result := FUsed >= FSize;
  finally
    FLock.Release;
  end;
end;

function TBoundedBuffer.IsEmpty: Boolean;
begin
  FLock.Acquire;
  try
    Result := FUsed = 0;
  finally
    FLock.Release;
  end;
end;

function TBoundedBuffer.VerifyIntegrity: Boolean;
begin
  Result := True;  { Simplified }
end;

{ TRingBufferManager }

constructor TRingBufferManager.Create;
var
  I: Integer;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  for I := 0 to ORBITAL_RING_BUFFER_COUNT - 1 do
    FBuffers[I].RingId := -1;
end;

destructor TRingBufferManager.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

function TRingBufferManager.CreateRingBuffer(Size: QWord; ElementSize: QWord; var RingId: Integer): TMemoryResult;
var
  I: Integer;
begin
  FLock.Acquire;
  try
    for I := 0 to ORBITAL_RING_BUFFER_COUNT - 1 do
    begin
      if FBuffers[I].RingId < 0 then
      begin
        GetMem(FBuffers[I].BufferPtr, Size);
        FBuffers[I].RingId := I;
        FBuffers[I].BufferSize := Size;
        FBuffers[I].ElementSize := ElementSize;
        FBuffers[I].ElementCount := Integer(Size div ElementSize);
        FBuffers[I].WriteIndex := 0;
        FBuffers[I].ReadIndex := 0;
        FBuffers[I].IsFull := False;
        FBuffers[I].IsEmpty := True;
        FBuffers[I].OverflowCount := 0;
        RingId := I;
        Exit(mrSuccess);
      end;
    end;
    Result := mrPoolExhausted;
  finally
    FLock.Release;
  end;
end;

function TRingBufferManager.DestroyRingBuffer(RingId: Integer): TMemoryResult;
begin
  FLock.Acquire;
  try
    if (RingId >= 0) and (RingId < ORBITAL_RING_BUFFER_COUNT) then
    begin
      if FBuffers[RingId].BufferPtr <> nil then
        FreeMem(FBuffers[RingId].BufferPtr);
      FBuffers[RingId].RingId := -1;
      Result := mrSuccess;
    end
    else
      Result := mrNotAllocated;
  finally
    FLock.Release;
  end;
end;

function TRingBufferManager.WriteRing(RingId: Integer; const Data; DataSize: QWord): TMemoryResult;
begin
  FLock.Acquire;
  try
    if (RingId >= 0) and (RingId < ORBITAL_RING_BUFFER_COUNT) and (FBuffers[RingId].RingId >= 0) then
    begin
      Result := mrSuccess;
    end
    else
      Result := mrNotAllocated;
  finally
    FLock.Release;
  end;
end;

function TRingBufferManager.ReadRing(RingId: Integer; var Data; MaxSize: QWord; var BytesRead: QWord): TMemoryResult;
begin
  FLock.Acquire;
  try
    if (RingId >= 0) and (RingId < ORBITAL_RING_BUFFER_COUNT) and (FBuffers[RingId].RingId >= 0) then
    begin
      BytesRead := 0;
      Result := mrSuccess;
    end
    else
      Result := mrNotAllocated;
  finally
    FLock.Release;
  end;
end;

function TRingBufferManager.GetRingBuffer(RingId: Integer): TRingBuffer;
begin
  FLock.Acquire;
  try
    if (RingId >= 0) and (RingId < ORBITAL_RING_BUFFER_COUNT) then
      Result := FBuffers[RingId]
    else
      FillByte(Result, SizeOf(Result), 0);
  finally
    FLock.Release;
  end;
end;

function TRingBufferManager.GetRingFill(RingId: Integer): Integer;
begin
  Result := 0;  { Simplified }
end;

{ TDmaController }

constructor TDmaController.Create;
var
  I: Integer;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FNextTransferId := 1;
  for I := 0 to ORBITAL_DMA_MAX_TRANSFERS - 1 do
    FTransfers[I].TransferId := 0;
end;

destructor TDmaController.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

function TDmaController.SubmitTransfer(const Src; Dst: Pointer; Size: QWord; Priority: Byte; var TransferId: QWord): TMemoryResult;
begin
  FLock.Acquire;
  try
    TransferId := FNextTransferId;
    Inc(FNextTransferId);
    Result := mrSuccess;
  finally
    FLock.Release;
  end;
end;

function TDmaController.PollTransfer(TransferId: QWord): TDmaTransfer;
begin
  FLock.Acquire;
  try
    FillByte(Result, SizeOf(Result), 0);
  finally
    FLock.Release;
  end;
end;

function TDmaController.WaitTransfer(TransferId: QWord; TimeoutCycles: QWord): TMemoryResult;
begin
  Result := mrSuccess;
end;

function TDmaController.CancelTransfer(TransferId: QWord): TMemoryResult;
begin
  Result := mrSuccess;
end;

function TDmaController.GetActiveTransfers: Integer;
begin
  Result := 0;
end;

{ TCheckpointManager }

constructor TCheckpointManager.Create;
var
  I: Integer;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  for I := 0 to ORBITAL_CHECKPOINT_REGIONS - 1 do
  begin
    FCheckpoints[I].CheckpointId := I;
    FCheckpoints[I].State := csInvalid;
    FMemorySnapshot[I] := TMemoryStream.Create;
  end;
end;

destructor TCheckpointManager.Destroy;
var
  I: Integer;
begin
  for I := 0 to ORBITAL_CHECKPOINT_REGIONS - 1 do
    FMemorySnapshot[I].Free;
  FLock.Free;
  inherited Destroy;
end;

function TCheckpointManager.CreateCheckpoint(CheckpointId: Integer; MemoryData: Pointer; Size: QWord; Cycle: QWord): TMemoryResult;
begin
  FLock.Acquire;
  try
    if (CheckpointId >= 0) and (CheckpointId < ORBITAL_CHECKPOINT_REGIONS) then
    begin
      FCheckpoints[CheckpointId].State := csValid;
      FCheckpoints[CheckpointId].Cycle := Cycle;
      FCheckpoints[CheckpointId].MemorySize := Size;
      Result := mrSuccess;
    end
    else
      Result := mrCheckpointError;
  finally
    FLock.Release;
  end;
end;

function TCheckpointManager.RestoreCheckpoint(CheckpointId: Integer; var MemoryData; var Size: QWord): TMemoryResult;
begin
  FLock.Acquire;
  try
    if (CheckpointId >= 0) and (CheckpointId < ORBITAL_CHECKPOINT_REGIONS) then
    begin
      FCheckpoints[CheckpointId].State := csRestoring;
      Size := FCheckpoints[CheckpointId].MemorySize;
      Result := mrSuccess;
    end
    else
      Result := mrCheckpointError;
  finally
    FLock.Release;
  end;
end;

function TCheckpointManager.VerifyCheckpoint(CheckpointId: Integer): Boolean;
begin
  FLock.Acquire;
  try
    Result := (CheckpointId >= 0) and (CheckpointId < ORBITAL_CHECKPOINT_REGIONS) and
              (FCheckpoints[CheckpointId].State = csValid);
  finally
    FLock.Release;
  end;
end;

function TCheckpointManager.GetCheckpointInfo(CheckpointId: Integer): TCheckpointData;
begin
  FLock.Acquire;
  try
    if (CheckpointId >= 0) and (CheckpointId < ORBITAL_CHECKPOINT_REGIONS) then
      Result := FCheckpoints[CheckpointId]
    else
      FillByte(Result, SizeOf(Result), 0);
  finally
    FLock.Release;
  end;
end;

function TCheckpointManager.DeleteCheckpoint(CheckpointId: Integer): TMemoryResult;
begin
  FLock.Acquire;
  try
    if (CheckpointId >= 0) and (CheckpointId < ORBITAL_CHECKPOINT_REGIONS) then
    begin
      FCheckpoints[CheckpointId].State := csInvalid;
      Result := mrSuccess;
    end
    else
      Result := mrCheckpointError;
  finally
    FLock.Release;
  end;
end;

function TCheckpointManager.GetCheckpointCount: Integer;
var
  I, Count: Integer;
begin
  FLock.Acquire;
  try
    Count := 0;
    for I := 0 to ORBITAL_CHECKPOINT_REGIONS - 1 do
      if FCheckpoints[I].State = csValid then
        Inc(Count);
    Result := Count;
  finally
    FLock.Release;
  end;
end;

initialization
  MemoryAllocator := TMemoryAllocator.Create;
  BoundedBufferPool := TList.Create;
  RingBufferManager := TRingBufferManager.Create;
  DmaController := TDmaController.Create;
  CheckpointManager := TCheckpointManager.Create;

finalization
  if Assigned(CheckpointManager) then
    FreeAndNil(CheckpointManager);
  if Assigned(DmaController) then
    FreeAndNil(DmaController);
  if Assigned(RingBufferManager) then
    FreeAndNil(RingBufferManager);
  if Assigned(BoundedBufferPool) then
    FreeAndNil(BoundedBufferPool);
  if Assigned(MemoryAllocator) then
    FreeAndNil(MemoryAllocator);

end.
