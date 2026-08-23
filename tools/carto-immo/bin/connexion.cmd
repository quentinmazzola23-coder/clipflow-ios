@echo off
REM A lancer une seule fois : ouvre le navigateur pour se connecter
REM a lacquereur.fr et a leboncoin. La session est ensuite reutilisee.
cd /d "%~dp0.."
if not exist node_modules (
  call npm install || goto :erreur
  call npx playwright install chromium
)
node src\cli.js login
pause
exit /b 0

:erreur
pause
exit /b 1
