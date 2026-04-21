@echo off
setlocal enableextensions

:menu
cls
echo Select an option:
echo.
echo   1. Get-ExecutionPolicy          (current effective policy)
echo   2. Get-ExecutionPolicy -List    (policy for every scope)
echo   3. Set-ExecutionPolicy Restricted      (default; no scripts run)
echo   4. Set-ExecutionPolicy AllSigned       (only signed by trusted publishers)
echo   5. Set-ExecutionPolicy RemoteSigned    (local OK; downloaded must be signed)
echo   6. Set-ExecutionPolicy Unrestricted    (any script; prompt on downloaded)
echo   7. Set-ExecutionPolicy Bypass          (no restrictions, no prompts)
echo   8. Set-ExecutionPolicy Undefined       (remove policy from scope)
echo   9. Exit
echo.

set "choice="
set /p "choice=Enter your choice (1-9): "
if not defined choice goto invalid

if "%choice%"=="1" (powershell -NoProfile -Command "Get-ExecutionPolicy" & pause & goto menu)
if "%choice%"=="2" (powershell -NoProfile -Command "Get-ExecutionPolicy -List" & pause & goto menu)
if "%choice%"=="3" (call :set_policy Restricted   & goto menu)
if "%choice%"=="4" (call :set_policy AllSigned    & goto menu)
if "%choice%"=="5" (call :set_policy RemoteSigned & goto menu)
if "%choice%"=="6" (call :set_policy Unrestricted & goto menu)
if "%choice%"=="7" (call :set_policy Bypass       & goto menu)
if "%choice%"=="8" (call :set_policy Undefined    & goto menu)
if "%choice%"=="9" goto :eof

:invalid
echo Invalid choice. Please enter 1-9.
pause
goto menu

:set_policy
setlocal
set "policy=%~1"
powershell -NoProfile -ExecutionPolicy Bypass -Command "Set-ExecutionPolicy %policy% -Scope Process     -Force"
powershell -NoProfile -ExecutionPolicy Bypass -Command "Set-ExecutionPolicy %policy% -Scope CurrentUser -Force"
powershell -NoProfile -ExecutionPolicy Bypass -Command "Set-ExecutionPolicy %policy% -Scope LocalMachine -Force"
echo Applied %policy% to Process, CurrentUser, and LocalMachine scopes.
pause
endlocal
goto :eof
