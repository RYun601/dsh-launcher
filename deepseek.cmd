@echo off
setlocal EnableDelayedExpansion
title DeepSeek Harness
cd /d "%USERPROFILE%"

set "ARGS=%*"

rem The cmd built-in help switch (slash followed by a question mark) is not a
rem plain token for echo or for: echo prints ECHO help and for drops the
rem token, so that help alias would silently fall through to the foreground
rem launch.  Fold it into --help before validation and dispatch.  The fold
rem must run only when arguments exist and must use delayed expansion: a
rem plain %-substitution against an undefined variable injects leftover
rem pattern text into ARGS and derails validation and dispatch.
if defined ARGS set "ARGS=!ARGS:/?=--help!"

rem Classify every token before dispatching.  Keep the canonical action and
rem its modifiers separate so a number cannot silently become a foreground
rem launch and --full cannot be lost on its way to the uninstaller.
set "ACTION="
set "FULL="
set "LOG_COUNT="
set "BADARG="
set "CONFLICT="
if defined ARGS (
    for %%a in (%ARGS%) do (
        if not defined BADARG if not defined CONFLICT call :classify "%%~a"
    )
)
if defined BADARG (
    echo [ERROR] Unknown argument: %BADARG%
    echo.
    call :help
    exit /b 1
)
if defined FULL (
    if /i not "%ACTION%"=="uninstall" (
        echo [ERROR] --full is only valid together with --uninstall
        echo.
        call :help
        exit /b 1
    )
)

if defined CONFLICT (
    echo [ERROR] Conflicting actions: !CONFLICT!
    echo Choose one action per invocation; see the list below.
    echo.
    call :help
    exit /b 1
)

if /i "%ACTION%"=="background" (
    call :background
    set "DSH_RC=!ERRORLEVEL!"
    exit /b !DSH_RC!
)
if /i "%ACTION%"=="stop" (
    call :stop
    set "DSH_RC=!ERRORLEVEL!"
    exit /b !DSH_RC!
)
if /i "%ACTION%"=="status" (
    call :status
    set "DSH_RC=!ERRORLEVEL!"
    exit /b !DSH_RC!
)
if /i "%ACTION%"=="logs" (
    call :logs
    set "DSH_RC=!ERRORLEVEL!"
    exit /b !DSH_RC!
)
if /i "%ACTION%"=="upgrade" (
    call :upgrade
    set "DSH_RC=!ERRORLEVEL!"
    exit /b !DSH_RC!
)
if /i "%ACTION%"=="update" (
    call :update
    set "DSH_RC=!ERRORLEVEL!"
    exit /b !DSH_RC!
)
if /i "%ACTION%"=="update-launcher" (
    call :update-launcher
    set "DSH_RC=!ERRORLEVEL!"
    exit /b !DSH_RC!
)
rem Self-overwrite-safe dispatch: --upgrade-launcher replaces this file while it
rem is still executing. The target label parses its entire invocation line
rem (child + delayed-expansion exit) before the replacement happens, and goto
rem dispatch never returns to a stale line offset in the rewritten file.
if /i "%ACTION%"=="upgrade-launcher" goto upgrade-launcher
if /i "%ACTION%"=="version" (
    call :version
    set "DSH_RC=!ERRORLEVEL!"
    exit /b !DSH_RC!
)
if /i "%ACTION%"=="uninstall" (
    call :uninstall
    set "DSH_RC=!ERRORLEVEL!"
    exit /b !DSH_RC!
)
if /i "%ACTION%"=="help" (
    call :help
    exit /b 0
)
if /i "%ACTION%"=="check" (
    call :check
    set "DSH_RC=!ERRORLEVEL!"
    exit /b !DSH_RC!
)

call :foreground
set "DSH_RC=!ERRORLEVEL!"
exit /b !DSH_RC!

:foreground
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-foreground.ps1"
set "DSH_RC=%ERRORLEVEL%"
exit /b %DSH_RC%

:background
echo Starting DeepSeek Harness (background)...
echo This command returns immediately; the browser opens when ready.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-background.ps1" -TimeoutSeconds 900
set "DSH_RC=%ERRORLEVEL%"
exit /b %DSH_RC%

:stop
echo Stopping DeepSeek Harness...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0stop-dsh.ps1"
set "DSH_RC=%ERRORLEVEL%"
exit /b %DSH_RC%

:status
if defined STATUS_JSON (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0dsh-launch-state.ps1" -Action GetStatusJson
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0dsh-launch-state.ps1" -Action GetStatus
)
set "DSH_RC=%ERRORLEVEL%"
exit /b %DSH_RC%

:logs
set "COUNT=20"
if defined LOG_COUNT set "COUNT=%LOG_COUNT%"
set "LOG_ARGS="
if defined LOG_FOLLOW set "LOG_ARGS=-Follow"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0dsh-logs.ps1" -Count %COUNT% !LOG_ARGS!
set "DSH_RC=%ERRORLEVEL%"
exit /b %DSH_RC%

:upgrade
echo Upgrading DeepSeek Harness (stop -> clear cache -> restart)...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0upgrade-dsh.ps1"
set "DSH_RC=%ERRORLEVEL%"
exit /b %DSH_RC%

:update
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0update-check.ps1"
set "DSH_RC=%ERRORLEVEL%"
exit /b %DSH_RC%

:update-launcher
rem Query only: no file is replaced, so a normal call dispatch is safe here.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0update-launcher.ps1"
set "DSH_RC=%ERRORLEVEL%"
exit /b %DSH_RC%

:upgrade-launcher
rem Self-overwrite: update-launcher.ps1 replaces this file mid-execution. The
rem whole line below (child invocation plus the delayed-expansion exit) is
rem parsed before the replacement, and `exit /b !ERRORLEVEL!` in the main
rem context ends the batch without reading the rewritten file again.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0update-launcher.ps1" -Upgrade & exit /b !ERRORLEVEL!

:version
rem R8: version lookup lives in version-info.ps1; -File quoting survives
rem install paths containing spaces, single quotes or non-ASCII characters,
rem which the old inline -Command string injection did not. Delayed expansion
rem is disabled in this block so an exclamation mark in the install path
rem survives %~dp0 expansion (the doc flagged this CMD edge case).
setlocal DisableDelayedExpansion
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0version-info.ps1"
set "DSH_RC=%ERRORLEVEL%"
endlocal & exit /b %DSH_RC%

:uninstall
echo Removing deepseek command from PATH...
if defined FULL (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1" -Full
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1"
)
set "DSH_RC=%ERRORLEVEL%"
exit /b %DSH_RC%

:help
echo Usage:
echo   deepseek                start in foreground mode (default)
echo   deepseek -b / -d        submit background startup and return immediately
echo   deepseek --status       check service state (starting/ready/unhealthy/foreign-port/failed/stopped)
echo   deepseek --status --json  same state as machine-readable JSON (exit code reflects findings)
echo   deepseek --stop         stop the service
echo   deepseek --logs [N]     show last N lines of the background log (default 20)
echo   deepseek --logs --follow [N]  follow the log and reconnect across rotation (Ctrl+C to stop)
echo   deepseek --version      show launcher and DeepSeek Harness versions
echo   deepseek --update       check for a newer DeepSeek Harness version
echo   deepseek --upgrade      stop, clear cache, restart with the latest version
echo   deepseek --update-launcher    check for a newer launcher release on GitHub
echo   deepseek --upgrade-launcher   download, verify and update this launcher install
echo   deepseek --uninstall    remove this command from PATH
echo   deepseek --uninstall --full   remove everything (PATH, install dir, logs, shortcut)
echo   deepseek --check        check environment and exit
echo   deepseek --help         show this help
echo   Only one action may be used per invocation (--full requires --uninstall).
rem call :help must return to the validation error path, so do not exit here.
rem The top-level goto help path preserves the current success errorlevel.
goto :eof

:check
rem Phase D: --check is now a real diagnosis (doctor). Its exit code reflects
rem the findings instead of a fixed success value.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0dsh-doctor.ps1"
set "DSH_RC=%ERRORLEVEL%"
exit /b %DSH_RC%

rem Subroutine: map one argument token to its canonical action name.  Sets
rem ACTION on first hit and CONFLICT when a different action token arrives.
:classify
set "CLASSIFY_TOKEN=%~1"
set "CLASSIFY_THIS="
if /i "%CLASSIFY_TOKEN%"=="--full" (
    if defined FULL set "BADARG=duplicate --full"
    set "FULL=1"
    goto :eof
)
echo(%CLASSIFY_TOKEN%| findstr /r /c:"^[0-9][0-9]*$" >nul 2>&1
if not errorlevel 1 (
    if /i not "%ACTION%"=="logs" set "BADARG=%CLASSIFY_TOKEN%"
    if defined LOG_COUNT set "BADARG=%CLASSIFY_TOKEN%"
    set "LOG_COUNT=%CLASSIFY_TOKEN%"
    goto :eof
)
echo(%CLASSIFY_TOKEN%| findstr /i /r /c:"^--background$" /c:"^-b$" /c:"^--bg$" /c:"^--daemon$" /c:"^-d$" >nul 2>&1
if not errorlevel 1 set "CLASSIFY_THIS=background"
echo(%CLASSIFY_TOKEN%| findstr /i /r /c:"^--stop$" /c:"^stop$" >nul 2>&1
if not errorlevel 1 set "CLASSIFY_THIS=stop"
echo(%CLASSIFY_TOKEN%| findstr /i /r /c:"^--status$" >nul 2>&1
if not errorlevel 1 set "CLASSIFY_THIS=status"
echo(%CLASSIFY_TOKEN%| findstr /i /r /c:"^--logs$" >nul 2>&1
if not errorlevel 1 set "CLASSIFY_THIS=logs"
echo(%CLASSIFY_TOKEN%| findstr /i /r /c:"^--follow$" >nul 2>&1
if not errorlevel 1 (
    if /i not "%ACTION%"=="logs" set "BADARG=%CLASSIFY_TOKEN%"
    if defined LOG_FOLLOW set "BADARG=%CLASSIFY_TOKEN%"
    set "LOG_FOLLOW=1"
    goto :eof
)
echo(%CLASSIFY_TOKEN%| findstr /i /r /c:"^--json$" >nul 2>&1
if not errorlevel 1 (
    if /i not "%ACTION%"=="status" set "BADARG=%CLASSIFY_TOKEN%"
    if defined STATUS_JSON set "BADARG=%CLASSIFY_TOKEN%"
    set "STATUS_JSON=1"
    goto :eof
)
echo(%CLASSIFY_TOKEN%| findstr /i /r /c:"^--upgrade$" >nul 2>&1
if not errorlevel 1 set "CLASSIFY_THIS=upgrade"
echo(%CLASSIFY_TOKEN%| findstr /i /r /c:"^--update$" /c:"^update$" >nul 2>&1
if not errorlevel 1 set "CLASSIFY_THIS=update"
echo(%CLASSIFY_TOKEN%| findstr /i /r /c:"^--update-launcher$" >nul 2>&1
if not errorlevel 1 set "CLASSIFY_THIS=update-launcher"
echo(%CLASSIFY_TOKEN%| findstr /i /r /c:"^--upgrade-launcher$" >nul 2>&1
if not errorlevel 1 set "CLASSIFY_THIS=upgrade-launcher"
echo(%CLASSIFY_TOKEN%| findstr /i /r /c:"^--version$" >nul 2>&1
if not errorlevel 1 set "CLASSIFY_THIS=version"
echo(%CLASSIFY_TOKEN%| findstr /i /r /c:"^--uninstall$" /c:"^uninstall$" >nul 2>&1
if not errorlevel 1 set "CLASSIFY_THIS=uninstall"
echo(%CLASSIFY_TOKEN%| findstr /i /r /c:"^--help$" /c:"^-h$" /c:"^/\?$" >nul 2>&1
if not errorlevel 1 set "CLASSIFY_THIS=help"
echo(%CLASSIFY_TOKEN%| findstr /i /r /c:"^--check$" >nul 2>&1
if not errorlevel 1 set "CLASSIFY_THIS=check"
if not defined CLASSIFY_THIS (
    set "BADARG=%CLASSIFY_TOKEN%"
    goto :eof
)
if not defined ACTION (
    set "ACTION=%CLASSIFY_THIS%"
    goto :eof
)
if /i not "%ACTION%"=="%CLASSIFY_THIS%" set "CONFLICT=%ACTION% and %CLASSIFY_THIS%"
goto :eof
