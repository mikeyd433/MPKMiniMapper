@echo off
:: ============================================================
:: MPKMiniMapper Installer
:: Copies MPKMiniMapper.lua to the REAPER Scripts folder.
:: Run this file once after downloading or updating the script.
:: ============================================================

set "DEST=%APPDATA%\REAPER\Scripts"

echo MPKMiniMapper Installer
echo =======================

:: Verify the destination exists
if not exist "%DEST%" (
    echo.
    echo ERROR: REAPER Scripts folder not found at:
    echo   %DEST%
    echo.
    echo Please make sure REAPER is installed and has been run at least once.
    pause
    exit /b 1
)

:: Copy the script
echo Copying MPKMiniMapper.lua to:
echo   %DEST%\
echo.

copy /Y "Scripts\MPKMiniMapper.lua" "%DEST%\MPKMiniMapper.lua"

if errorlevel 1 (
    echo.
    echo ERROR: Copy failed. Make sure you are running this file
    echo from the MPKMiniMapper folder and that REAPER is not
    echo currently loading scripts.
    pause
    exit /b 1
)

echo.
echo Done!
echo.
echo Next steps in REAPER:
echo   1. Open Actions ^> Show Action List
echo   2. Click "New Action" ^> "Load ReaScript..."
echo   3. Select MPKMiniMapper.lua from your Scripts folder
echo   4. Right-click a toolbar ^> Customize toolbar...
echo   5. Add "Script: MPKMiniMapper.lua" to the toolbar
echo.
pause
