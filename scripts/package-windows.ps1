# Windows packaging script for chuk_chat
# Creates MSIX installer and portable ZIP

param(
    [string]$Version = "1.0.0",
    [switch]$SkipBuild = $false
)

Write-Host "🪟 Building Windows release..." -ForegroundColor Cyan

# Load environment variables
if (Test-Path .env) {
    Get-Content .env | ForEach-Object {
        if ($_ -match '^([^=]+)=(.*)$') {
            [Environment]::SetEnvironmentVariable($matches[1], $matches[2], "Process")
        }
    }
}

$SUPABASE_URL = $env:SUPABASE_URL
$SUPABASE_ANON_KEY = $env:SUPABASE_ANON_KEY

if (-not $SUPABASE_URL -or -not $SUPABASE_ANON_KEY) {
    Write-Host "❌ Error: SUPABASE_URL or SUPABASE_ANON_KEY not set" -ForegroundColor Red
    Write-Host "Create .env file with these values or set environment variables" -ForegroundColor Yellow
    exit 1
}

# Build Flutter app
if (-not $SkipBuild) {
    Write-Host "Building Flutter Windows app..." -ForegroundColor Yellow
    flutter build windows --release `
        --dart-define=SUPABASE_URL=$SUPABASE_URL `
        --dart-define=SUPABASE_ANON_KEY=$SUPABASE_ANON_KEY `
        --dart-define=FEATURE_PROJECTS=true `
        --dart-define=FEATURE_IMAGE_GEN=true `
        --dart-define=FEATURE_MEDIA_MANAGER=true `
        --dart-define=FEATURE_VOICE_MODE=true `
        --tree-shake-icons

    if ($LASTEXITCODE -ne 0) {
        Write-Host "❌ Flutter build failed" -ForegroundColor Red
        exit 1
    }
}

# Create portable ZIP
Write-Host "📦 Creating portable ZIP..." -ForegroundColor Yellow
$releaseDir = "build\windows\x64\runner\Release"
$zipPath = "build\windows\chuk_chat-$Version-windows-portable.zip"

if (Test-Path $zipPath) {
    Remove-Item $zipPath -Force
}

Compress-Archive -Path "$releaseDir\*" -DestinationPath $zipPath
Write-Host "✅ Portable ZIP created: $zipPath" -ForegroundColor Green

# Build MSIX
Write-Host "📦 Creating MSIX installer..." -ForegroundColor Yellow

# Ensure msix tool is installed
flutter pub add msix --dev

# Build MSIX
flutter pub run msix:create --build-windows false

$msixFile = Get-ChildItem -Path "$releaseDir" -Filter "*.msix" | Select-Object -First 1

if ($msixFile) {
    Write-Host "✅ MSIX installer created: $($msixFile.FullName)" -ForegroundColor Green
} else {
    Write-Host "⚠️  MSIX file not found" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "✅ Windows packaging complete!" -ForegroundColor Green
Write-Host "📦 Portable ZIP: $zipPath" -ForegroundColor Cyan
if ($msixFile) {
    Write-Host "📦 MSIX Installer: $($msixFile.FullName)" -ForegroundColor Cyan
}
