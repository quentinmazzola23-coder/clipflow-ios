<#
.SYNOPSIS
  Programme la veille immobiliere tous les matins via le Planificateur de taches.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\planifier-windows.ps1
  powershell -ExecutionPolicy Bypass -File scripts\planifier-windows.ps1 -Heure 06:45
  powershell -ExecutionPolicy Bypass -File scripts\planifier-windows.ps1 -Supprimer
#>
param(
  [string]$Heure = '07:30',
  [string]$NomTache = 'Carto-immo - veille quotidienne',
  # La voie `annonces` ne demande pas de session ouverte : c'est celle qu'on
  # programme par defaut. -Commande run bascule sur la voie leboncoin.
  [ValidateSet('annonces','run')][string]$Commande = 'annonces',
  [string]$Zone = 'Marciac',
  [switch]$Supprimer
)

$ErrorActionPreference = 'Stop'
$racine = Split-Path -Parent $PSScriptRoot

if ($Supprimer) {
  if (Get-ScheduledTask -TaskName $NomTache -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $NomTache -Confirm:$false
    Write-Host "Tache supprimee : $NomTache"
  } else {
    Write-Host "Aucune tache nommee '$NomTache'."
  }
  return
}

$node = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $node) { throw "Node.js est introuvable. Installe-le depuis https://nodejs.org puis relance." }

$arguments = if ($Commande -eq 'annonces') {
  "src\cli.js annonces --zone $Zone --quiet"
} else {
  'src\cli.js run --quiet'
}
$action = New-ScheduledTaskAction -Execute $node -Argument $arguments -WorkingDirectory $racine

$declencheur = New-ScheduledTaskTrigger -Daily -At $Heure

# La voie leboncoin a besoin d'une session ouverte : son navigateur utilise le
# profil connecte. La voie annonces, elle, n'a besoin de rien.
$parametres = New-ScheduledTaskSettingsSet `
  -StartWhenAvailable `
  -DontStopIfGoingOnBatteries `
  -AllowStartIfOnBatteries `
  -ExecutionTimeLimit (New-TimeSpan -Hours 2)

$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName $NomTache -Action $action -Trigger $declencheur `
  -Settings $parametres -Principal $principal -Force `
  -Description 'Collecte leboncoin, analyse lacquereur.fr, tableur et carte interactive.' | Out-Null

Write-Host "Tache creee : '$NomTache', tous les jours a $Heure."
Write-Host "Dossier      : $racine"
Write-Host "Desinstaller : powershell -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Supprimer"
