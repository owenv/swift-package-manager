# This source file is part of the Swift open source project
#
# Copyright (c) 2014-2024 Apple Inc. and the Swift project authors
# Licensed under Apache License v2.0 with Runtime Library Exception
#
# See http://swift.org/LICENSE.txt for license information
# See http://swift.org/CONTRIBUTORS.txt for Swift project authors
#
# bootstrap.ps1 - Windows PowerShell bootstrap build script for SwiftPM
#
# Usage:
#   .\Utilities\bootstrap.ps1 build
#   .\Utilities\bootstrap.ps1 build --release
#   .\Utilities\bootstrap.ps1 build --build-dir C:\path\to\build
#   .\Utilities\bootstrap.ps1 test
#   .\Utilities\bootstrap.ps1 clean
#
# Prerequisites:
#   - Swift toolchain in PATH (or pass --swiftc-path)
#   - CMake in PATH (or pass --cmake-path)
#   - Ninja in PATH (or pass --ninja-path)
#   - Clang in PATH (or pass --clang-path)
#   - Sibling repositories checked out next to swiftpm:
#       llbuild, swift-tools-support-core, swift-argument-parser,
#       swift-driver, swift-system, swift-collections, swift-crypto,
#       swift-asn1, swift-certificates, swift-syntax, swift-tools-protocols,
#       swift-build, swift-toolchain-sqlite

[CmdletBinding()]
param(
    [Parameter(Position=0, Mandatory=$true)]
    [ValidateSet("build", "test", "clean", "install")]
    [string]$Command,

    [string]$BuildDir = ".build",
    [string]$SwiftcPath,
    [string]$ClangPath,
    [string]$CmakePath,
    [string]$NinjaPath,
    [string]$LlbuildBuildDir,
    [string]$FoundationBuildDir,
    [string]$DispatchBuildDir,
    [string]$InstallPrefix = "C:\swiftpm",
    [string]$CrossCompileConfig,
    [switch]$Release,
    [switch]$Reconfigure,
    [switch]$SkipCmakeBootstrap,
    [switch]$LlbuildLinkFramework,
    [switch]$Parallel,
    [string[]]$Filter = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------

$script:ProjectRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$script:SourceRoot  = Join-Path $script:ProjectRoot "Sources"
$script:BuildDirs   = @{}
$script:SourceDirs  = @{}

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------

function Write-Log {
    param([string]$Level, [string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "--- bootstrap | $timestamp | $($Level.PadRight(7)) | $Message"
}

function Write-Info  { param([string]$Msg) Write-Log "INFO"    $Msg }
function Write-Debug { param([string]$Msg) if ($VerbosePreference -ne 'SilentlyContinue') { Write-Log "DEBUG" $Msg } }
function Write-Err   { param([string]$Msg) Write-Log "ERROR"   $Msg ; throw $Msg }

# ---------------------------------------------------------------------------
# Path utilities
# ---------------------------------------------------------------------------

function Find-Tool {
    param([string]$ToolName, [string]$ExplicitPath)
    if ($ExplicitPath) {
        $resolved = [System.IO.Path]::GetFullPath($ExplicitPath)
        if (-not (Test-Path $resolved)) { Write-Err "Tool not found at $resolved" }
        return $resolved
    }
    $found = Get-Command $ToolName -ErrorAction SilentlyContinue
    if ($found) { return $found.Source }
    Write-Err "Unable to find $ToolName. Add it to PATH or pass the appropriate flag."
}

function Ensure-Dir {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Touch-File {
    param([string]$Path)
    Ensure-Dir (Split-Path -Parent $Path)
    if (-not (Test-Path $Path)) {
        New-Item -ItemType File -Path $Path -Force | Out-Null
    } else {
        (Get-Item $Path).LastWriteTime = Get-Date
    }
}

function Invoke-Call {
    param([string[]]$Cmd, [string]$WorkingDir = $null)
    Write-Debug "Running: $($Cmd -join ' ')"
    $exe  = $Cmd[0]
    $rest = if ($Cmd.Count -gt 1) { $Cmd[1..($Cmd.Count-1)] } else { @() }
    & $exe @rest
    if ($LASTEXITCODE -ne 0) { Write-Err "Command failed with exit code $LASTEXITCODE`: $($Cmd -join ' ')" }
}

function Invoke-CallInDir {
    param([string[]]$Cmd, [string]$WorkingDir)
    $prev = $PWD
    Set-Location $WorkingDir
    try { Invoke-Call $Cmd }
    finally { Set-Location $prev }
}

function Invoke-Output {
    param([string[]]$Cmd)
    Write-Debug "Running (capture): $($Cmd -join ' ')"
    $exe  = $Cmd[0]
    $rest = if ($Cmd.Count -gt 1) { $Cmd[1..($Cmd.Count-1)] } else { @() }
    # Run via cmd.exe so that "< NUL" gives the child a real character-device
    # handle for stdin.  PowerShell's & operator always provides a pipe, which
    # causes swiftc to treat stdin as a source-file input and either hang
    # (pipe open) or error "duplicate input file '-'" (pipe closed).
    $argStr = $rest -join ' '
    $out = cmd /c "`"$exe`" $argStr < NUL 2>NUL"
    if ($LASTEXITCODE -ne 0) { Write-Err "Command failed: $($Cmd -join ' ')" }
    return (($out -join "`n")).Trim()
}

# ---------------------------------------------------------------------------
# Toolchain discovery
# ---------------------------------------------------------------------------

function Get-SwiftcPath {
    if ($SwiftcPath) { return Find-Tool "swiftc" $SwiftcPath }
    if ($env:SWIFT_EXEC) { return $env:SWIFT_EXEC }
    return Find-Tool "swiftc" $null
}

function Initialize-VsEnvironment {
    # Skip if already initialised (e.g. running inside a Developer Command Prompt).
    if ($env:VCINSTALLDIR) { return }

    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) {
        Write-Info "vswhere not found; skipping MSVC environment setup"
        return
    }

    $vcvars = cmd /c "`"$vswhere`" -latest -find VC\Auxiliary\Build\vcvarsall.bat 2>NUL"
    if (-not $vcvars) {
        Write-Info "vcvarsall.bat not found; skipping MSVC environment setup"
        return
    }

    Write-Info "Initialising MSVC environment from $vcvars"
    # Run vcvarsall.bat and capture every environment variable it sets.
    $envLines = cmd /c "`"$vcvars`" x64 > NUL 2>&1 && set"
    foreach ($line in $envLines) {
        if ($line -match '^([^=]+)=(.*)$') {
            [System.Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process')
        }
    }
}

function Get-BuildTarget {
    $info = Invoke-Output @($script:Swiftc, "-print-target-info")
    $parsed = $info | ConvertFrom-Json
    $script:TargetInfo = $parsed
    return $parsed.target.triple
}

function Get-ModuleTriple {
    if (-not $script:TargetInfo) { Get-BuildTarget | Out-Null }
    return $script:TargetInfo.target.moduleTriple
}

# ---------------------------------------------------------------------------
# Initialise resolved paths
# ---------------------------------------------------------------------------

function Initialize-Paths {
    $script:BuildDir    = [System.IO.Path]::GetFullPath($BuildDir)
    $script:Swiftc      = Get-SwiftcPath
    # Ensure the toolchain bin is on PATH so link.exe (shipped alongside swiftc)
    # is visible to the Swift compiler when it links Swift modules.
    $toolchainBin = Split-Path -Parent $script:Swiftc
    if ($env:PATH -notlike "*$toolchainBin*") {
        $env:PATH = "$toolchainBin;$env:PATH"
    }
    # Set up MSVC environment (link.exe, LIB, INCLUDE) if not already present.
    Initialize-VsEnvironment
    $script:Clang       = Find-Tool "clang-cl" $ClangPath
    $script:Cmake       = Find-Tool "cmake"  $CmakePath
    $script:Ninja       = Find-Tool "ninja"  $NinjaPath
    $script:Configuration = if ($Release) { "release" } else { "debug" }

    $parentDir = Split-Path -Parent $script:ProjectRoot
    $script:SourceDirs = @{
        "tsc"                   = Join-Path $parentDir "swift-tools-support-core"
        "swift-argument-parser" = Join-Path $parentDir "swift-argument-parser"
        "swift-crypto"          = Join-Path $parentDir "swift-crypto"
        "swift-driver"          = Join-Path $parentDir "swift-driver"
        "swift-system"          = Join-Path $parentDir "swift-system"
        "swift-collections"     = Join-Path $parentDir "swift-collections"
        "swift-tools-protocols" = Join-Path $parentDir "swift-tools-protocols"
        "swift-certificates"    = Join-Path $parentDir "swift-certificates"
        "swift-asn1"            = Join-Path $parentDir "swift-asn1"
        "swift-syntax"          = Join-Path $parentDir "swift-syntax"
        "swift-build"           = Join-Path $parentDir "swift-build"
        "swift-toolchain-sqlite" = Join-Path $parentDir "swift-toolchain-sqlite"
        "llbuild"               = Join-Path $parentDir "llbuild"
    }

    # Determine target triple for output directory name
    $triple = Get-BuildTarget
    $script:TargetDir   = Join-Path $script:BuildDir $triple
    $script:BootstrapDir = Join-Path $script:TargetDir "bootstrap"
    $script:BinDir       = Join-Path $script:TargetDir $script:Configuration

    if ($LlbuildBuildDir) {
        $script:BuildDirs["llbuild"] = [System.IO.Path]::GetFullPath($LlbuildBuildDir)
    }
}

# ---------------------------------------------------------------------------
# CMake build helper
# ---------------------------------------------------------------------------

function Invoke-CmakeBuild {
    param(
        [string[]]$CmakeArgs,
        [string[]]$NinjaTargets = @(),
        [string]$SourcePath,
        [string]$BuildPath
    )

    Ensure-Dir $BuildPath

    $cacheFile = Join-Path $BuildPath "CMakeCache.txt"
    $needsConfigure = $Reconfigure -or
                      (-not (Test-Path $cacheFile)) -or
                      (-not (Select-String -Path $cacheFile -Pattern ([regex]::Escape($script:Swiftc)) -Quiet))

    if ($needsConfigure) {
        $moduleCache = Join-Path $BuildPath "module-cache"

        $swiftFlags = @(
            "-gnone",
            "-use-ld=lld-link",
            "-module-cache-path", "`"$moduleCache`""
        )

        # CMake's Windows-MSVC platform file auto-initialises CMAKE_SHARED_LINKER_FLAGS
        # (and EXE/MODULE variants) with bare MSVC link.exe-style flags such as
        # /machine:x64 and /INCREMENTAL:NO (for Release).  Those flags are fine when
        # clang-cl drives the link step, but they are passed verbatim to swiftc when a
        # target sets LINKER_LANGUAGE Swift (e.g. SWBCSupport in swift-build), and
        # swiftc does not recognise them.  Override the flags here so that they use the
        # -Xlinker form, which both clang-cl and swiftc forward to the underlying
        # lld-link invocation.
        $machineArch = switch -Regex ($(Get-BuildTarget)) {
            "aarch64" { "ARM64" }
            "x86_64"  { "x64"   }
            default   { "x86"   }
        }

        $cmd = @(
            $script:Cmake,
            "-G", "Ninja",
            "-DCMAKE_MAKE_PROGRAM=$($script:Ninja)",
            "-DCMAKE_BUILD_TYPE=Release",
            "-DCMAKE_Swift_COMPILER=$($script:Swiftc)",
            "-DCMAKE_Swift_COMPILER_TARGET=$(Get-BuildTarget)",
            "-DCMAKE_Swift_COMPILER_ID=Apple",
            "-DCMAKE_Swift_FLAGS=$($swiftFlags -join ' ')",
            "-DCMAKE_C_COMPILER=$($script:Clang)",
            "-DCMAKE_CXX_COMPILER=$($script:Clang)",
            "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL",
            "-DCMAKE_STATIC_LIBRARY_PREFIX_Swift=lib",
            "-DCMAKE_SHARED_LINKER_FLAGS=-Xlinker /machine:$machineArch",
            "-DCMAKE_EXE_LINKER_FLAGS=-Xlinker /machine:$machineArch",
            "-DCMAKE_MODULE_LINKER_FLAGS=-Xlinker /machine:$machineArch",
            "-DCMAKE_SHARED_LINKER_FLAGS_RELEASE=-Xlinker /INCREMENTAL:NO",
            "-DCMAKE_EXE_LINKER_FLAGS_RELEASE=-Xlinker /INCREMENTAL:NO",
            "-DCMAKE_MODULE_LINKER_FLAGS_RELEASE=-Xlinker /INCREMENTAL:NO",
            "-DCMAKE_SHARED_LINKER_FLAGS_MINSIZEREL=-Xlinker /INCREMENTAL:NO",
            "-DCMAKE_EXE_LINKER_FLAGS_MINSIZEREL=-Xlinker /INCREMENTAL:NO",
            "-DCMAKE_MODULE_LINKER_FLAGS_MINSIZEREL=-Xlinker /INCREMENTAL:NO"
        ) + $CmakeArgs + @($SourcePath)

        Write-Debug "CMake configure: $($cmd -join ' ')"
        Invoke-CallInDir $cmd $BuildPath
    }

    $ninjaCmd = @($script:Ninja) + $NinjaTargets
    $prevVerbose = $env:VERBOSE
    if ($VerbosePreference -ne 'SilentlyContinue') { $env:VERBOSE = "1" }
    try {
        Invoke-CallInDir $ninjaCmd $BuildPath
    } finally {
        $env:VERBOSE = $prevVerbose
    }
}

# ---------------------------------------------------------------------------
# Dependency builders
# ---------------------------------------------------------------------------

function Build-LLBuild {
    Write-Info "Building llbuild"

    $script:BuildDirs["llbuild"] = Join-Path $script:TargetDir "llbuild"
    $llbuildSrc = $script:SourceDirs["llbuild"]
    if (-not (Test-Path $llbuildSrc)) {
        Write-Err "llbuild source not found at $llbuildSrc. Clone swift-llbuild as 'llbuild' next to swiftpm."
    }

    # Create CMake API query so we get codemodel data
    $apiDir = Join-Path $script:BuildDirs["llbuild"] ".cmake\api\v1\query"
    Ensure-Dir $apiDir
    Touch-File (Join-Path $apiDir "codemodel-v2")

    $flags = @(
        "-DCMAKE_C_COMPILER=$($script:Clang)",
        "-DLLBUILD_SUPPORT_BINDINGS=Swift"
    )

    Invoke-CmakeBuild -CmakeArgs $flags -SourcePath $llbuildSrc -BuildPath $script:BuildDirs["llbuild"]
}

function Get-LLBuildCmakeArg {
    if ($LlbuildLinkFramework) {
        return "-DCMAKE_FIND_FRAMEWORK_EXTRA_LOCATIONS=$($script:BuildDirs['llbuild'])"
    }
    return "-DLLBuild_DIR=$(Join-Path $script:BuildDirs['llbuild'] 'cmake\modules')"
}

function Build-Dependency {
    param(
        [string]$Name,
        [string[]]$CmakeFlags = @()
    )
    Write-Info "Building dependency $Name"
    $script:BuildDirs[$Name] = Join-Path $script:TargetDir $Name
    $src = $script:SourceDirs[$Name]
    if (-not (Test-Path $src)) {
        Write-Err "Source for $Name not found at $src"
    }
    Invoke-CmakeBuild -CmakeArgs $CmakeFlags -SourcePath $src -BuildPath $script:BuildDirs[$Name]
}

function Build-SwiftPMWithCMake {
    Write-Info "Building SwiftPM (with CMake)"

    $moduleTriple = Get-ModuleTriple

    $cmakeFlags = @(
        $(Get-LLBuildCmakeArg),
        "-DTSC_DIR=$(Join-Path $script:BuildDirs['tsc'] 'cmake\modules')",
        "-DArgumentParser_DIR=$(Join-Path $script:BuildDirs['swift-argument-parser'] 'cmake\modules')",
        "-DSwiftToolsProtocols_DIR=$(Join-Path $script:BuildDirs['swift-tools-protocols'] 'cmake\modules')",
        "-DSwiftDriver_DIR=$(Join-Path $script:BuildDirs['swift-driver'] 'cmake\modules')",
        "-DSwiftSystem_DIR=$(Join-Path $script:BuildDirs['swift-system'] 'cmake\modules')",
        "-DSwiftCollections_DIR=$(Join-Path $script:BuildDirs['swift-collections'] 'cmake\modules')",
        "-DSwiftCrypto_DIR=$(Join-Path $script:BuildDirs['swift-crypto'] 'cmake\modules')",
        "-DSwiftASN1_DIR=$(Join-Path $script:BuildDirs['swift-asn1'] 'cmake\modules')",
        "-DSwiftCertificates_DIR=$(Join-Path $script:BuildDirs['swift-certificates'] 'cmake\modules')",
        "-DSwiftBuild_DIR=$(Join-Path $script:BuildDirs['swift-build'] 'cmake\modules')",
        "-DSWIFTPM_PATH_TO_SWIFT_SYNTAX_SOURCE=$($script:SourceDirs['swift-syntax'])",
        "-DSwiftPMRuntime_MODULE_TRIPLE=$moduleTriple",
        # SwiftPM's CMakeLists.txt uses find_package(SQLite3 REQUIRED).  On Windows
        # there is no system SQLite3, so point CMake's FindSQLite3 module at the
        # copy we built from swift-toolchain-sqlite above.
        "-DSQLite3_INCLUDE_DIR=$(Join-Path $script:SourceDirs['swift-toolchain-sqlite'] 'Sources\CSQLite\include')",
        "-DSQLite3_LIBRARY=$(Join-Path $script:BuildDirs['swift-toolchain-sqlite'] 'SQLite3.lib')"
    )

    $targets = @("swift-bootstrap", "PackageDescription", "PackagePlugin", "CompilerPluginSupport", "swift-package")
    Invoke-CmakeBuild -CmakeArgs $cmakeFlags -NinjaTargets $targets `
        -SourcePath $script:ProjectRoot -BuildPath $script:BootstrapDir

    # Copy runtime module files to expected locations
    $pmManifestDir = Join-Path $script:BootstrapDir "pm\ManifestAPI"
    $pmPluginDir   = Join-Path $script:BootstrapDir "pm\PluginAPI"
    Ensure-Dir $pmManifestDir
    Ensure-Dir $pmPluginDir

    $modulesBase = Join-Path $script:BootstrapDir "Sources\Runtimes"
    Copy-Item (Join-Path $modulesBase "PackageDescription\PackageDescription.swiftmodule\$moduleTriple.swiftmodule") `
              (Join-Path $pmManifestDir "PackageDescription.swiftmodule") -Force
    Copy-Item (Join-Path $modulesBase "CompilerPluginSupport\CompilerPluginSupport.swiftmodule\$moduleTriple.swiftmodule") `
              (Join-Path $pmManifestDir "CompilerPluginSupport.swiftmodule") -Force
    Copy-Item (Join-Path $modulesBase "PackagePlugin\PackagePlugin.swiftmodule\$moduleTriple.swiftmodule") `
              (Join-Path $pmPluginDir "PackagePlugin.swiftmodule") -Force
}

function Build-SwiftPMWithSwiftPM {
    param([bool]$IntegratedDriver = $false)

    Write-Info "Building SwiftPM (with swift-bootstrap)"

    $env:SWIFTCI_USE_LOCAL_DEPS = "1"
    $env:SWIFT_EXEC = $script:Swiftc
    $env:SWIFT_DRIVER_SWIFT_EXEC = $script:Swiftc
    $env:CC = $script:Clang
    $env:SWIFTPM_CUSTOM_LIBS_DIR = Join-Path $script:BootstrapDir "pm"

    # Add all dependency lib directories to PATH so DLLs can be found
    $libDirs = @(
        (Join-Path $script:BootstrapDir               "bin"),
        (Join-Path $script:BuildDirs["tsc"]            "bin"),
        (Join-Path $script:BuildDirs["llbuild"]        "bin"),
        (Join-Path $script:BuildDirs["swift-argument-parser"] "bin"),
        (Join-Path $script:BuildDirs["swift-crypto"]   "bin"),
        (Join-Path $script:BuildDirs["swift-driver"]   "bin"),
        (Join-Path $script:BuildDirs["swift-system"]   "bin"),
        (Join-Path $script:BuildDirs["swift-collections"] "bin"),
        (Join-Path $script:BuildDirs["swift-tools-protocols"] "bin"),
        (Join-Path $script:BuildDirs["swift-asn1"]     "bin"),
        (Join-Path $script:BuildDirs["swift-certificates"] "bin"),
        (Join-Path $script:BuildDirs["swift-build"]    "bin")
    )
    $env:PATH = ($libDirs -join ";") + ";$env:PATH"

    $swiftBootstrap = Join-Path $script:BootstrapDir "bin\swift-bootstrap.exe"

    $buildFlags = @(
        "--build-path", $script:BuildDir,
        "--disable-sandbox"
    )

    if ($Release) {
        $buildFlags += @("--configuration", "release")
    }

    if ($VerbosePreference -ne 'SilentlyContinue') {
        $buildFlags += "--very-verbose"
    }

    if ($IntegratedDriver) {
        $buildFlags += "--use-integrated-swift-driver"
    }

    # Isolate module cache
    $moduleCache = Join-Path $script:BuildDir "module-cache"
    foreach ($modifier in @("-Xswiftc", "-Xbuild-tools-swiftc")) {
        $buildFlags += @($modifier, "-module-cache-path", $modifier, $moduleCache)
    }

    Invoke-CallInDir (@($swiftBootstrap) + $buildFlags) $script:ProjectRoot
}

# ---------------------------------------------------------------------------
# Top-level actions
# ---------------------------------------------------------------------------

function Invoke-Build {
    Initialize-Paths

    $needBootstrap = (-not $SkipCmakeBootstrap) -or
                     (-not (Test-Path (Join-Path (Split-Path -Parent $script:Swiftc) "swift-build.exe")))

    if ($needBootstrap) {
        Write-Info "Building bootstrap"

        if (-not $script:BuildDirs.ContainsKey("llbuild")) {
            Build-LLBuild
        }

        Build-Dependency "swift-system"

        Build-Dependency "tsc" @(
            "-DSwiftSystem_DIR=$(Join-Path $script:BuildDirs['swift-system'] 'cmake\modules')"
        )

        Build-Dependency "swift-argument-parser" @(
            "-DBUILD_TESTING=NO",
            "-DBUILD_EXAMPLES=NO"
        )

        Build-Dependency "swift-driver" @(
            $(Get-LLBuildCmakeArg),
            "-DSwiftSystem_DIR=$(Join-Path $script:BuildDirs['swift-system'] 'cmake\modules')",
            "-DTSC_DIR=$(Join-Path $script:BuildDirs['tsc'] 'cmake\modules')",
            "-DArgumentParser_DIR=$(Join-Path $script:BuildDirs['swift-argument-parser'] 'cmake\modules')"
        )

        Build-Dependency "swift-collections"
        Build-Dependency "swift-tools-protocols"
        Build-Dependency "swift-asn1"

        # swift-toolchain-sqlite provides SQLite3 as a built-from-source C library.
        # Windows has no system SQLite3, so we must build it explicitly and point
        # SwiftPM's CMake configure step at the resulting headers and library.
        Build-Dependency "swift-toolchain-sqlite" @(
            "-DBUILD_SHARED_LIBS=NO"
        )

        Build-Dependency "swift-crypto" @(
            "-DSwiftASN1_DIR=$(Join-Path $script:BuildDirs['swift-asn1'] 'cmake\modules')"
        )

        Build-Dependency "swift-certificates" @(
            "-DSwiftASN1_DIR=$(Join-Path $script:BuildDirs['swift-asn1'] 'cmake\modules')",
            "-DSwiftCrypto_DIR=$(Join-Path $script:BuildDirs['swift-crypto'] 'cmake\modules')"
        )

        Build-Dependency "swift-build" @(
            $(Get-LLBuildCmakeArg),
            "-DSwiftSystem_DIR=$(Join-Path $script:BuildDirs['swift-system'] 'cmake\modules')",
            "-DSwiftASN1_DIR=$(Join-Path $script:BuildDirs['swift-asn1'] 'cmake\modules')",
            "-DSwiftCrypto_DIR=$(Join-Path $script:BuildDirs['swift-crypto'] 'cmake\modules')",
            "-DTSC_DIR=$(Join-Path $script:BuildDirs['tsc'] 'cmake\modules')",
            "-DArgumentParser_DIR=$(Join-Path $script:BuildDirs['swift-argument-parser'] 'cmake\modules')",
            "-DSwiftDriver_DIR=$(Join-Path $script:BuildDirs['swift-driver'] 'cmake\modules')",
            "-DSwiftToolsProtocols_DIR=$(Join-Path $script:BuildDirs['swift-tools-protocols'] 'cmake\modules')"
        )

        Build-SwiftPMWithCMake
    }

    Build-SwiftPMWithSwiftPM
}

function Invoke-Test {
    Invoke-Build

    Write-Info "Testing"

    $swiftTest = Join-Path $script:BinDir "swift-test.exe"

    $cmd = @($swiftTest)
    if ($Parallel) { $cmd += "--parallel" }
    foreach ($f in $Filter) { $cmd += @("--filter", $f) }

    Invoke-CallInDir $cmd $script:ProjectRoot
}

function Invoke-Clean {
    $resolvedBuildDir = [System.IO.Path]::GetFullPath($BuildDir)
    Write-Info "Cleaning $resolvedBuildDir"
    if (Test-Path $resolvedBuildDir) {
        Remove-Item -Recurse -Force $resolvedBuildDir
    }
}

function Invoke-Install {
    Invoke-Build

    Write-Info "Installing to $InstallPrefix"

    $binDest  = Join-Path $InstallPrefix "bin"
    $shareDest = Join-Path $InstallPrefix "share\pm"
    Ensure-Dir $binDest
    Ensure-Dir $shareDest

    # Install swift-package-manager.exe
    $spmExe = Join-Path $script:BinDir "swift-package-manager.exe"
    if (Test-Path $spmExe) {
        Copy-Item $spmExe (Join-Path $binDest "swift-package.exe") -Force
    }

    # On Windows, create copies (not symlinks) of the tool under alternate names
    foreach ($tool in @("swift-build", "swift-test", "swift-run", "swift-package-collection",
                         "swift-package-registry", "swift-sdk", "swift-experimental-sdk")) {
        $dest = Join-Path $binDest "$tool.exe"
        Copy-Item (Join-Path $binDest "swift-package.exe") $dest -Force
    }

    # Install config.json
    $configSrc = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "config.json"
    Copy-Item $configSrc $shareDest -Force

    Write-Info "Install complete"
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

Write-Info "Command: $Command"

switch ($Command) {
    "build"   { Invoke-Build }
    "test"    { Invoke-Test }
    "clean"   { Invoke-Clean }
    "install" { Invoke-Install }
}

Write-Info "Done"
