param(
    [Parameter(Mandatory=$false)]
    [ValidateSet('msvc', 'gcc', 'auto')]
    [string]$Compiler = 'auto',

    [Parameter(Mandatory=$false)]
    [switch]$NoSign,

    [Parameter(Mandatory=$false)]
    [ValidateSet('x64', 'x86', 'arm64')]
    [string]$Arch
)

# Auto-detect architecture if not specified
if (-not $PSBoundParameters.ContainsKey('Arch')) {
    $nativeArch = $env:PROCESSOR_ARCHITECTURE
    Write-Host "Auto-detecting architecture: $nativeArch" -ForegroundColor Cyan
    if ($nativeArch -eq 'AMD64') {
        $Arch = 'x64'
    } elseif ($nativeArch -eq 'ARM64') {
        $Arch = 'arm64'
    } elseif ($nativeArch -eq 'X86') {
        $Arch = 'x86'
    } else {
        Write-Host "Unsupported architecture for auto-detection: $nativeArch. Defaulting to x64." -ForegroundColor Yellow
        $Arch = 'x64'
    }
}
Write-Host "Building for Architecture: $Arch" -ForegroundColor Cyan

# Dynamically find WinDivert path
$WinDivertPath = (Get-ChildItem "C:\WinDivert-*-A" | Select-Object -First 1).FullName
$SourcePath = "src"
$SourceFile = "ProxyBridge.c"
$OutputDLL = "ProxyBridgeCore.dll"
$OutputDir = "output"

$SignTool = "signtool.exe"
$CertThumbprint = ""
$TimestampServer = "http://timestamp.digicert.com"

if (Test-Path $OutputDir) {
    Write-Host "Removing existing output directory..." -ForegroundColor Yellow
    Remove-Item $OutputDir -Recurse -Force
}
Write-Host "Creating output directory: $OutputDir" -ForegroundColor Cyan
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

if (-not (Test-Path $WinDivertPath)) {
    Write-Host "ERROR: WinDivert not found at: C:\WinDivert-*-A" -ForegroundColor Red
    Write-Host "Please ensure WinDivert was built or downloaded correctly." -ForegroundColor Yellow
    exit 1
}

function Compile-MSVC {
    # MSVC compilation is not configured for ARM64 in this script.
    # We will rely on Clang/GCC for ARM64.
    if ($Arch -eq 'arm64') {
        Write-Host "MSVC compilation for ARM64 is not supported by this script. Please use -Compiler gcc." -ForegroundColor Yellow
        return $false
    }

    Write-Host "`nCompiling DLL with MSVC..." -ForegroundColor Green

    $vsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"

    if (Test-Path $vsWhere) {
        $vsPath = & $vsWhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
        if ($vsPath) {
            $vcvarsPath = Join-Path $vsPath "VC\Auxiliary\Build\vcvarsall.bat"
            if (Test-Path $vcvarsPath) {
                Write-Host "Found Visual Studio at: $vsPath" -ForegroundColor Cyan
            }
        }
    }

    $cmd = "cl.exe /nologo /O2 /W3 /D_CRT_SECURE_NO_WARNINGS /DPROXYBRIDGE_EXPORTS " +
           "/I`"$WinDivertPath\include`" " +
           "$SourcePath\$SourceFile " +
           "/LD " +
           "/link /LIBPATH:`"$WinDivertPath\$Arch`" " +
           "WinDivert.lib ws2_32.lib iphlpapi.lib " +
           "/OUT:$OutputDLL"

    Write-Host "Command: $cmd" -ForegroundColor Gray

    $result = cmd /c $cmd '2>&1'
    $exitCode = $LASTEXITCODE

    Write-Host $result

    return $exitCode -eq 0
}

function Compile-Mingw { # Changed from Compile-GCC
    Write-Host "`nCompiling DLL with MinGW/Clang..." -ForegroundColor Green

    $compilerExe = if ($Arch -eq 'arm64') { 'clang' } else { 'gcc' }
    $compilerVersion = cmd /c "$compilerExe --version 2>&1"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: $compilerExe not found in PATH" -ForegroundColor Red
        return $false
    }
    Write-Host "$compilerExe found: $($compilerVersion[0])" -ForegroundColor Cyan

    $libArchDir = switch ($Arch) {
        'x64'   { 'x64' }
        'x86'   { 'x86' }
        'arm64' { 'aarch64' } # clang-aarch64 toolchain uses 'aarch64'
    }

    $cmd = "$compilerExe -shared -O2 -Wall -D_WIN32_WINNT=0x0601 -DPROXYBRIDGE_EXPORTS " +
           "-I`"$WinDivertPath\include`" " +
           "$SourcePath\$SourceFile " +
           "-L`"$WinDivertPath\$libArchDir`" " +
           "-lWinDivert -lws2_32 -liphlpapi " +
           "-o $OutputDLL"

    Write-Host "Command: $cmd" -ForegroundColor Gray

    $result = cmd /c $cmd '2>&1'
    $exitCode = $LASTEXITCODE

    Write-Host $result

    return $exitCode -eq 0
}

function Sign-Binary {
    param(
        [string]$FilePath
    )

    if (-not (Test-Path $FilePath)) {
        Write-Host "  File not found: $FilePath" -ForegroundColor Red
        return $false
    }

    $fileName = Split-Path $FilePath -Leaf

    if ($fileName -like "WinDivert*") {
        Write-Host "  Skipped: $fileName (WinDivert is already EV signed)" -ForegroundColor Yellow
        return $true
    }

    Write-Host "  Signing: $fileName" -ForegroundColor Cyan

    if ([string]::IsNullOrEmpty($CertThumbprint)) {
        $cmd = "signtool.exe sign /a /fd SHA256 /tr `"$TimestampServer`" /td SHA256 `"$FilePath`""
    } else {
        $cmd = "signtool.exe sign /sha1 $CertThumbprint /fd SHA256 /tr `"$TimestampServer`" /td SHA256 `"$FilePath`""
    }

    $result = cmd /c $cmd '2>&1'
    $exitCode = $LASTEXITCODE

    if ($exitCode -eq 0) {
        Write-Host "    ✓ Signed successfully" -ForegroundColor Green
        return $true
    } else {
        Write-Host "    ✗ Signing failed: $result" -ForegroundColor Red
        return $false
    }
}

$success = $false
# On arm64, force compiler to 'gcc' (which now means clang)
if ($Arch -eq 'arm64') {
    $Compiler = 'gcc'
}

if ($Compiler -eq 'auto') {
    Write-Host "Auto-detecting compiler..." -ForegroundColor Cyan
    $success = Compile-MSVC
    if (-not $success) {
        Write-Host "`nMSVC compilation failed, trying GCC..." -ForegroundColor Yellow
        $success = Compile-Mingw
    }
} elseif ($Compiler -eq 'msvc') {
    $success = Compile-MSVC
} elseif ($Compiler -eq 'gcc') {
    $success = Compile-Mingw
}


if ($success) {
    Write-Host "`nCompilation SUCCESSFUL!" -ForegroundColor Green

    Write-Host "`nMoving files to output directory..." -ForegroundColor Green
    Move-Item $OutputDLL -Destination $OutputDir -Force
    Write-Host "  Moved: $OutputDLL -> $OutputDir\" -ForegroundColor Gray

    $libArchDir = switch ($Arch) {
        'x64'   { 'x64' }
        'x86'   { 'x86' }
        'arm64' { 'aarch64' }
    }
    $divertLibPath = Join-Path $WinDivertPath $libArchDir
    
    $filesToCopy = @()
    $filesToCopy += Join-Path $divertLibPath "WinDivert.dll"

    if ($Arch -eq 'x64') {
        $filesToCopy += Join-Path $divertLibPath "WinDivert64.sys"
        $filesToCopy += Join-Path $divertLibPath "WinDivert32.sys"
    } elseif ($Arch -eq 'arm64' -or $Arch -eq 'x86') {
        $filesToCopy += Join-Path $divertLibPath "WinDivert.sys"
    }

    foreach ($file in $filesToCopy) {
        if (Test-Path $file) {
            Copy-Item $file -Destination $OutputDir -Force
            Write-Host "  Copied: $(Split-Path $file -Leaf)" -ForegroundColor Gray
        } else {
            Write-Host "  Warning: Could not find file to copy: $file" -ForegroundColor Yellow
        }
    }
    
    $dotnetRid = switch ($Arch) {
        'x64'   { 'win-x64' }
        'x86'   { 'win-x86' }
        'arm64' { 'win-arm64' }
        default { 'win-x64' }
    }
    Write-Host "`nUsing .NET Runtime Identifier (RID): $dotnetRid" -ForegroundColor Cyan

    Write-Host "`nPublishing GUI..." -ForegroundColor Green
    $guiPublishPath = "gui/bin/Release/net9.0-windows/$dotnetRid/publish"
    $publishResult = dotnet publish gui/ProxyBridge.GUI.csproj -c Release -r $dotnetRid --self-contained -o $guiPublishPath 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  GUI published successfully" -ForegroundColor Gray

        Write-Host "`nCopying GUI files to output..." -ForegroundColor Green
        Copy-Item "$guiPublishPath\ProxyBridge.exe" -Destination $OutputDir -Force
        Write-Host "  Copied: ProxyBridge.exe" -ForegroundColor Gray

        Get-ChildItem "$guiPublishPath\*.dll" | ForEach-Object {
            Copy-Item $_.FullName -Destination $OutputDir -Force
            Write-Host "  Copied: $($_.Name)" -ForegroundColor Gray
        }
    } else {
        Write-Host "  GUI publish failed!" -ForegroundColor Red
        Write-Host $publishResult
    }

    Write-Host "`nPublishing CLI..." -ForegroundColor Green
    $cliPublishPath = "cli/bin/Release/net9.0-windows/$dotnetRid/publish"
    $publishResult = dotnet publish cli/ProxyBridge.CLI.csproj -c Release -r $dotnetRid --self-contained -o $cliPublishPath 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  CLI published successfully" -ForegroundColor Gray

        Write-Host "`nCopying CLI files to output..." -ForegroundColor Green
        Copy-Item "$cliPublishPath\ProxyBridge_CLI.exe" -Destination $OutputDir -Force
        Write-Host "  Copied: ProxyBridge_CLI.exe" -ForegroundColor Gray
    } else {
        Write-Host "  CLI publish failed!" -ForegroundColor Red
        Write-Host $publishResult
    }

    if (-not $NoSign) {
        Write-Host "`nSigning binaries..." -ForegroundColor Green
        $filesToSign = Get-ChildItem $OutputDir -Include *.exe,*.dll -Recurse
        $signedCount = 0
        $skippedCount = 0

        foreach ($file in $filesToSign) {
            if ($file.Name -like "WinDivert*") {
                Write-Host "  Skipped: $($file.Name) (WinDivert is already EV signed)" -ForegroundColor Yellow
                $skippedCount++
            } else {
                if (Sign-Binary -FilePath $file.FullName) {
                    $signedCount++
                }
            }
        }

        Write-Host "`nSigning Summary:" -ForegroundColor Cyan
        Write-Host "  Signed: $signedCount files" -ForegroundColor Green
        Write-Host "  Skipped: $skippedCount files (WinDivert)" -ForegroundColor Yellow
    } else {
        Write-Host "`nSigning skipped (-NoSign flag)" -ForegroundColor Yellow
    }

    Write-Host "`nAll files ready in: $OutputDir\" -ForegroundColor Cyan
    Write-Host "Contents:" -ForegroundColor Yellow
    Get-ChildItem $OutputDir | ForEach-Object {
        $size = [math]::Round($_.Length/1MB, 2)
        Write-Host "  - $($_.Name) ($size MB)" -ForegroundColor Gray
    }

    Write-Host "`nBuilding installer..." -ForegroundColor Green
    $nsisPath = "C:\Program Files (x86)\NSIS\Bin\makensis.exe"
    if (Test-Path $nsisPath) {
        Push-Location installer
        # Pass architecture to NSIS script
        $result = & $nsisPath "/DARCH=$Arch" "ProxyBridge.nsi" 2>&1
        Pop-Location
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  Installer created successfully" -ForegroundColor Green
            # Installer name might need to be arch-specific
            $installerName = "ProxyBridge-Setup-2.0.1.exe" 
            if (Test-Path "installer\$installerName") {
                $archSpecificInstallerName = "ProxyBridge-Setup-2.0.1-$Arch.exe"
                Move-Item "installer\$installerName" -Destination "$OutputDir\$archSpecificInstallerName" -Force
                Write-Host "  Moved and Renamed: $archSpecificInstallerName -> $OutputDir\" -ForegroundColor Gray

                if (-not $NoSign) {
                    Write-Host "`nSigning installer..." -ForegroundColor Green
                    if (Sign-Binary -FilePath "$OutputDir\$archSpecificInstallerName") {
                        $installerSize = [math]::Round((Get-Item "$OutputDir\$archSpecificInstallerName").Length/1MB, 2)
                        Write-Host "  Installer ready: $OutputDir\$archSpecificInstallerName ($installerSize MB)" -ForegroundColor Cyan
                    }
                } else {
                    $installerSize = [math]::Round((Get-Item "$OutputDir\$archSpecificInstallerName").Length/1MB, 2)
                    Write-Host "  Installer ready: $OutputDir\$archSpecificInstallerName ($installerSize MB)" -ForegroundColor Cyan
                }
            }
        } else {
            Write-Host "  Installer build failed!" -ForegroundColor Red
            Write-Host $result
        }
    } else {
        Write-Host "  NSIS not found at: $nsisPath" -ForegroundColor Yellow
        Write-Host "  Skipping installer creation" -ForegroundColor Yellow
    }
} else {
    Write-Host "`nCompilation FAILED!" -ForegroundColor Red
    Write-Host "Need: Visual Studio with C++ or MinGW-w64" -ForegroundColor Yellow
    exit 1
}
