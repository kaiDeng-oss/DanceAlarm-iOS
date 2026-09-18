@echo off
chcp 65001 >nul
setlocal

set "HOSTS=%SystemRoot%\System32\drivers\etc\hosts"
set "BAK=%SystemRoot%\System32\drivers\etc\hosts.dancealarm.bak"

echo ============================================================
echo   GitHub Network Fix
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

echo [1/5] Backing up hosts file...
if not exist "%BAK%" copy /Y "%HOSTS%" "%BAK%" >nul
echo       Backup saved: %BAK%

echo [2/5] Checking existing entries...
findstr /C:"# dancealarm-github-fix" "%HOSTS%" >nul 2>&1
if %errorlevel% equ 0 (
    echo       Old entries found. Removing them first...
    findstr /V /C:"# dancealarm-github-fix" /C:"140.82.112.3    github.com" /C:"140.82.112.5    api.github.com" /C:"140.82.112.5    codeload.github.com" /C:"185.199.109.133 raw.githubusercontent.com" /C:"185.199.109.133 objects.githubusercontent.com" /C:"185.199.109.133 gist.githubusercontent.com" /C:"185.199.109.133 avatars.githubusercontent.com" "%HOSTS%" > "%TEMP%\hosts.new"
    copy /Y "%TEMP%\hosts.new" "%HOSTS%" >nul
    del "%TEMP%\hosts.new" >nul 2>&1
)

echo [3/5] Writing IP mappings...
echo. >> "%HOSTS%"
echo # dancealarm-github-fix begin >> "%HOSTS%"
echo 140.82.112.3    github.com >> "%HOSTS%"
echo 140.82.112.5    api.github.com >> "%HOSTS%"
echo 140.82.112.5    codeload.github.com >> "%HOSTS%"
echo 185.199.109.133 raw.githubusercontent.com >> "%HOSTS%"
echo 185.199.109.133 objects.githubusercontent.com >> "%HOSTS%"
echo 185.199.109.133 gist.githubusercontent.com >> "%HOSTS%"
echo 185.199.109.133 avatars.githubusercontent.com >> "%HOSTS%"
echo # dancealarm-github-fix end >> "%HOSTS%"

echo [4/5] Flushing DNS cache...
ipconfig /flushdns >nul

echo [5/5] Verifying...
echo.
ping -n 1 -w 2000 github.com | findstr /C:"140.82.112.3" >nul
if %errorlevel% equ 0 (
    echo       [OK] github.com now resolves to 140.82.112.3
) else (
    echo       [WARN] DNS still resolving elsewhere. Try again in a moment.
)

echo.
echo ============================================================
echo   Done! Open https://github.com in your browser to verify.
echo   To undo: run restore_github_hosts.bat as administrator.
echo ============================================================
echo.
pause
