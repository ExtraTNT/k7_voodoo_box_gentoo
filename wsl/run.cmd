@echo off
rem PowerShell / cmd: run one of this repo's Linux scripts inside the WSL build
rem distro, as root.  (Git Bash: ./wsl/run.sh does the same.)
rem
rem   wsl\run build\prebuild.sh
rem   wsl\run iso\build-iso.sh
rem   wsl\run build\publish.sh
rem   wsl\run test\live-test.sh run
rem   wsl\run REBUILD=1 test\live-test.sh
rem
rem Distro: %S2466_WSL% (default s2466-build, made by wsl\setup.ps1).
setlocal
set "DISTRO=%S2466_WSL%"
if "%DISTRO%"=="" set "DISTRO=s2466-build"
for %%I in ("%~dp0..") do set "REPO=%%~fI"
rem no quotes around the distro: wsl.exe would take them literally
wsl.exe -d %DISTRO% -u root --cd "%REPO%" --exec bash wsl/inside.sh %*
exit /b %ERRORLEVEL%
