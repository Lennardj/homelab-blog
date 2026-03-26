Write-Host "=== Step 1: Terraform destroy ===" -ForegroundColor Cyan
docker compose run --rm --entrypoint /bin/sh terraform -c "cd /work/terraform/proxmox && terraform init -input=false && terraform destroy -auto-approve"
if ($LASTEXITCODE -ne 0) {
    Write-Host "WARNING: Terraform destroy failed or resources already gone - continuing teardown." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=== Step 2: Docker Compose down ===" -ForegroundColor Cyan
docker compose down --volumes --remove-orphans
Write-Host "Compose down complete."

Write-Host ""
Write-Host "=== Step 3: Docker prune ===" -ForegroundColor Cyan
docker system prune --all --force --volumes
Write-Host "Docker prune complete."

Write-Host ""
Write-Host "=== Step 4: Clean Terraform local state ===" -ForegroundColor Cyan
$tfDir = "terraform\proxmox"
$filesToDelete = @(
    "$tfDir\.terraform.lock.hcl",
    "$tfDir\terraform.tfstate",
    "$tfDir\terraform.tfstate.backup"
)
foreach ($file in $filesToDelete) {
    if (Test-Path $file) {
        Remove-Item $file -Force
        Write-Host "Deleted $file"
    }
}
if (Test-Path "$tfDir\.terraform") {
    Remove-Item "$tfDir\.terraform" -Recurse -Force
    Write-Host "Deleted $tfDir\.terraform\"
}

Write-Host ""
Write-Host "=== Step 5: Clear artifacts and inventory ===" -ForegroundColor Cyan
if (Test-Path "artifacts\output.json") {
    Clear-Content "artifacts\output.json"
    Write-Host "Cleared artifacts\output.json"
}
if (Test-Path "ansible\inventory\hosts.ini") {
    Clear-Content "ansible\inventory\hosts.ini"
    Write-Host "Cleared ansible\inventory\hosts.ini"
}

Write-Host ""
Write-Host "=== Teardown done ===" -ForegroundColor Green
