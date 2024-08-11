@echo off
:menu
cls
echo Select an option:
echo 1. Get-ExecutionPolicy
echo    # To view the current execution policy
echo 2. Get-ExecutionPolicy -List
echo    # To get a list of all execution policies for all scopes
echo 3. Set-ExecutionPolicy Restricted
echo    # To set the execution policy to Restricted (default). No scripts can run
echo 4. Set-ExecutionPolicy AllSigned
echo    # To set the execution policy to AllSigned. Only scripts signed by a trusted publisher can be run
echo 5. Set-ExecutionPolicy RemoteSigned
echo    # To set the execution policy to RemoteSigned. Scripts created locally can run, but scripts downloaded from the internet must be signed by a trusted publisher
echo 6. Set-ExecutionPolicy Unrestricted
echo    # To set the execution policy to Unrestricted. Scripts can run without being signed. You are prompted for permission before running unsigned scripts downloaded from the internet
echo 7. Set-ExecutionPolicy Bypass
echo    # To set the execution policy to Bypass. No restrictions; all scripts can run without warnings or prompts
echo 8. Set-ExecutionPolicy Undefined
echo    # To remove the currently assigned execution policy from the current scope. If all scopes are set to Undefined, the effective policy is Restricted
echo 9. Exit
set /p choice="Enter your choice (1-9): "
 
rem Switch statement
goto case_%choice%
 
:case_1
    powershell -Command "Get-ExecutionPolicy"
    pause
    goto menu
 
:case_2
    powershell -Command "Get-ExecutionPolicy -List"
    pause
    goto menu
 
:case_3
    call :set_policy Restricted
    goto menu
 
:case_4
    call :set_policy AllSigned
    goto menu
 
:case_5
    call :set_policy RemoteSigned
    goto menu
 
:case_6
    call :set_policy Unrestricted
    goto menu
 
:case_7
    call :set_policy Bypass
    goto menu
 
:case_8
    call :set_policy Undefined
    goto menu
 
:case_9
    exit
 
:invalid_choice
    echo Invalid choice. Please select a valid option (1-9).
    pause
    goto menu
 
:set_policy
    set "policy=%~1"
    powershell -ExecutionPolicy Bypass -Command "Set-ExecutionPolicy %policy% -Scope Process"
    powershell -ExecutionPolicy Bypass -Command "Set-ExecutionPolicy %policy% -Scope CurrentUser"
    powershell -ExecutionPolicy Bypass -Command "Set-ExecutionPolicy %policy% -Scope LocalMachine"
    exit /b