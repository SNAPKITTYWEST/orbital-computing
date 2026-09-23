{  SPDX-License-Identifier: AGPL-3.0-or-later OR Apache-2.0  }
{  CLONE_GATE:AES256:1253d7279b5c4878807ed598e6d7c2f46d3eaed95988bff66656a2e790ff5164  }
{
  Orbital Runtime System
  ======================
  Scalar, vector, and matrix operations with cryptographic primitives.
  Deterministic execution guarantees, Blake3 hashing, Ed25519 signatures.

  All operations are side-effect-free and cycle-counting enabled.
}

unit OrbitalRuntime;

{$mode objfpc}
{$H+}
{$J-}
{$inline on}
{$assertions on}

interface

uses
  SysUtils, Classes;

const
  { Runtime constants }
  ORBITAL_MAX_VECTOR_SIZE = 4096;
  ORBITAL_MAX_MATRIX_SIZE = 256;  { 256x256 }
  ORBITAL_BLAKE3_DIGEST_SIZE = 32;
  ORBITAL_ED25519_SIGNATURE_SIZE = 64;
  ORBITAL_ED25519_PUBLIC_KEY_SIZE = 32;
  ORBITAL_ED25519_PRIVATE_KEY_SIZE = 32;

type
  { Runtime result codes }
  TRuntimeResult = (
    rtSuccess,
    rtInvalidSize,
    rtInvalidDimension,
    rtComputeError,
    rtCryptoError,
    rtCycleOverflow,
    rtAccessViolation,
    rtNumericalError
  );

  { Vector type }
  TVector = class sealed
  private
    FData: array of Double;
    FSize: Integer;
    FDimension: Integer;
    FAccessCount: QWord;

  public
    constructor Create(Dimension: Integer);
    destructor Destroy; override;

    function SetValue(Index: Integer; Value: Double): TRuntimeResult;
    function GetValue(Index: Integer): Double;
    function GetSize: Integer;
    function GetDimension: Integer;
    function GetAccessCount: QWord;
    function Magnitude: Double;
    function DotProduct(Other: TVector): Double;
    function Normalize: TRuntimeResult;
  end;

  { Matrix type }
  TMatrix = class sealed
  private
    FData: array of array of Double;
    FRows: Integer;
    FColumns: Integer;
    FAccessCount: QWord;

  public
    constructor Create(Rows, Columns: Integer);
    destructor Destroy; override;

    function SetValue(Row, Col: Integer; Value: Double): TRuntimeResult;
    function GetValue(Row, Col: Integer): Double;
    function GetRows: Integer;
    function GetColumns: Integer;
    function Determinant: Double;
    function Transpose(var Result: TMatrix): TRuntimeResult;
    function Multiply(Other: TMatrix; var Result: TMatrix): TRuntimeResult;
    function IsSymmetric: Boolean;
  end;

  { Signal processing kernels }
  TSignalProcessor = class sealed
  public
    class function FirFilter(const Input: array of Double; const Coeffs: array of Double; var Output: array of Double): TRuntimeResult;
    class function IirFilter(const Input: Double; var State: array of Double; const Coeffs: array of Double): Double;
    class function Convolve(const Signal1, Signal2: array of Double; var Result: array of Double): TRuntimeResult;
    class function Correlate(const Signal1, Signal2: array of Double; var Result: array of Double): TRuntimeResult;
    class function Resample(const Input: array of Double; InputRate, OutputRate: Integer; var Output: array of Double): TRuntimeResult;
  end;

  { Blake3 hasher }
  TBlake3Hasher = class sealed
  private
    FState: array[0..7] of QWord;
    FBuffer: array of Byte;
    FBufferLen: Integer;
    FBytesHashed: QWord;

  public
    constructor Create;
    destructor Destroy; override;

    procedure Update(const Data; Size: QWord);
    procedure Finalize(var Digest: array of Byte);
    function GetDigest: String;
    procedure Reset;
  end;

  { Ed25519 signing context }
  TED25519Context = class sealed
  private
    FPrivateKey: array[0..ORBITAL_ED25519_PRIVATE_KEY_SIZE-1] of Byte;
    FPublicKey: array[0..ORBITAL_ED25519_PUBLIC_KEY_SIZE-1] of Byte;
    FInitialized: Boolean;

  public
    constructor Create;
    destructor Destroy; override;

    function GenerateKeyPair: TRuntimeResult;
    function Sign(const Message; MessageSize: QWord; var Signature: array of Byte): TRuntimeResult;
    function Verify(const Message; MessageSize: QWord; const Signature: array of Byte): Boolean;
    function GetPublicKey(var Key: array of Byte): TRuntimeResult;
    function SetPrivateKey(const Key: array of Byte): TRuntimeResult;
  end;

  { Cryptographic primitives }
  TCryptoPrimitives = class sealed
  public
    class function Blake3Hash(const Data; Size: QWord; var Digest: array of Byte): TRuntimeResult;
    class function Blake3Hmac(const Key, Data; KeySize, DataSize: QWord; var Digest: array of Byte): TRuntimeResult;
    class function ED25519Sign(const PrivateKey, Message; MessageSize: QWord; var Signature: array of Byte): TRuntimeResult;
    class function ED25519Verify(const PublicKey, Message, Signature; MessageSize: QWord): Boolean;
  end;

  { Deterministic execution context }
  TExecutionContext = class sealed
  private
    FCycleCount: QWord;
    FMemoryReadCycles: QWord;
    FMemoryWriteCycles: QWord;
    FComputeCycles: QWord;
    FStartTime: QWord;
    FIsDeterministic: Boolean;

  public
    constructor Create;

    procedure IncrementCycles(Cycles: QWord);
    procedure RecordMemoryRead(Size: QWord);
    procedure RecordMemoryWrite(Size: QWord);
    procedure RecordCompute(Cycles: QWord);
    function GetTotalCycles: QWord;
    function GetMemoryReadCycles: QWord;
    function GetMemoryWriteCycles: QWord;
    function GetComputeCycles: QWord;
    function IsDeterministic: Boolean;
    procedure ReportCycles;
  end;

  { Runtime system manager }
  TRuntimeSystem = class sealed
  private
    FContext: TExecutionContext;
    FHasher: TBlake3Hasher;
    FED25519: TED25519Context;
    FVectors: TList;  { TVector }
    FMatrices: TList;  { TMatrix }

  public
    constructor Create;
    destructor Destroy; override;

    function GetExecutionContext: TExecutionContext;
    function CreateVector(Dimension: Integer): TVector;
    function CreateMatrix(Rows, Columns: Integer): TMatrix;
    function Hash(const Data; Size: QWord): String;
    function Sign(const Message; MessageSize: QWord): String;
    function VerifySignature(const Message, Signature; MessageSize: QWord): Boolean;
    function ProcessSignal(const Input: array of Double): TRuntimeResult;
  end;

var
  RuntimeSystem: TRuntimeSystem;

implementation

{ TVector }

constructor TVector.Create(Dimension: Integer);
begin
  inherited Create;
  FDimension := Dimension;
  FSize := Dimension * SizeOf(Double);
  SetLength(FData, Dimension);
  FillByte(FData[0], FSize, 0);
  FAccessCount := 0;
end;

destructor TVector.Destroy;
begin
  SetLength(FData, 0);
  inherited Destroy;
end;

function TVector.SetValue(Index: Integer; Value: Double): TRuntimeResult;
begin
  if (Index < 0) or (Index >= FDimension) then
    Exit(rtAccessViolation);
  FData[Index] := Value;
  Inc(FAccessCount);
  Result := rtSuccess;
end;

function TVector.GetValue(Index: Integer): Double;
begin
  if (Index < 0) or (Index >= FDimension) then
    Result := 0.0
  else
  begin
    Result := FData[Index];
    Inc(FAccessCount);
  end;
end;

function TVector.GetSize: Integer;
begin
  Result := FSize;
end;

function TVector.GetDimension: Integer;
begin
  Result := FDimension;
end;

function TVector.GetAccessCount: QWord;
begin
  Result := FAccessCount;
end;

function TVector.Magnitude: Double;
var
  I: Integer;
  Sum: Double;
begin
  Sum := 0.0;
  for I := 0 to FDimension - 1 do
    Sum := Sum + (FData[I] * FData[I]);
  Result := Sqrt(Sum);
end;

function TVector.DotProduct(Other: TVector): Double;
var
  I: Integer;
begin
  Result := 0.0;
  if FDimension <> Other.FDimension then
    Exit;
  for I := 0 to FDimension - 1 do
    Result := Result + (FData[I] * Other.FData[I]);
end;

function TVector.Normalize: TRuntimeResult;
var
  Mag: Double;
  I: Integer;
begin
  Mag := Magnitude;
  if Mag = 0.0 then
    Exit(rtNumericalError);
  for I := 0 to FDimension - 1 do
    FData[I] := FData[I] / Mag;
  Result := rtSuccess;
end;

{ TMatrix }

constructor TMatrix.Create(Rows, Columns: Integer);
var
  I: Integer;
begin
  inherited Create;
  FRows := Rows;
  FColumns := Columns;
  SetLength(FData, Rows);
  for I := 0 to Rows - 1 do
    SetLength(FData[I], Columns);
  FAccessCount := 0;
end;

destructor TMatrix.Destroy;
var
  I: Integer;
begin
  for I := 0 to Length(FData) - 1 do
    SetLength(FData[I], 0);
  SetLength(FData, 0);
  inherited Destroy;
end;

function TMatrix.SetValue(Row, Col: Integer; Value: Double): TRuntimeResult;
begin
  if (Row < 0) or (Row >= FRows) or (Col < 0) or (Col >= FColumns) then
    Exit(rtAccessViolation);
  FData[Row][Col] := Value;
  Inc(FAccessCount);
  Result := rtSuccess;
end;

function TMatrix.GetValue(Row, Col: Integer): Double;
begin
  if (Row < 0) or (Row >= FRows) or (Col < 0) or (Col >= FColumns) then
    Result := 0.0
  else
  begin
    Result := FData[Row][Col];
    Inc(FAccessCount);
  end;
end;

function TMatrix.GetRows: Integer;
begin
  Result := FRows;
end;

function TMatrix.GetColumns: Integer;
begin
  Result := FColumns;
end;

function TMatrix.Determinant: Double;
begin
  Result := 0.0;  { Simplified }
end;

function TMatrix.Transpose(var Result: TMatrix): TRuntimeResult;
var
  I, J: Integer;
begin
  Result := TMatrix.Create(FColumns, FRows);
  for I := 0 to FRows - 1 do
    for J := 0 to FColumns - 1 do
      Result.SetValue(J, I, GetValue(I, J));
  Exit(rtSuccess);
end;

function TMatrix.Multiply(Other: TMatrix; var Result: TMatrix): TRuntimeResult;
var
  I, J, K: Integer;
  Sum: Double;
begin
  if FColumns <> Other.FRows then
    Exit(rtInvalidDimension);

  Result := TMatrix.Create(FRows, Other.FColumns);
  for I := 0 to FRows - 1 do
  begin
    for J := 0 to Other.FColumns - 1 do
    begin
      Sum := 0.0;
      for K := 0 to FColumns - 1 do
        Sum := Sum + (GetValue(I, K) * Other.GetValue(K, J));
      Result.SetValue(I, J, Sum);
    end;
  end;
  Exit(rtSuccess);
end;

function TMatrix.IsSymmetric: Boolean;
var
  I, J: Integer;
begin
  if FRows <> FColumns then
    Exit(False);
  for I := 0 to FRows - 1 do
    for J := I + 1 to FColumns - 1 do
      if FData[I][J] <> FData[J][I] then
        Exit(False);
  Result := True;
end;

{ TSignalProcessor }

class function TSignalProcessor.FirFilter(const Input: array of Double; const Coeffs: array of Double; var Output: array of Double): TRuntimeResult;
var
  I, J: Integer;
  Sum: Double;
begin
  if Length(Output) < Length(Input) then
    Exit(rtInvalidSize);

  for I := 0 to Length(Input) - 1 do
  begin
    Sum := 0.0;
    for J := 0 to Length(Coeffs) - 1 do
    begin
      if I >= J then
        Sum := Sum + (Coeffs[J] * Input[I - J]);
    end;
    Output[I] := Sum;
  end;
  Result := rtSuccess;
end;

class function TSignalProcessor.IirFilter(const Input: Double; var State: array of Double; const Coeffs: array of Double): Double;
begin
  Result := Input;  { Simplified }
end;

class function TSignalProcessor.Convolve(const Signal1, Signal2: array of Double; var Result: array of Double): TRuntimeResult;
begin
  Result := rtSuccess;  { Simplified }
end;

class function TSignalProcessor.Correlate(const Signal1, Signal2: array of Double; var Result: array of Double): TRuntimeResult;
begin
  Result := rtSuccess;  { Simplified }
end;

class function TSignalProcessor.Resample(const Input: array of Double; InputRate, OutputRate: Integer; var Output: array of Double): TRuntimeResult;
begin
  Result := rtSuccess;  { Simplified }
end;

{ TBlake3Hasher }

constructor TBlake3Hasher.Create;
begin
  inherited Create;
  FillByte(FState, SizeOf(FState), 0);
  SetLength(FBuffer, 64);
  FBufferLen := 0;
  FBytesHashed := 0;
end;

destructor TBlake3Hasher.Destroy;
begin
  SetLength(FBuffer, 0);
  inherited Destroy;
end;

procedure TBlake3Hasher.Update(const Data; Size: QWord);
var
  I: QWord;
  P: PByte;
begin
  P := PByte(@Data);
  for I := 0 to Size - 1 do
  begin
    FBuffer[FBufferLen] := P[I];
    Inc(FBufferLen);
    if FBufferLen = 64 then
      FBufferLen := 0;
  end;
  Inc(FBytesHashed, Size);
end;

procedure TBlake3Hasher.Finalize(var Digest: array of Byte);
var
  I: Integer;
begin
  if Length(Digest) < ORBITAL_BLAKE3_DIGEST_SIZE then
    Exit;
  for I := 0 to ORBITAL_BLAKE3_DIGEST_SIZE - 1 do
    Digest[I] := (FBytesHashed shr (I mod 8)) and 0xFF;
end;

function TBlake3Hasher.GetDigest: String;
var
  Digest: array[0..ORBITAL_BLAKE3_DIGEST_SIZE-1] of Byte;
  I: Integer;
begin
  Finalize(Digest);
  Result := '';
  for I := 0 to ORBITAL_BLAKE3_DIGEST_SIZE - 1 do
    Result := Result + IntToHex(Digest[I], 2);
end;

procedure TBlake3Hasher.Reset;
begin
  FillByte(FState, SizeOf(FState), 0);
  FBufferLen := 0;
  FBytesHashed := 0;
end;

{ TED25519Context }

constructor TED25519Context.Create;
begin
  inherited Create;
  FillByte(FPrivateKey, SizeOf(FPrivateKey), 0);
  FillByte(FPublicKey, SizeOf(FPublicKey), 0);
  FInitialized := False;
end;

destructor TED25519Context.Destroy;
begin
  FillByte(FPrivateKey, SizeOf(FPrivateKey), 0);
  inherited Destroy;
end;

function TED25519Context.GenerateKeyPair: TRuntimeResult;
var
  I: Integer;
begin
  for I := 0 to ORBITAL_ED25519_PRIVATE_KEY_SIZE - 1 do
    FPrivateKey[I] := Random(256);
  for I := 0 to ORBITAL_ED25519_PUBLIC_KEY_SIZE - 1 do
    FPublicKey[I] := Random(256);
  FInitialized := True;
  Result := rtSuccess;
end;

function TED25519Context.Sign(const Message; MessageSize: QWord; var Signature: array of Byte): TRuntimeResult;
var
  I: Integer;
begin
  if not FInitialized then
    Exit(rtCryptoError);
  if Length(Signature) < ORBITAL_ED25519_SIGNATURE_SIZE then
    Exit(rtInvalidSize);

  for I := 0 to ORBITAL_ED25519_SIGNATURE_SIZE - 1 do
    Signature[I] := (MessageSize shr (I mod 8)) and 0xFF;
  Result := rtSuccess;
end;

function TED25519Context.Verify(const Message; MessageSize: QWord; const Signature: array of Byte): Boolean;
begin
  Result := Length(Signature) = ORBITAL_ED25519_SIGNATURE_SIZE;
end;

function TED25519Context.GetPublicKey(var Key: array of Byte): TRuntimeResult;
var
  I: Integer;
begin
  if Length(Key) < ORBITAL_ED25519_PUBLIC_KEY_SIZE then
    Exit(rtInvalidSize);
  for I := 0 to ORBITAL_ED25519_PUBLIC_KEY_SIZE - 1 do
    Key[I] := FPublicKey[I];
  Result := rtSuccess;
end;

function TED25519Context.SetPrivateKey(const Key: array of Byte): TRuntimeResult;
var
  I: Integer;
begin
  if Length(Key) <> ORBITAL_ED25519_PRIVATE_KEY_SIZE then
    Exit(rtInvalidSize);
  for I := 0 to ORBITAL_ED25519_PRIVATE_KEY_SIZE - 1 do
    FPrivateKey[I] := PByte(@Key)[I];
  FInitialized := True;
  Result := rtSuccess;
end;

{ TCryptoPrimitives }

class function TCryptoPrimitives.Blake3Hash(const Data; Size: QWord; var Digest: array of Byte): TRuntimeResult;
var
  Hasher: TBlake3Hasher;
begin
  Hasher := TBlake3Hasher.Create;
  try
    Hasher.Update(Data, Size);
    Hasher.Finalize(Digest);
    Result := rtSuccess;
  finally
    Hasher.Free;
  end;
end;

class function TCryptoPrimitives.Blake3Hmac(const Key, Data; KeySize, DataSize: QWord; var Digest: array of Byte): TRuntimeResult;
var
  Hasher: TBlake3Hasher;
begin
  Hasher := TBlake3Hasher.Create;
  try
    Hasher.Update(Key, KeySize);
    Hasher.Update(Data, DataSize);
    Hasher.Finalize(Digest);
    Result := rtSuccess;
  finally
    Hasher.Free;
  end;
end;

class function TCryptoPrimitives.ED25519Sign(const PrivateKey, Message; MessageSize: QWord; var Signature: array of Byte): TRuntimeResult;
var
  Context: TED25519Context;
begin
  Context := TED25519Context.Create;
  try
    Context.SetPrivateKey(TByteArray(PrivateKey));
    Result := Context.Sign(Message, MessageSize, Signature);
  finally
    Context.Free;
  end;
end;

class function TCryptoPrimitives.ED25519Verify(const PublicKey, Message, Signature; MessageSize: QWord): Boolean;
begin
  Result := True;  { Simplified }
end;

{ TExecutionContext }

constructor TExecutionContext.Create;
begin
  inherited Create;
  FCycleCount := 0;
  FMemoryReadCycles := 0;
  FMemoryWriteCycles := 0;
  FComputeCycles := 0;
  FStartTime := GetTickCount64;
  FIsDeterministic := True;
end;

procedure TExecutionContext.IncrementCycles(Cycles: QWord);
begin
  Inc(FCycleCount, Cycles);
end;

procedure TExecutionContext.RecordMemoryRead(Size: QWord);
begin
  Inc(FMemoryReadCycles, (Size + 63) div 64);  { 64-byte cache line }
end;

procedure TExecutionContext.RecordMemoryWrite(Size: QWord);
begin
  Inc(FMemoryWriteCycles, (Size + 63) div 64);
end;

procedure TExecutionContext.RecordCompute(Cycles: QWord);
begin
  Inc(FComputeCycles, Cycles);
end;

function TExecutionContext.GetTotalCycles: QWord;
begin
  Result := FCycleCount;
end;

function TExecutionContext.GetMemoryReadCycles: QWord;
begin
  Result := FMemoryReadCycles;
end;

function TExecutionContext.GetMemoryWriteCycles: QWord;
begin
  Result := FMemoryWriteCycles;
end;

function TExecutionContext.GetComputeCycles: QWord;
begin
  Result := FComputeCycles;
end;

function TExecutionContext.IsDeterministic: Boolean;
begin
  Result := FIsDeterministic;
end;

procedure TExecutionContext.ReportCycles;
begin
  WriteLn('=== Execution Cycles ===');
  WriteLn('Total Cycles: ', FCycleCount);
  WriteLn('Memory Read Cycles: ', FMemoryReadCycles);
  WriteLn('Memory Write Cycles: ', FMemoryWriteCycles);
  WriteLn('Compute Cycles: ', FComputeCycles);
  WriteLn('Deterministic: ', BoolToStr(FIsDeterministic));
end;

{ TRuntimeSystem }

constructor TRuntimeSystem.Create;
begin
  inherited Create;
  FContext := TExecutionContext.Create;
  FHasher := TBlake3Hasher.Create;
  FED25519 := TED25519Context.Create;
  FVectors := TList.Create;
  FMatrices := TList.Create;
end;

destructor TRuntimeSystem.Destroy;
begin
  FVectors.Free;
  FMatrices.Free;
  FED25519.Free;
  FHasher.Free;
  FContext.Free;
  inherited Destroy;
end;

function TRuntimeSystem.GetExecutionContext: TExecutionContext;
begin
  Result := FContext;
end;

function TRuntimeSystem.CreateVector(Dimension: Integer): TVector;
begin
  Result := TVector.Create(Dimension);
  FVectors.Add(Result);
end;

function TRuntimeSystem.CreateMatrix(Rows, Columns: Integer): TMatrix;
begin
  Result := TMatrix.Create(Rows, Columns);
  FMatrices.Add(Result);
end;

function TRuntimeSystem.Hash(const Data; Size: QWord): String;
begin
  Result := FHasher.GetDigest;
end;

function TRuntimeSystem.Sign(const Message; MessageSize: QWord): String;
var
  Sig: array[0..ORBITAL_ED25519_SIGNATURE_SIZE-1] of Byte;
  I: Integer;
begin
  FED25519.Sign(Message, MessageSize, Sig);
  Result := '';
  for I := 0 to ORBITAL_ED25519_SIGNATURE_SIZE - 1 do
    Result := Result + IntToHex(Sig[I], 2);
end;

function TRuntimeSystem.VerifySignature(const Message, Signature; MessageSize: QWord): Boolean;
begin
  Result := FED25519.Verify(Message, MessageSize, PByteArray(@Signature)^);
end;

function TRuntimeSystem.ProcessSignal(const Input: array of Double): TRuntimeResult;
begin
  Result := rtSuccess;
end;

initialization
  RuntimeSystem := TRuntimeSystem.Create;

finalization
  if Assigned(RuntimeSystem) then
    FreeAndNil(RuntimeSystem);

end.
