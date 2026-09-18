@echo off
chcp 65001 >nul
setlocal

set "HOSTS=%SystemRoot%\System32\drivers\etc\hosts"
set "BAK=%SystemRoot%\System32\drivers\etc\hosts.dancealarm.bak"

echo ============================================================
echo   Restore Original hosts File
echo ============================================================
echo.

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo [ERROR] Administrator privileges required.
    echo         Right-click this file and choose "Run as administrator".
    echo.
    pause
    exit /b 1
)

echo [1/3] Removing dancealarm entries...
findstr /V /C:"# dancealarm-github-fix" /C:"140.82.112.3    github.com" /C:"140.82.112.5    api.github.com" /C:"140.82.112.5    codeload.github.com" /C:"185.199.109.133 raw.githubusercontent.com" /C:"185.199.109.133 objects.githubusercontent.com" /C:"185.199.109.133 gist.githubusercontent.com" /C:"185.199.109.133 avatars.githubusercontent.com" "%HOSTS%" > "%TEMP%\hosts.clean"
copy /Y "%TEMP%\hosts.clean" "%HOSTS%" >nul
del "%TEMP%\hosts.clean" >nul 2>&1

echo [2/3] Flushing DNS cache...
ipconfig /flushdns >nul

echo [3/3] Restoring from backup if available...
if exist "%BAK%" (
    echo       Backup found. Restoring: %BAK%
    copy /Y "%BAK%" "%HOSTS%" >nul
    echo       [OK] Original hosts file restored.
) else (
    echo       [OK] Entries removed. No backup file needed.
)

echo.
echo ============================================================
echo   GitHub IP mappings removed. DNS back to normal.
echo ============================================================
echo.
pause
