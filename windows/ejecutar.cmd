@echo off
REM UTF-8: el servidor imprime acentos y palomitas.
chcp 65001 >nul
REM Konekt Sales - lanzador para la tarea programada.
REM Existe para poder mandar la salida a un archivo de log: la tarea
REM programada de Windows por si sola no redirige stdout.

cd /d "%~dp0.."

REM install-windows.ps1 deja aqui la ruta absoluta de node, porque la cuenta
REM SYSTEM no siempre trae node en su PATH.
set NODE_EXE=node
if exist "%~dp0node-ruta.txt" set /p NODE_EXE=<"%~dp0node-ruta.txt"

if not exist "logs" mkdir "logs"

echo. >> "logs\konekt-sales.log"
echo ==== Arranque: %date% %time% ==== >> "logs\konekt-sales.log"

"%NODE_EXE%" server.js >> "logs\konekt-sales.log" 2>&1
