# run_lab.ps1 - Build (once) and run a lab script inside Docker
# Usage: .\run_lab.ps1 <lab_script>
# Example: .\run_lab.ps1 lab5_1.sh

param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$Script,
    [switch]$Build
)

$Image = "awscli-labs"

if (-not (Test-Path $Script)) {
    Write-Error "ERROR: '$Script' not found."
    exit 1
}

if (-not (Test-Path ".env")) {
    Write-Error "ERROR: .env file not found. Copy .env.example and fill in your credentials."
    exit 1
}

# Build the image if it doesn't exist yet, or if --Build is passed
$imageExists = docker image inspect $Image 2>$null
if ($Build -or -not $imageExists) {
    Write-Host "==> Building Docker image '$Image'..."
    docker build -t $Image .
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

Write-Host "==> Running $Script inside Docker..."

# Use the Windows-style path that Docker Desktop expects
$HostPwd = (Get-Location).Path.Replace('\', '/')

docker run --rm -it `
    --env-file .env `
    -v "${HostPwd}:/lab" `
    $Image `
    bash $Script
