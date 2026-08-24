@echo off
REM Double-clique ce fichier pour lancer la veille immobiliere.
cd /d "%~dp0.."
if not exist node_modules (
  echo Premiere utilisation : installation des dependances...
  call npm install || goto :erreur
  call npx playwright install chromium
)
node src\cli.js run %*
if errorlevel 1 goto :erreur
exit /b 0

:erreur
echo.
echo L'agent s'est arrete sur une erreur. La fenetre reste ouverte.
pause
exit /b 1
