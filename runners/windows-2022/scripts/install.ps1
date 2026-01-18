$ErrorActionPreference = "Stop"

function Install-Chocolatey {
  if (Get-Command choco.exe -ErrorAction SilentlyContinue) {
    Write-Host "Chocolatey already installed."
    return
  }
  Write-Host "Installing Chocolatey..."
  Set-ExecutionPolicy Bypass -Scope Process -Force
  [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
  Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
}

function Install-Tools {
  Write-Host "Installing CMake and Git..."
  choco install -y cmake --installargs 'ADD_CMAKE_TO_PATH=System'
  choco install -y git
}

function Install-VSBuildTools {
  Write-Host "Installing Visual Studio Build Tools..."
  choco install -y visualstudio2022buildtools --package-parameters "--add Microsoft.VisualStudio.Workload.VCTools --includeRecommended --includeOptional"
}

function Install-Runner {
  $runnerVersion = $env:RUNNER_VERSION
  if (-not $runnerVersion) { $runnerVersion = "2.327.0" }
  $runnerArch = $env:RUNNER_ARCH
  if (-not $runnerArch) { $runnerArch = "x64" }
  $runnerRoot = "C:\\actions-runner"

  if (-not (Test-Path $runnerRoot)) {
    New-Item -ItemType Directory -Path $runnerRoot | Out-Null
  }

  $zipName = "actions-runner-win-$runnerArch-$runnerVersion.zip"
  $zipPath = Join-Path $runnerRoot $zipName
  $url = "https://github.com/actions/runner/releases/download/v$runnerVersion/$zipName"

  Write-Host "Downloading runner $runnerVersion..."
  Invoke-WebRequest -Uri $url -OutFile $zipPath
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $runnerRoot, $true)
  Remove-Item $zipPath -Force
}

Install-Chocolatey
Install-Tools
Install-VSBuildTools
Install-Runner
