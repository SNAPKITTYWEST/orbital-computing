@echo off
REM Orbital Computing Stack - Windows Build Script

setlocal enabledelayedexpansion

echo === Orbital Computing Stack Build (Windows) ===
echo.

REM Configuration
set TARGET_OS=win64
set TARGET_CPU=x86_64
set BUILD_MODE=%1
if "%BUILD_MODE%"=="" set BUILD_MODE=debug

set INSTALL_DIR=bin
set FPC_COMPILER=fpc

echo Target OS: %TARGET_OS%
echo Target CPU: %TARGET_CPU%
echo Build Mode: %BUILD_MODE%
echo.

REM Check if FPC is available
where /q %FPC_COMPILER%
if errorlevel 1 (
    echo ERROR: FPC not found in PATH
    echo Please install Free Pascal or add it to PATH
    exit /b 1
)

REM Create output directories
if not exist %INSTALL_DIR% mkdir %INSTALL_DIR%
if not exist obj\%TARGET_CPU%-%TARGET_OS% mkdir obj\%TARGET_CPU%-%TARGET_OS%

REM Compiler flags
set FPCFLAGS=-Mobjfpc -H+ -J- -Scgi -Cg

if "%BUILD_MODE%"=="release" (
    set FPCFLAGS=%FPCFLAGS% -O3 -Xs
) else (
    set FPCFLAGS=%FPCFLAGS% -g -gl
)

REM Windows-specific flags
set FPCFLAGS=%FPCFLAGS% -Twin64 -Px86_64

REM Compile
echo Compiling source files...
%FPC_COMPILER% %FPCFLAGS% ^
    -Isrc ^
    -FE%INSTALL_DIR% ^
    -FUobj\%TARGET_CPU%-%TARGET_OS% ^
    src\orbital-main.pas

if errorlevel 1 (
    echo Build failed!
    exit /b 1
)

echo.
echo Build successful!
echo Output: %INSTALL_DIR%\orbital-main.exe
echo.

dir %INSTALL_DIR%\orbital-main.exe

REM Statistics
echo.
echo Code statistics:
for /f "tokens=1" %%i in ('findstr /r /c:"." src\*.pas ^| find /c /v ""') do (
    echo Total lines: %%i
)

echo.
echo Build complete!
echo Run: %INSTALL_DIR%\orbital-main.exe

