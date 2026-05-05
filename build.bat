@echo off
setlocal enabledelayedexpansion
cd /d "%~dp0"

:: Find link.exe in VS Build Tools
set "LINK_DIR="
for /f "delims=" %%F in ('dir /s /b "C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\VC\Tools\MSVC\link.exe" 2^>nul') do set "LINK_DIR=%%~dpF"
for /f "delims=" %%F in ('dir /s /b "C:\Program Files\Microsoft Visual Studio\link.exe" 2^>nul') do set "LINK_DIR=%%~dpF"

if not defined LINK_DIR (
    echo [ERROR] C++ Build Tools not installed.
    echo Run first: install_cpp.bat ^(as administrator^)
    echo.
    pause
    exit /b 1
)

echo [OK] link.exe found at: !LINK_DIR!
set "PATH=!LINK_DIR!;!PATH!"
rustup default stable-x86_64-pc-windows-msvc >nul 2>&1

echo Building...
echo.
cargo build --release -p kissmp-bridge -p kissmp-server
if errorlevel 1 ( pause & exit /b 1 )

if not exist "dist" mkdir "dist"
copy /Y "target\release\kissmp-bridge.exe" "dist\" >nul
copy /Y "target\release\kissmp-server.exe" "dist\" >nul

echo.
echo Done! Executables in dist\
pause
