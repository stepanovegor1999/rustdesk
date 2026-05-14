@echo off
setlocal

for %%I in ("%~dp0..\..") do set "ROOT=%%~fI"
set "MSI=%~1"
set "LOG=%TEMP%\GuberniaDesktop-deploy.log"

if "%MSI%"=="" (
  set "MSI=%ROOT%\res\msi\Package\bin\x64\Release\ru-ru\Package.msi"
)

if not exist "%MSI%" (
  echo ERROR: MSI not found: "%MSI%"
  echo Usage: %~nx0 [path-to-msi]
  exit /b 1
)

echo Installing "%MSI%" on this Windows host.
echo Log file: "%LOG%"

msiexec /i "%MSI%" /qn /norestart /l*v "%LOG%" LAUNCH_TRAY_APP=N DESKTOPSHORTCUTS=1 STARTMENUSHORTCUTS=1 PRINTER=1
set "EXITCODE=%ERRORLEVEL%"

if not "%EXITCODE%"=="0" (
  echo.
  echo Deployment failed with exit code %EXITCODE%.
  echo Check "%LOG%" for details.
  exit /b %EXITCODE%
)

echo.
echo Deployment completed successfully.
exit /b 0
