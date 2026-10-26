@echo off
rem Start the maintenance installer with elevation; first install only.
rem Usage: Start-Install.cmd [config-file]
setlocal DisableDelayedExpansion
set "MAINT_STARTER=%~f0"
set "MAINT_DIR=%~dp0"
pushd "%MAINT_DIR%"
if errorlevel 1 goto folderError

if not "%~1"=="" goto argument
set "configCount=0"
for /f "delims=" %%F in ('dir /b /a-d "config\*.psd1" 2^>nul ^| findstr /i /v /e /l ".example.psd1"') do (
    set /a configCount+=1 >nul
    set "MAINT_CONFIG=%MAINT_DIR%config\%%F"
)
if "%configCount%"=="0" goto noConfig
if "%configCount%"=="1" goto validate
echo Multiple site configs found:
for /f "delims=" %%F in ('dir /b /a-d "config\*.psd1" 2^>nul ^| findstr /i /v /e /l ".example.psd1"') do echo   "%%F"
set "configName="
set /p "configName=Type the file name from config\: "
if not defined configName goto invalidConfig
set "MAINT_CONFIG=%MAINT_DIR%config\%configName%"
goto validate

:argument
rem Relative arguments resolve from this starter's folder.
set "MAINT_CONFIG=%~1"

:validate
for %%I in ("%MAINT_CONFIG%") do set "MAINT_CONFIG=%%~fI"
if not exist "%MAINT_CONFIG%" goto invalidConfig
if exist "%MAINT_CONFIG%\" goto invalidConfig
if not exist "%MAINT_DIR%Install-Maintenance.ps1" goto missingInstaller
net session >nul 2>&1
if not errorlevel 1 goto install

rem Environment variables keep paths out of PowerShell source interpolation.
powershell -NoProfile -Command "$ErrorActionPreference = 'Stop'; try { Start-Process -FilePath $env:MAINT_STARTER -ArgumentList ('{0}{1}{0}' -f [char]34, $env:MAINT_CONFIG) -Verb RunAs; exit 0 } catch { Write-Host ('Elevation cancelled or failed: ' + $_.Exception.Message); exit 1 }"
if errorlevel 1 goto elevationFailed
set "result=0"
goto finish

:install
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%MAINT_DIR%Install-Maintenance.ps1" -ConfigPath "%MAINT_CONFIG%"
set "result=%errorlevel%"
if "%result%"=="0" (
    echo Exit code %result%: installed, no FAIL.
) else (
    echo Exit code %result%: read the FAIL lines above.
)
echo If a maintenance-account password was shown, copy it into the company vault.
pause
goto finish

:noConfig
echo No site config found. Create config\^<site^>-^<role^>.psd1 from config\site.example.psd1.
set "result=1"
pause
goto finish

:invalidConfig
echo Config file does not exist or is not a file: "%MAINT_CONFIG%"
set "result=1"
pause
goto finish

:missingInstaller
echo Installer not found: "%MAINT_DIR%Install-Maintenance.ps1"
set "result=1"
pause
goto finish

:elevationFailed
echo Administrator approval was declined or elevation failed. Run the starter again and approve UAC.
set "result=1"
pause
goto finish

:folderError
echo Cannot open the starter folder: "%MAINT_DIR%"
pause
endlocal
exit /b 1

:finish
popd
endlocal & exit /b %result%
