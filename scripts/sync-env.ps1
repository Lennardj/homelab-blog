# Sync .env from local machine to runner-01 VM
# Usage: .\scripts\sync-env.ps1

$RunnerHost = "lennard@192.168.1.73"
$RunnerEnvPath = "/home/lennard/.env"

scp .env "${RunnerHost}:${RunnerEnvPath}"
Write-Host "Synced .env to runner-01"
