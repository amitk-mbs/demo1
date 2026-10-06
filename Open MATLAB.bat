@echo off
setlocal

echo ==================================================================
echo   Starting MATLAB Developer Environment
echo ==================================================================

REM 1. Identify Repository Root Directory
set "REPO_ROOT=%~dp0"
if "%REPO_ROOT:~-1%"=="\" set "REPO_ROOT=%REPO_ROOT:~0,-1%"

echo [INFO] Repository Directory: %REPO_ROOT%

REM 2. Determine Working Directory (prefer 'development' if it exists, else root)
if exist "%REPO_ROOT%\development\" (
    set "START_DIR=%REPO_ROOT%\development"
) else (
    set "START_DIR=%REPO_ROOT%"
)
echo [INFO] Working Directory   : %START_DIR%

REM 3. Locate MATLAB Executable
set "MATLAB_EXE="

REM Priority 1: Check Windows Registry (100% reliable for any drive / custom install)
for /f "tokens=2,*" %%A in ('reg query "HKLM\SOFTWARE\MathWorks\MATLAB" /s /v MATLABROOT 2^>nul ^| findstr /i "MATLABROOT"') do (
    if exist "%%B\bin\matlab.exe" (
        set "MATLAB_EXE=%%B\bin\matlab.exe"
    )
)

REM Priority 2: Check system PATH
if not defined MATLAB_EXE (
    where matlab >nul 2>&1
    if not errorlevel 1 (
        set "MATLAB_EXE=matlab"
    )
)

REM Priority 3: Scan standard installation directories across C: and D: drives
if not defined MATLAB_EXE (
    for %%D in ("C:\Program Files\MATLAB" "D:\Program Files\MATLAB" "C:\MATLAB" "D:\MATLAB") do (
        if exist "%%~D" (
            for /d %%V in ("%%~D"\R20*) do (
                if exist "%%V\bin\matlab.exe" (
                    set "MATLAB_EXE=%%V\bin\matlab.exe"
                )
            )
        )
    )
)

REM Verify MATLAB was located
if not defined MATLAB_EXE (
    echo.
    echo [ERROR] MATLAB executable could not be located automatically.
    echo Please ensure MATLAB is installed and added to your system PATH.
    echo.
    echo You can also start MATLAB manually, then run:
    echo   cd('%START_DIR%')
    echo   run('startup.m')
    echo.
    pause
    exit /b 1
)

echo [INFO] MATLAB Executable   : %MATLAB_EXE%
echo [INFO] Launching MATLAB with auto-path setup...

REM 4. Launch MATLAB with starting directory and auto-execution of startup.m
cd /d "%START_DIR%"

start "" /d "%START_DIR%" "%MATLAB_EXE%" -sd "%START_DIR%" -nosplash -r "if exist('startup.m','file'), run('startup.m'); end"

echo [SUCCESS] MATLAB launch initiated successfully.
echo ==================================================================
ping 127.0.0.1 -n 3 >nul
exit /b 0
