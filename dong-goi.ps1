# Đóng gói ứng dụng thành một thư mục chạy được, sao chép sang máy khác là dùng.
#
#   powershell -ExecutionPolicy Bypass -File dong-goi.ps1
#
# Kết quả nằm trong dist\SachLuoi\ gồm file exe và các thư viện đi kèm, trong đó
# có thư viện Rust chạy mô hình. Mô hình giọng nói KHÔNG được sao chép — máy đích
# tự tải trong phần Cài đặt của ứng dụng.

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$flutter = 'C:\Software\flutter\bin\flutter.bat'
$dist = Join-Path $root 'dist\SachLuoi'

Write-Host ''
Write-Host '  Dang build ung dung Windows...' -ForegroundColor Cyan
$env:PUB_CACHE = 'C:\Software\.pub-cache'
Push-Location (Join-Path $root 'app')
& $flutter build windows --release
if ($LASTEXITCODE -ne 0) { Pop-Location; throw 'Build that bai' }
Pop-Location

$release = Join-Path $root 'app\build\windows\x64\runner\Release'
if (-not (Test-Path $release)) { throw "Khong tim thay thu muc build: $release" }

Write-Host '  Dang sao chep file...' -ForegroundColor Cyan
if (Test-Path $dist) { Remove-Item $dist -Recurse -Force }
New-Item -ItemType Directory -Path $dist -Force | Out-Null

# Ứng dụng và các DLL đi kèm
Copy-Item (Join-Path $release '*') $dist -Recurse -Force

# Không chép tts_service nữa: mô hình chạy thẳng trong ứng dụng qua thư viện
# Rust, thư mục đó giờ chỉ còn là công cụ chuẩn bị dữ liệu cho người phát triển.
Copy-Item (Join-Path $root 'README.md') $dist -Force

$size = (Get-ChildItem $dist -Recurse -File | Measure-Object -Property Length -Sum).Sum / 1MB
Write-Host ''
Write-Host ('  Thu muc chay duoc: {0:N0} MB tai {1}' -f $size, $dist) -ForegroundColor Green

# -- Bo cai dat -------------------------------------------------------------
# Can Inno Setup. Chua co thi bo qua, thu muc o tren van dung duoc binh thuong.
$iscc = @(
  "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
  "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
  "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $iscc) {
  Write-Host ''
  Write-Host '  Chua co Inno Setup nen bo qua buoc tao bo cai.' -ForegroundColor Yellow
  Write-Host '  Cai bang: winget install --id JRSoftware.InnoSetup --scope user' -ForegroundColor Yellow
} else {
  Write-Host ''
  Write-Host '  Dang tao bo cai dat...' -ForegroundColor Cyan
  & $iscc (Join-Path $root 'installer.iss') | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'Tao bo cai that bai' }
  $setup = Get-ChildItem (Join-Path $root 'dist') -Filter 'SachLuoi-Setup-*.exe' |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
  Write-Host ('  Bo cai: {0:N1} MB tai {1}' -f ($setup.Length / 1MB), $setup.FullName) -ForegroundColor Green
}

Write-Host ''
Write-Host '  Chay SachLuoi.exe de mo ung dung, hoac dua bo cai sang may khac.' -ForegroundColor Green
Write-Host ''
