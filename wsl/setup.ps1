<#
  Creates the WSL build distro for this repo (Alpine, ~200 MB) - once.
  Your other WSL distros are not touched. Remove it with:  wsl --unregister s2466-build

    powershell -ExecutionPolicy Bypass -File wsl\setup.ps1 -Location S:\wsl\s2466-build

  Running it again only (re)installs the packages.
#>
param(
  [string]$Name = "s2466-build",
  [string]$Location = "$env:USERPROFILE\wsl\s2466-build"
)
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# wsl -l prints UTF-16; strip the NULs
$existing = (wsl.exe -l -q) -replace "`0", "" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
if ($existing -contains $Name) {
  Write-Host "$Name already exists - installing packages only"
} else {
  $base = "https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64"
  $yaml = (Invoke-WebRequest -UseBasicParsing "$base/latest-releases.yaml").Content
  $m = [regex]::Match($yaml, "flavor: alpine-minirootfs[\s\S]*?file: (\S+)[\s\S]*?sha256: ([0-9a-f]{64})")
  if (-not $m.Success) { throw "alpine-minirootfs not found in latest-releases.yaml" }
  $file = $m.Groups[1].Value
  $sha = $m.Groups[2].Value
  $tmp = Join-Path $env:TEMP $file
  Write-Host "downloading $file"
  Invoke-WebRequest -UseBasicParsing "$base/$file" -OutFile $tmp
  if ((Get-FileHash $tmp -Algorithm SHA256).Hash.ToLower() -ne $sha) { throw "sha256 mismatch for $file" }
  New-Item -ItemType Directory -Force $Location | Out-Null
  wsl.exe --import $Name $Location $tmp --version 2
  if ($LASTEXITCODE -ne 0) { throw "wsl --import failed" }
  Remove-Item $tmp
}

# everything the build, ISO and VM-test scripts need
$pkgs = "bash coreutils util-linux findutils grep sed tar xz wget curl git git-daemon " +
        "xorriso squashfs-tools qemu-system-i386 qemu-img qemu-ui-gtk"
wsl.exe -d $Name -u root --exec sh -c "apk add -q $pkgs"
if ($LASTEXITCODE -ne 0) { throw "apk add failed" }
Write-Host "ready: $Name in $Location"
