# Codex CLI sandbox installer for native Windows (Route B).
#
#  THIS FILE IS GENERATED — do not edit it directly.
#  Source: src/, assembled by tools/build.sh. Edit there and rebuild.
#  Version 1.3.0
#
#
#   irm https://raw.githubusercontent.com/mriffle/llm-cli-docker-sandbox/main/install/codex.ps1 | iex
#
# Creates <home>\codex-sandbox\{Dockerfile,config.toml}, launcher scripts in
# <home>\bin, a per-user image, and the volume that holds your login.
param(
    [switch]$Check,
    [switch]$Force,
    [switch]$Uninstall,
    [switch]$Purge,
    [switch]$Yes,
    [switch]$NoBuild,
    [switch]$NoPathEdit,
    [switch]$PrintPath,
    [switch]$Quiet,
    [switch]$Version,
    [switch]$Help,
    [string]$Prefix,
    [string]$SrcDir
)
$ErrorActionPreference = 'Stop'

$script:InstallerVersion = '1.3.0'
$script:RawBase          = 'https://raw.githubusercontent.com/mriffle/llm-cli-docker-sandbox/main'
$script:RepoUrl          = 'https://github.com/mriffle/llm-cli-docker-sandbox'
$script:Agent            = 'codex'
$script:AgentName        = 'Codex CLI'
$script:LauncherName     = 'codex-sandbox'
$script:ImageBasename    = 'codex-sandbox'
$script:VolumeBasenames  = @('codex-config')

# ---------------------------------------------------------------------------
# lib.ps1 — shared helpers for the native-Windows sandbox installers.
#
# Mirrors src/lib/common.sh. Differences that matter on this route: Docker
# Desktop papers over Linux file ownership for Windows bind mounts, so no
# UID/GID build args; and WSL2 is a hard prerequisite because it is the
# engine Docker Desktop runs Linux containers on.
#
# Test seams: SANDBOX_FAKE_HOME, SANDBOX_FAKE_PLATFORM, SANDBOX_FAKE_USER.
# ---------------------------------------------------------------------------

$script:ExitMissingDocker = 10
$script:ExitDockerUnreachable = 11
$script:ExitNoWsl = 12
$script:ExitUnsupported = 78

# ---- output ---------------------------------------------------------------

function Say  { param([string]$Text = '') if (-not $script:Quiet) { [Console]::Error.WriteLine($Text) } }
function Step { param([string]$Text) if (-not $script:Quiet) { [Console]::Error.WriteLine("==> $Text") } }
function Ok   { param([string]$Text) if (-not $script:Quiet) { [Console]::Error.WriteLine("  $Text") } }
function Info { param([string]$Text) if (-not $script:Quiet) { [Console]::Error.WriteLine("  $Text") } }
function Warn { param([string]$Text) [Console]::Error.WriteLine("warning: $Text") }
function Oops { param([string]$Text) [Console]::Error.WriteLine("error: $Text") }

# Numbered remediation list; an empty string emits a separator.
function Remedy {
    param([string[]]$Steps)
    Say ''
    [Console]::Error.WriteLine('How to fix:')
    $n = 0
    foreach ($s in $Steps) {
        if ([string]::IsNullOrEmpty($s)) { [Console]::Error.WriteLine('') }
        else { $n++; [Console]::Error.WriteLine(("  {0}. {1}" -f $n, $s)) }
    }
    Say ''
}

function Fail { param([string]$Text, [int]$Code = 1) Oops $Text; exit $Code }

function Test-HaveCommand { param([string]$Name) [bool](Get-Command $Name -ErrorAction SilentlyContinue) }

# ---- identity and paths ---------------------------------------------------

function Get-SandboxHome {
    if ($env:SANDBOX_FAKE_HOME) { return $env:SANDBOX_FAKE_HOME }
    if ($env:USERPROFILE) { return $env:USERPROFILE }
    return $HOME
}

function Get-SandboxUser {
    if ($env:SANDBOX_FAKE_USER) { return $env:SANDBOX_FAKE_USER }
    if ($env:USERNAME) { return $env:USERNAME }
    return 'user'
}

function Get-StateDir {
    if ($env:SANDBOX_STATE_DIR) { return $env:SANDBOX_STATE_DIR }
    if ($env:LOCALAPPDATA) { return (Join-Path $env:LOCALAPPDATA 'agent-sandbox') }
    return (Join-Path (Get-SandboxHome) '.agent-sandbox')
}

function Get-ManifestPath { Join-Path (Get-StateDir) "$script:Agent.manifest" }

# ---- hashing and atomic writes -------------------------------------------

function Get-StringSha256 {
    param([string]$Text)
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '' }
    finally { $sha.Dispose() }
}

# The hash an embedded asset will have once written: Write-AtomicText appends
# exactly one newline, so the raw string would never match the file.
function Get-AssetSha { param([string]$Content) Get-StringSha256 ($Content + "`n") }

function Get-FileSha {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 'missing' }
    (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLower()
}

# LF endings and no BOM: these files are read by Linux containers.
function Write-AtomicText {
    param([string]$Path, [string]$Content)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $tmp = "$Path.tmp$([System.IO.Path]::GetRandomFileName())"
    $text = ($Content -replace "`r`n", "`n") + "`n"
    [System.IO.File]::WriteAllBytes($tmp, [System.Text.UTF8Encoding]::new($false).GetBytes($text))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Backup-File {
    param([string]$Path)
    $bak = "$Path.bak.$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item -LiteralPath $Path -Destination $bak -Force
    return $bak
}

# ---- platform preflight ---------------------------------------------------

function Test-IsWindows {
    if ($env:SANDBOX_FAKE_PLATFORM) { return $env:SANDBOX_FAKE_PLATFORM -eq 'windows' }
    if ($null -ne (Get-Variable -Name IsWindows -ErrorAction SilentlyContinue)) { return $IsWindows }
    return $true   # Windows PowerShell 5.1 has no $IsWindows
}

function Assert-Windows {
    if (Test-IsWindows) { return }
    Oops "This installer is for native Windows."
    Remedy @(
        "On Linux, macOS or inside WSL, use the shell installer instead:",
        "   curl -fsSL $script:RawBase/install/$script:Agent.sh | bash"
    )
    exit $script:ExitUnsupported
}

# Docker Desktop runs Linux containers on WSL2, so a missing or v1-only WSL
# is worth naming precisely rather than letting `docker build` fail obscurely.
function Assert-Wsl2 {
    if (-not (Test-HaveCommand 'wsl.exe')) {
        Oops "WSL2 is not installed, and Docker Desktop needs it to run Linux containers."
        Remedy @(
            "Open PowerShell as Administrator and run:  wsl --install",
            "Reboot when prompted, then finish the Ubuntu first-run setup",
            "Re-run this installer in a normal (non-admin) PowerShell"
        )
        exit $script:ExitNoWsl
    }

    $listing = (& wsl.exe -l -v 2>&1 | Out-String) -replace "`0", ''
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($listing)) {
        Warn "could not query WSL distributions; continuing"
        return
    }
    # A distro line ends in its version column. Any '2' means we are fine.
    $versions = [regex]::Matches($listing, '(?m)\s(\d)\s*$') | ForEach-Object { $_.Groups[1].Value }
    if ($versions.Count -gt 0 -and ($versions -notcontains '2')) {
        Oops "WSL is installed, but every distribution is still on WSL1."
        Remedy @(
            "List your distributions:  wsl -l -v",
            "Upgrade one:  wsl --set-version <distro> 2",
            "Make it the default for new installs:  wsl --set-default-version 2",
            "Re-run this installer"
        )
        exit $script:ExitNoWsl
    }
}

function Assert-Docker {
    if (-not (Test-HaveCommand 'docker')) {
        Oops "Docker Desktop is not installed (no ``docker`` on PATH)."
        Remedy @(
            "Install it:  winget install -e --id Docker.DockerDesktop",
            "   (or download from https://www.docker.com/products/docker-desktop/)",
            "Note: Docker Desktop requires a paid subscription for larger",
            "   organisations (250+ employees or `$10M+ revenue) — check yours.",
            "Launch Docker Desktop once and let it finish starting",
            "In Settings -> General, keep 'Use the WSL 2 based engine' enabled",
            "Re-run this installer"
        )
        exit $script:ExitMissingDocker
    }

    $info = (& docker info 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) {
        Oops "Docker is installed but not responding."
        Say ''
        Say ($info.Trim() -split "`n" | Select-Object -Last 5 | Out-String).Trim()
        Remedy @(
            "Start Docker Desktop and wait for the whale icon to stop animating",
            "Verify with:  docker info",
            "Re-run this installer"
        )
        exit $script:ExitDockerUnreachable
    }

    $osType = (& docker info -f '{{.OSType}}' 2>&1 | Out-String).Trim()
    if ($osType -and $osType -ne 'linux') {
        Oops "Docker is in Windows-container mode; these images are Linux images."
        Remedy @(
            "Right-click the Docker Desktop tray icon",
            "Choose 'Switch to Linux containers...'",
            "Re-run this installer"
        )
        exit $script:ExitDockerUnreachable
    }
}

# ---- docker helpers -------------------------------------------------------

function Test-DockerImage { param([string]$Image) & docker image inspect $Image 2>&1 | Out-Null; return $LASTEXITCODE -eq 0 }
function Test-DockerVolume { param([string]$Volume) & docker volume inspect $Volume 2>&1 | Out-Null; return $LASTEXITCODE -eq 0 }

function Get-ImageLabel {
    param([string]$Image, [string]$Label)
    $v = (& docker image inspect -f "{{index .Config.Labels `"$Label`"}}" $Image 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { return '' }
    return $v
}

function New-DockerVolume {
    param([string]$Volume)
    if (Test-DockerVolume $Volume) { return }
    & docker volume create $Volume | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "could not create docker volume: $Volume" }
    Ok "created volume $Volume"
}

# The image's agent user, asked of the image rather than assumed. Windows
# builds do not pass UID args, so this is whatever the Dockerfile defaulted to.
function Get-ImageAgentUid {
    param([string]$Image)
    $uid = (& docker run --rm --entrypoint id $Image -u 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $uid -notmatch '^\d+$') { return '1001' }
    return $uid
}

# ---- manifest -------------------------------------------------------------

function Read-Manifest {
    $path = Get-ManifestPath
    $map = @{}
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $map }
    foreach ($line in Get-Content -LiteralPath $path) {
        $i = $line.IndexOf('=')
        if ($i -gt 0) { $map[$line.Substring(0, $i)] = $line.Substring($i + 1) }
    }
    return $map
}

function Get-ManifestValue {
    param([string]$Key, [string]$Default = '')
    $m = Read-Manifest
    if ($m.ContainsKey($Key)) { return $m[$Key] }
    return $Default
}

function Test-Installed { Test-Path -LiteralPath (Get-ManifestPath) -PathType Leaf }

function Write-Manifest {
    param([hashtable]$Extra = @{})
    $lines = @(
        "schema=1"
        "agent=$script:Agent"
        "installer_version=$script:InstallerVersion"
        "installed_at=$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ')"
        "src_dir=$script:SrcDirPath"
        "dockerfile=$(Join-Path $script:SrcDirPath 'Dockerfile')"
        "dockerfile_sha=$(Get-FileSha (Join-Path $script:SrcDirPath 'Dockerfile'))"
        "launcher=$(Join-Path $script:BinDirPath ($script:LauncherName + '.ps1'))"
        "launcher_sha=$(Get-FileSha (Join-Path $script:BinDirPath ($script:LauncherName + '.ps1')))"
        "bin_dir=$script:BinDirPath"
        "image=$script:Image"
    )
    foreach ($k in $Extra.Keys) { $lines += "$k=$($Extra[$k])" }
    Write-AtomicText (Get-ManifestPath) ($lines -join "`n")
}

# ---- PATH -----------------------------------------------------------------

function Get-UserPath {
    if ($env:SANDBOX_FAKE_USERPATH_FILE) {
        if (Test-Path -LiteralPath $env:SANDBOX_FAKE_USERPATH_FILE) {
            return (Get-Content -Raw -LiteralPath $env:SANDBOX_FAKE_USERPATH_FILE).Trim()
        }
        return ''
    }
    try { return [Environment]::GetEnvironmentVariable('Path', 'User') } catch { return '' }
}

function Set-UserPath {
    param([string]$Value)
    if ($env:SANDBOX_FAKE_USERPATH_FILE) {
        Set-Content -LiteralPath $env:SANDBOX_FAKE_USERPATH_FILE -Value $Value -NoNewline
        return $true
    }
    try { [Environment]::SetEnvironmentVariable('Path', $Value, 'User'); return $true }
    catch { return $false }
}

function Add-ToUserPath {
    param([string]$Dir)

    # Whether the launcher is runnable by name in THIS session is a separate
    # question from whether the persisted user PATH already lists it — and it is
    # the one that decides if the caller needs telling. Installing the second
    # agent finds the persisted PATH already correct, writes nothing, and used
    # to say nothing, leaving the launcher un-runnable with no explanation.
    if ((($env:Path -split ';') -notcontains $Dir)) {
        $script:PathNeedsReload = $true
        $script:PathExportLine  = '$env:Path = "$env:Path;' + $Dir + '"'
    }

    $current = Get-UserPath
    if ($null -eq $current) { $current = '' }
    $entries = $current -split ';' | Where-Object { $_ -ne '' }
    if ($entries -contains $Dir) { Info "$Dir is already on your PATH"; return }
    if ($script:NoPathEdit) { Warn "$Dir is not on PATH and -NoPathEdit was given"; return }
    $new = if ($current.TrimEnd(';') -eq '') { $Dir } else { $current.TrimEnd(';') + ';' + $Dir }
    if (-not (Set-UserPath $new)) {
        Warn "could not update your user PATH automatically; add $Dir by hand"
        return
    }
    $env:Path = "$env:Path;$Dir"
    Ok "added $Dir to your user PATH (new terminals pick it up automatically)"
    $script:PathWasEdited = $true
}

# ---- asset installation ---------------------------------------------------

# Never destroys local edits: a file whose hash differs from what the manifest
# recorded is backed up before being replaced.
function Install-Asset {
    param([string]$Path, [string]$Content, [string]$RecordedKey)
    $new = Get-AssetSha $Content
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $cur = Get-FileSha $Path
        if ($cur -eq $new -and -not $script:Force) {
            Info "$(Split-Path -Leaf $Path) is already current"
            return 'unchanged'
        }
        $recorded = Get-ManifestValue $RecordedKey ''
        if ($recorded -and $recorded -ne $cur) {
            $bak = Backup-File $Path
            Warn "$Path was modified locally — your version is saved as $(Split-Path -Leaf $bak)"
            Write-AtomicText $Path $Content
            Ok "updated $Path"
            return 'replaced'
        }
        Write-AtomicText $Path $Content
        Ok "updated $Path"
        return 'updated'
    }
    Write-AtomicText $Path $Content
    Ok "wrote $Path"
    return 'created'
}

function Install-AssetIfAbsent {
    param([string]$Path, [string]$Content)
    if ((Test-Path -LiteralPath $Path -PathType Leaf) -and -not $script:Force) {
        Info "keeping your $(Split-Path -Leaf $Path)"
        return 'kept'
    }
    Write-AtomicText $Path $Content
    Ok "wrote $Path"
    return 'created'
}

# ---- build ----------------------------------------------------------------

function Test-ImageCurrent {
    param([string]$WantSha)
    if (-not (Test-DockerImage $script:Image)) { return $false }
    return (Get-ImageLabel $script:Image 'sandbox.dockerfile_sha') -eq $WantSha
}

function Invoke-Build {
    param([string[]]$ExtraArgs = @())
    $wantSha = Get-FileSha (Join-Path $script:SrcDirPath 'Dockerfile')

    if ($script:NoBuild) { Warn "-NoBuild given; skipping docker build"; return }
    if ((Test-ImageCurrent $wantSha) -and -not $script:Force -and -not $script:ForceBuild) {
        Info "image $script:Image is up to date"
        return
    }
    if (-not (Test-DockerImage $script:Image)) {
        Step "Building $script:Image for the first time — this can take a few minutes"
    } elseif ($script:ForceBuild) {
        Step "Rebuilding $script:Image`: $script:ForceBuildReason — this can take a few minutes"
    } else {
        Step "Rebuilding $script:Image — this can take a few minutes"
    }

    $buildArgs = @(
        'build',
        '--label', "sandbox.dockerfile_sha=$wantSha",
        '--label', "sandbox.installer_version=$script:InstallerVersion"
    ) + $ExtraArgs + @('-t', $script:Image, $script:SrcDirPath)

    # The build stream is progress, not data: routed to stderr like every other
    # diagnostic here, so the success stream stays free for -PrintPath. Write-Host
    # would not do — with stdout redirected the host writes it there anyway.
    & docker @buildArgs | ForEach-Object { [Console]::Error.WriteLine($_) }
    if ($LASTEXITCODE -ne 0) {
        Oops "docker build failed (exit $LASTEXITCODE)"
        Remedy @(
            "Read the error above — usually a transient network failure or a full disk",
            "Re-run this installer to try again",
            "If it persists, open an issue at $script:RepoUrl/issues"
        )
        exit 1
    }
    Ok "built $script:Image"
}

# ---- confirmation ---------------------------------------------------------

function Confirm-Action {
    param([string]$Prompt)
    if ($script:Yes) { return $true }
    if ([Console]::IsInputRedirected) {
        Oops $Prompt
        Info "Not running interactively — re-run with -Yes to confirm."
        return $false
    }
    $reply = Read-Host "$Prompt [y/N]"
    return $reply -match '^(y|yes)$'
}

# ---- update check ---------------------------------------------------------

function Get-LatestVersion {
    if ($env:SANDBOX_FAKE_UPSTREAM -eq 'fail') { return '' }
    if ($env:SANDBOX_FAKE_UPSTREAM) { return $env:SANDBOX_FAKE_UPSTREAM }
    try {
        $v = (Invoke-RestMethod -Uri "$script:RawBase/VERSION" -TimeoutSec 5 -ErrorAction Stop)
        return ("$v".Trim() -split "`n")[0].Trim()
    } catch { return '' }
}

function Compare-Version {
    param([string]$A, [string]$B)   # 1 when A is newer than B
    $pa = ($A -replace '^v', '') -split '\.'
    $pb = ($B -replace '^v', '') -split '\.'
    for ($i = 0; $i -lt 4; $i++) {
        $x = 0; $y = 0
        if ($i -lt $pa.Count) { [int]::TryParse($pa[$i], [ref]$x) | Out-Null }
        if ($i -lt $pb.Count) { [int]::TryParse($pb[$i], [ref]$y) | Out-Null }
        if ($x -gt $y) { return 1 }
        if ($x -lt $y) { return -1 }
    }
    return 0
}

# ---- agent hooks (no-ops; the agent section below replaces what it needs) --

function Invoke-AgentPreBuild { }
function Invoke-AgentPostBuild { }
function Show-AgentCheckExtra { }
function Remove-AgentExtra { }
function Get-AgentBuildArgs { return @() }

# Step 0 of every agent's next-steps block: printed whenever the launcher is
# not runnable by name in the session that ran the installer.
function Write-PathStep {
    if (-not $script:PathNeedsReload) { return }
    Say "  0. Make $script:LauncherName runnable in this terminal:"
    Say "       $script:PathExportLine"
    if ($script:PathWasEdited) { Say '     New terminals pick it up automatically.' }
    Say ''
}

# The success stream's only job. Every diagnostic here goes to Write-Host or
# the error stream, so -PrintPath can hand the caller a line to apply to its
# own session:
#
#   & ([scriptblock]::Create((irm .../claude.ps1))) -PrintPath | iex
#
# Unlike the shell installers this needs an explicit switch: PowerShell's
# success stream reaches `| iex` without the process's stdout ever being
# redirected, so there is no "am I being captured" test to key off.
function Write-PathCommand {
    if (-not $script:PrintPath) { return }
    if (-not $script:PathExportLine) { return }
    Write-Output $script:PathExportLine
}

# ---- usage ----------------------------------------------------------------

function Show-Usage {
    Write-Host @"
$script:AgentName sandbox installer (v$script:InstallerVersion)

Installs a Docker sandbox for running $script:AgentName in full-autonomy mode,
where the only host path the agent can see is the directory you launch it from.

Usage
  irm $script:RawBase/install/$script:Agent.ps1 | iex

  # with options, since a piped script cannot take arguments directly:
  & ([scriptblock]::Create((irm $script:RawBase/install/$script:Agent.ps1))) -Check

Options
  -Check         Report what is installed and whether it is current; change nothing
  -Force         Reinstall/rebuild even when everything looks current
  -Uninstall     Remove the launcher, Dockerfile and image (volumes/auth survive)
  -Purge         With -Uninstall, also delete the named volumes (destroys auth)
  -Prefix DIR    Directory for the launcher (default: <home>\bin)
  -SrcDir DIR    Directory for the Dockerfile (default: <home>\$script:Agent-sandbox)
  -NoBuild       Install the files but skip the docker build
  -NoPathEdit    Never touch your user PATH
  -PrintPath     Print this session's PATH command to the success stream, so
                 piping the installer into iex makes the launcher runnable now
  -Yes           Assume yes for confirmations
  -Quiet         Only warnings and errors
  -Version       Print the installer version
  -Help          This message

Re-running the install command is the upgrade path: it rewrites only what
changed and rebuilds the image only when the Dockerfile changed.
"@
}

# ---- modes ----------------------------------------------------------------

function Invoke-Install {
    Assert-Windows
    Assert-Wsl2
    Assert-Docker

    Step "Installing the $script:AgentName sandbox (v$script:InstallerVersion)"
    $wasInstalled = Test-Installed
    if ($wasInstalled) {
        $prev = Get-ManifestValue 'installer_version' 'unknown'
        if ($prev -eq $script:InstallerVersion) { Info "already at v$prev — checking that everything matches" }
        else { Info "upgrading from v$prev to v$script:InstallerVersion" }
    }

    Install-Asset (Join-Path $script:SrcDirPath 'Dockerfile') $AssetDockerfile 'dockerfile_sha' | Out-Null
    Install-Asset (Join-Path $script:BinDirPath "$script:LauncherName.ps1") $AssetLauncher 'launcher_sha' | Out-Null
    Install-Asset (Join-Path $script:BinDirPath "$script:LauncherName.cmd") $AssetShim 'shim_sha' | Out-Null
    Add-ToUserPath $script:BinDirPath

    Invoke-AgentPreBuild
    Invoke-Build -ExtraArgs (Get-AgentBuildArgs)
    foreach ($v in $script:VolumeBasenames) { New-DockerVolume "$v-$(Get-SandboxUser)" }
    Invoke-AgentPostBuild

    Write-Manifest @{ shim_sha = (Get-FileSha (Join-Path $script:BinDirPath "$script:LauncherName.cmd")) }
    Say ''
    Step 'Done.'
    # First-run instructions are for a first run.
    if ($wasInstalled) {
        Say "  $script:AgentName sandbox is at v$script:InstallerVersion."
        Say "  $script:LauncherName --sandbox-doctor    to confirm image, volumes and versions"
        Say ''
        Write-PathStep
    } else {
        Show-NextSteps
    }
    Write-PathCommand
}

function Invoke-Check {
    $rc = 0
    Write-Host "$script:AgentName sandbox — status"
    Write-Host "  installer version   $script:InstallerVersion"
    if (-not (Test-Installed)) {
        Write-Host "  state               not installed"
        Write-Host ''
        Write-Host "Install with:  irm $script:RawBase/install/$script:Agent.ps1 | iex"
        return 1
    }
    Write-Host "  installed version   $(Get-ManifestValue 'installer_version' 'unknown')"
    Write-Host "  installed at        $(Get-ManifestValue 'installed_at' 'unknown')"

    $df = Join-Path $script:SrcDirPath 'Dockerfile'
    if (Test-Path -LiteralPath $df) {
        $cur = Get-FileSha $df
        if ($cur -eq (Get-AssetSha $AssetDockerfile)) { Write-Host "  Dockerfile          current ($df)" }
        elseif ($cur -eq (Get-ManifestValue 'dockerfile_sha' '')) { Write-Host "  Dockerfile          stale — re-run the installer"; $rc = 1 }
        else { Write-Host "  Dockerfile          locally modified ($df)"; $rc = 1 }
    } else { Write-Host "  Dockerfile          missing"; $rc = 1 }

    $lp = Join-Path $script:BinDirPath "$script:LauncherName.ps1"
    if (Test-Path -LiteralPath $lp) {
        if ((Get-FileSha $lp) -eq (Get-AssetSha $AssetLauncher)) { Write-Host "  launcher            current ($lp)" }
        else { Write-Host "  launcher            out of date ($lp)"; $rc = 1 }
    } else { Write-Host "  launcher            missing"; $rc = 1 }

    $shim = Join-Path $script:BinDirPath "$script:LauncherName.cmd"
    if (Test-Path -LiteralPath $shim) { Write-Host "  cmd shim            present" }
    else { Write-Host "  cmd shim            missing"; $rc = 1 }

    $userPath = Get-UserPath
    if ($userPath -and (($userPath -split ';') -contains $script:BinDirPath)) { Write-Host "  PATH                ok" }
    else { Write-Host "  PATH                $script:BinDirPath is not on your user PATH"; $rc = 1 }

    if (-not (Test-HaveCommand 'docker')) { Write-Host "  docker              not installed"; return 1 }
    & docker info 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host "  docker              installed but unreachable"; return 1 }
    Write-Host "  docker              ok"

    if (Test-DockerImage $script:Image) {
        if (Test-ImageCurrent (Get-FileSha $df)) { Write-Host "  image               current ($script:Image)" }
        else { Write-Host "  image               needs rebuild ($script:Image)"; $rc = 1 }
    } else { Write-Host "  image               missing ($script:Image)"; $rc = 1 }

    foreach ($v in $script:VolumeBasenames) {
        $vol = "$v-$(Get-SandboxUser)"
        if (Test-DockerVolume $vol) { Write-Host "  volume $vol present" }
        else { Write-Host "  volume $vol missing"; $rc = 1 }
    }

    Show-AgentCheckExtra

    $latest = Get-LatestVersion
    if ($latest) {
        if ((Compare-Version $latest $script:InstallerVersion) -gt 0) { Write-Host "  upstream            v$latest available"; $rc = 1 }
        else { Write-Host "  upstream            latest" }
    }

    if ($rc -ne 0) {
        Write-Host ''
        Write-Host "Re-run the installer to bring everything up to date:"
        Write-Host "  irm $script:RawBase/install/$script:Agent.ps1 | iex"
    }
    return $rc
}

function Invoke-Uninstall {
    if (-not (Test-Installed)) {
        Say "$script:AgentName sandbox is not installed. Nothing to do."
        return
    }
    Step "Removing the $script:AgentName sandbox"

    foreach ($f in @((Join-Path $script:BinDirPath "$script:LauncherName.ps1"),
                     (Join-Path $script:BinDirPath "$script:LauncherName.cmd"),
                     (Join-Path $script:SrcDirPath 'Dockerfile'))) {
        if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force; Ok "removed $f" }
    }
    Remove-AgentExtra

    if ((Test-HaveCommand 'docker') -and (Test-DockerImage $script:Image)) {
        & docker image rm $script:Image 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Ok "removed image $script:Image" }
        else { Warn "could not remove image $script:Image (a container may still be using it)" }
    }

    if ($script:Purge) {
        Say ''
        Warn "-Purge will delete these volumes, including your $script:AgentName login:"
        foreach ($v in $script:VolumeBasenames) { Say "    $v-$(Get-SandboxUser)" }
        if (Confirm-Action 'Delete them?') {
            foreach ($v in $script:VolumeBasenames) {
                $vol = "$v-$(Get-SandboxUser)"
                if (-not (Test-DockerVolume $vol)) { continue }
                & docker volume rm $vol 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) { Ok "removed volume $vol" } else { Warn "could not remove volume $vol" }
            }
        } else { Say 'Volumes kept.' }
    } else {
        Info 'volumes kept (your login survives); pass -Purge to delete them'
    }

    Remove-Item -LiteralPath (Get-ManifestPath) -Force
    Ok "removed $(Get-ManifestPath)"
}

$AssetDockerfile = @'
# Codex CLI sandbox. Same philosophy as claude-sandbox.
# NOTE: Codex has no auto-updater — version is baked at build time.
# The launcher rebuilds when a new version ships.
#
# Managed by the agent-sandbox installer (v1.3.0). Re-running the
# installer rewrites this file; local edits are backed up first.

FROM node:24-slim

ARG CODEX_VERSION=latest

RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates \
    build-essential pkg-config \
    python3 python3-pip python3-venv \
    jq ripgrep procps \
    && rm -rf /var/lib/apt/lists/*

# Docker CLI for --sandbox-docker; see the Claude Dockerfile note. Inert until
# that flag mounts the socket.
COPY --from=docker:29-cli /usr/local/bin/docker /usr/local/bin/docker
COPY --from=docker:29-cli /usr/local/libexec/docker/cli-plugins/ /usr/local/libexec/docker/cli-plugins/

ENV RUSTUP_HOME=/usr/local/rustup CARGO_HOME=/usr/local/cargo
# Downloaded to a file rather than piped into sh: a failed `curl | sh` exits 0
# because sh simply reads empty input, so a transient network blip silently
# installs nothing and only surfaces two commands later as a confusing
# "chmod: cannot access /usr/local/rustup". With && the download failure is fatal.
RUN curl -fsSL --retry 3 --retry-connrefused https://sh.rustup.rs -o /tmp/rustup-init.sh \
    && sh /tmp/rustup-init.sh -y --no-modify-path --profile minimal \
    && rm -f /tmp/rustup-init.sh \
    && chmod -R a+rX ${RUSTUP_HOME} ${CARGO_HOME}

# UID/GID must match the host user (see the Claude Dockerfile note, including
# why an already-taken UID is renamed rather than treated as an error)
ARG UID=1001
ARG GID=1001
RUN set -eux; \
    if getent group "${GID}" >/dev/null; then \
        old_group="$(getent group "${GID}" | cut -d: -f1)"; \
        [ "$old_group" = agent ] || groupmod -n agent "$old_group"; \
    else \
        groupadd -g "${GID}" agent; \
    fi; \
    if getent passwd "${UID}" >/dev/null; then \
        old_user="$(getent passwd "${UID}" | cut -d: -f1)"; \
        [ "$old_user" = agent ] || usermod -l agent "$old_user"; \
        usermod -g "${GID}" -s /bin/bash agent; \
        old_home="$(getent passwd agent | cut -d: -f6)"; \
        [ "$old_home" = /home/agent ] || usermod -d /home/agent -m agent; \
    else \
        useradd -m -s /bin/bash -u "${UID}" -g "${GID}" agent; \
    fi
USER agent
# Only the default, for a container run by hand. The launchers override it with
# `docker run -w`, mounting the project at the same path it has on the host so
# that each project keeps its own agent memory and session history.
WORKDIR /workspace

ENV CARGO_HOME=/home/agent/.cargo

RUN npm config set prefix /home/agent/.npm-global \
    && npm install -g @openai/codex@${CODEX_VERSION}

RUN mkdir -p /home/agent/.codex /home/agent/.cargo

ENV PATH=/home/agent/.npm-global/bin:/home/agent/.cargo/bin:/usr/local/cargo/bin:$PATH
'@
$AssetLauncher = @'
# codex-sandbox.ps1 — run Codex CLI sandboxed in the current directory.
#
# Installed by the agent-sandbox installer (v1.3.0):
#   irm https://raw.githubusercontent.com/mriffle/llm-cli-docker-sandbox/main/install/codex.ps1 | iex
# Edits here are backed up, not preserved, when you upgrade.
#
# Autonomy comes from ~/.codex/config.toml inside the container, not a flag.
$ErrorActionPreference = 'Stop'

$SandboxVersion = '1.3.0'
$RawBase        = 'https://raw.githubusercontent.com/mriffle/llm-cli-docker-sandbox/main'
$RepoUrl        = 'https://github.com/mriffle/llm-cli-docker-sandbox'
$Agent          = 'codex'
$AgentBin       = 'codex'
$AgentName      = 'Codex CLI'
$LauncherName   = 'codex-sandbox'

# --- shared launcher machinery (generated; see https://github.com/mriffle/llm-cli-docker-sandbox) ----------------

function Get-User {
    if ($env:SANDBOX_FAKE_USER) { return $env:SANDBOX_FAKE_USER }
    if ($env:USERNAME) { return $env:USERNAME }
    return 'user'
}

function Get-SandboxHomeDir {
    if ($env:SANDBOX_FAKE_HOME) { return $env:SANDBOX_FAKE_HOME }
    if ($env:USERPROFILE) { return $env:USERPROFILE }
    return $HOME
}

function Get-StateDirPath {
    if ($env:SANDBOX_STATE_DIR) { return $env:SANDBOX_STATE_DIR }
    if ($env:LOCALAPPDATA) { return (Join-Path $env:LOCALAPPDATA 'agent-sandbox') }
    return (Join-Path (Get-SandboxHomeDir) '.agent-sandbox')
}

function Write-Note { param([string]$Text) [Console]::Error.WriteLine("sandbox: $Text") }
function Stop-Launcher { param([string]$Text) Write-Note $Text; exit 1 }

function Compare-SandboxVersion {
    param([string]$A, [string]$B)
    $pa = ($A -replace '^v', '') -split '\.'
    $pb = ($B -replace '^v', '') -split '\.'
    for ($i = 0; $i -lt 4; $i++) {
        $x = 0; $y = 0
        if ($i -lt $pa.Count) { [int]::TryParse($pa[$i], [ref]$x) | Out-Null }
        if ($i -lt $pb.Count) { [int]::TryParse($pb[$i], [ref]$y) | Out-Null }
        if ($x -gt $y) { return 1 }
        if ($x -lt $y) { return -1 }
    }
    return 0
}

# Docker demands [a-zA-Z0-9][a-zA-Z0-9_.-]* — project directories do not.
function Get-ProjectSlug {
    $leaf = Split-Path -Leaf (Get-Location).Path
    if (-not $leaf) { $leaf = 'root' }
    return ($leaf -replace '[^a-zA-Z0-9_.-]', '-')
}

# --- where the project lives inside the container --------------------------
# Both agents key their per-project state on the working directory *string*:
# Claude Code's ~/.claude/projects/<cwd-slugified>/ (session transcripts and
# memory), its per-project approvals in .claude.json, and the cwd Codex records
# in every rollout for `codex resume`. Mount every project at a fixed
# /workspace and they are all one project to the agent. The shell launcher
# carries the full note; this is the same mechanism with Windows paths
# translated.

function Get-HostWorkdir {
    if ($env:SANDBOX_FAKE_PWD) { return $env:SANDBOX_FAKE_PWD }
    return (Get-Location).Path
}

# C:\Users\x\p -> /mnt/c/Users/x/p — the form WSL itself uses, so the same
# folder reached from PowerShell and from WSL is one project and not two. Only
# this destination is translated; the mount source keeps its native form,
# which is what Docker Desktop expects.
function ConvertTo-ContainerPath {
    param([string]$Path)
    if ($Path -match '^[A-Za-z]:') {
        $drive = $Path.Substring(0, 1).ToLower()
        $rest = ($Path.Substring(2) -replace '\\', '/').TrimStart('/')
        return "/mnt/$drive/$rest".TrimEnd('/')
    }
    if ($Path.StartsWith('\\')) {       # UNC: \\server\share\p
        $rest = ($Path.TrimStart('\') -replace '\\', '/').TrimStart('/')
        return "/mnt/unc/$rest".TrimEnd('/')
    }
    return $Path                        # already POSIX (pwsh on Linux/macOS)
}

# The mirrored path, unless it would land the mount on the container's own
# filesystem rather than in a fresh directory. Mirrors the shell launcher's
# guard list, including /home/agent — the agent's own home, which a host user
# actually named `agent` would otherwise expose in full.
# True for a container path that must not be mounted over: not absolute, one
# of the reserved directories, or the agent's own home. Shared by the project
# mount and by --sandbox-ro.
function Test-ReservedContainerPath {
    param([string]$Path)
    $reserved = @('/', '/bin', '/boot', '/dev', '/etc', '/home', '/lib', '/lib32',
                  '/lib64', '/media', '/mnt', '/opt', '/proc', '/root', '/run',
                  '/sbin', '/srv', '/sys', '/tmp', '/usr', '/var', '/home/agent')
    return ($Path -notlike '/*' -or $reserved -contains $Path -or $Path -like '/home/agent/*')
}

function Get-ContainerWorkdir {
    if ($env:SANDBOX_WORKDIR) { return $env:SANDBOX_WORKDIR }
    $p = ConvertTo-ContainerPath (Get-HostWorkdir)
    if (Test-ReservedContainerPath $p) {
        Write-Note "cannot mirror $p inside the container; using /workspace"
        Write-Note "(the agent's memory and session history there are shared with other such projects)"
        return '/workspace'
    }
    return $p
}

function Assert-DockerAndImage {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Stop-Launcher "docker is not installed or not on PATH — see $RepoUrl"
    }
    & docker image inspect $Image 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { return }
    & docker info 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Stop-Launcher "cannot reach the docker daemon — is Docker Desktop running?"
    }
    Write-Note "image $Image does not exist."
    Write-Note "install it with:  irm $RawBase/install/$Agent.ps1 | iex"
    exit 1
}

# At most one network call per day, silent when offline, and the timestamp is
# written before the request so a flaky network cannot stall every launch.
function Test-SandboxUpdate {
    if ($env:SANDBOX_NO_UPDATE_CHECK) { return }
    $dir = Get-StateDirPath
    $cache = Join-Path $dir "$Agent.lastcheck"
    try {
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        if (Test-Path -LiteralPath $cache) {
            $age = (Get-Date) - (Get-Item -LiteralPath $cache).LastWriteTime
            if ($age.TotalHours -lt 24) { return }
        }
        Set-Content -LiteralPath $cache -Value '' -NoNewline
        if ($env:SANDBOX_FAKE_UPSTREAM -eq 'fail') { return }
        elseif ($env:SANDBOX_FAKE_UPSTREAM) { $latest = $env:SANDBOX_FAKE_UPSTREAM }
        else { $latest = ("$(Invoke-RestMethod -Uri "$RawBase/VERSION" -TimeoutSec 2 -ErrorAction Stop)".Trim() -split "`n")[0].Trim() }
        if ($latest -and (Compare-SandboxVersion $latest $SandboxVersion) -gt 0) {
            Write-Note "v$latest of the sandbox is available (you have v$SandboxVersion)"
            Write-Note "upgrade with: $LauncherName --sandbox-upgrade"
        }
    } catch { return }
}

# --- git -------------------------------------------------------------------
# The mirror of git_env_args in the shell launcher; same environment, same
# host-scoped credential helper, no new mounts. See that file for why
# GIT_CONFIG_* is used rather than GIT_AUTHOR_*.

# Single-quoted on purpose: these expand in the container's shell.
$GitCredHelper = '!f(){ test "$1" = get && printf "username=%s\npassword=%s\n" "$SANDBOX_GIT_USER" "$SANDBOX_GIT_TOKEN"; }; f'

function Get-GitConfigValue {
    param([string]$Key)
    # `git config --get` exits 1 for an unset key; that is normal, not an error.
    $v = (& git config --get $Key 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { return '' }
    return $v
}

# The origin's host, https only — an ssh remote never consults a helper.
function Get-GitOriginHost {
    $url = (& git config --get remote.origin.url 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $url) { return '' }
    if ($url -notmatch '^https?://') { return '' }
    $rest = $url -replace '^https?://', ''
    $hostPart = ($rest -split '/')[0]
    return ($hostPart -replace '^.*@', '')
}

# Returns @(user, token), or @() when nothing is available.
function Get-GitCredential {
    param([string]$GitHost)
    $envToken = if ($env:GH_TOKEN) { $env:GH_TOKEN } else { $env:GITHUB_TOKEN }
    if ($GitHost -eq 'github.com' -and $envToken) { return @('x-access-token', $envToken) }

    if (Get-Command gh -ErrorAction SilentlyContinue) {
        $t = (& gh auth token --hostname $GitHost 2>$null | Out-String).Trim()
        if ($LASTEXITCODE -eq 0 -and $t) { return @('x-access-token', $t) }
    }

    # The host's own store answers — on Windows that is usually Git Credential
    # Manager. GIT_TERMINAL_PROMPT=0 keeps a missing credential from turning the
    # launch into a hang.
    $prev = $env:GIT_TERMINAL_PROMPT
    $env:GIT_TERMINAL_PROMPT = '0'
    try {
        $out = ("protocol=https`nhost=$GitHost`n`n" | & git credential fill 2>$null | Out-String)
    } catch { $out = '' } finally { $env:GIT_TERMINAL_PROMPT = $prev }

    $u = ''; $p = ''
    foreach ($line in ($out -split "`r?`n")) {
        if ($line -like 'username=*') { $u = $line.Substring(9) }
        elseif ($line -like 'password=*') { $p = $line.Substring(9) }
    }
    if ($p) { return @($u, $p) }
    return @()
}

function Get-GitEnvArgs {
    # Always an array, never $null: `@(...) + $null` inserts a phantom element.
    $envArgs = @()
    if ($env:SANDBOX_NO_GIT) { return $envArgs }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return $envArgs }

    $n = 0
    foreach ($pair in @(@('user.name', (Get-GitConfigValue 'user.name')),
                        @('user.email', (Get-GitConfigValue 'user.email')))) {
        # An empty value must never reach the array — `-e ''` becomes a real,
        # malformed argv entry.
        if ($pair[1]) {
            $envArgs += @('-e', "GIT_CONFIG_KEY_$n=$($pair[0])", '-e', "GIT_CONFIG_VALUE_$n=$($pair[1])")
            $n++
        }
    }

    if ($script:SandboxGit) {
        $gitHost = Get-GitOriginHost
        if (-not $gitHost) {
            Write-Note "--sandbox-git: no https remote here; nothing to forward"
        } else {
            $cred = Get-GitCredential $gitHost
            if ($cred.Count -eq 2) {
                $envArgs += @('-e', "SANDBOX_GIT_USER=$($cred[0])", '-e', "SANDBOX_GIT_TOKEN=$($cred[1])")
                $envArgs += @('-e', "GIT_CONFIG_KEY_$n=credential.https://$gitHost.helper",
                              '-e', "GIT_CONFIG_VALUE_$n=$GitCredHelper")
                $n++
            } else {
                Write-Note "--sandbox-git: no credential stored for $gitHost; pushing will fail"
            }
        }
    }

    if ($n -gt 0) { $envArgs += @('-e', "GIT_CONFIG_COUNT=$n") }
    return ,$envArgs
}

# --- read-only host mounts -------------------------------------------------
# The mirror of ro_mount_args in the shell launcher: --sandbox-ro PATH mounts a
# host directory or file read-only at its own path inside the container, the
# Windows path translated the way the project's is. Write access stays exactly
# the project. See that file for why the home directory and the project's
# ancestors are refused outright: read-only is not confidentiality.
$script:ReadOnlyPaths = @()       # as given on the command line, in order
$script:ReadOnlyMountArgs = @()   # -v src:dst:ro pairs, built by Get-ReadOnlyMountArgs

# The absolute host path, or '' when it is not there. SANDBOX_FAKE_RO_EXISTS is
# a test seam: the behavioural suite runs under pwsh on Linux, where a Windows
# path cannot exist, so it takes the path as given.
function Resolve-ReadOnlyPath {
    param([string]$Path)
    if ($env:SANDBOX_FAKE_RO_EXISTS) { return $Path }
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $p = (Resolve-Path -LiteralPath $Path).ProviderPath
    $p = $p.TrimEnd('\', '/')
    if ($p -match '^[A-Za-z]:$') { $p += '\' }   # a bare drive root
    if (-not $p) { $p = '/' }
    return $p
}

# The reason a resolved path cannot be mounted, or '' when it can. Comparisons
# are case-insensitive (-eq, -like), which is right for Windows paths.
function Get-ReadOnlyMountReason {
    param([string]$Src)
    $dst = ConvertTo-ContainerPath $Src
    if (Test-ReservedContainerPath $dst) { return "$Src is a system path inside the container" }
    $homeC = ConvertTo-ContainerPath (Get-SandboxHomeDir)
    if ($homeC -and ($homeC -eq $dst -or $homeC -like "$dst/*")) {
        return "$Src contains your home directory, and read-only is not confidentiality"
    }
    # The host working directory, not Get-ContainerWorkdir: SANDBOX_WORKDIR
    # moves the project's mount point, not the directory mounted writable.
    $projC = ConvertTo-ContainerPath (Get-HostWorkdir)
    if ($projC -eq $dst) { return "$Src is the project, which is already mounted writable" }
    if ($projC -like "$dst/*") { return "$Src contains the project, which is mounted writable" }
    return ''
}

function Get-ReadOnlyMountArgs {
    # Always an array, never $null, and never an empty element (see Get-GitEnvArgs).
    $roArgs = @()
    $seen = @()
    foreach ($given in $script:ReadOnlyPaths) {
        $src = Resolve-ReadOnlyPath $given
        if (-not $src) {
            # Refuse rather than let docker create the path on the host as a
            # directory and mount that.
            Stop-Launcher "--sandbox-ro: $given does not exist"
        }
        $reason = Get-ReadOnlyMountReason $src
        if ($reason) { Stop-Launcher "--sandbox-ro: $reason" }
        $dst = ConvertTo-ContainerPath $src
        if ($seen -contains $dst) { continue }
        $seen += $dst
        Write-Note "read-only: $src"
        $roArgs += @('-v', "${src}:${dst}:ro")
    }
    return ,$roArgs
}

function Invoke-Container {
    param([string[]]$Passthrough)
    $name = "$Agent-$(Get-User)-$(Get-ProjectSlug)-$([DateTimeOffset]::Now.ToUnixTimeSeconds())"
    $workdir = Get-ContainerWorkdir
    $dockerArgs = @(
        'run', '-it', '--rm',
        '--name', $name,
        '-v', "$(Get-HostWorkdir):$workdir",
        '-w', $workdir
    ) + $MountArgs + @($script:ReadOnlyMountArgs) + @(Get-GitEnvArgs) + @(
        '--cap-drop=ALL',
        '--security-opt=no-new-privileges',
        $Image, $AgentBin
    ) + $Passthrough
    & docker @dockerArgs
    exit $LASTEXITCODE
}

# Overridden by codex-sandbox.ps1, which has no self-updater to lean on.
function Invoke-PreRun { }

function Show-Doctor {
    Write-Host "$AgentName sandbox — doctor"
    Write-Host "  launcher version    $SandboxVersion"
    Write-Host "  user                $(Get-User)"
    Write-Host "  project mount       $(Get-HostWorkdir) -> $(Get-ContainerWorkdir)"
    # What --sandbox-ro would mount, or why it would refuse. Reported, never fatal.
    foreach ($given in $script:ReadOnlyPaths) {
        $src = Resolve-ReadOnlyPath $given
        if (-not $src) { Write-Host "  read-only mount     $given REFUSED — does not exist"; continue }
        $reason = Get-ReadOnlyMountReason $src
        if ($reason) { Write-Host "  read-only mount     $given REFUSED — $reason" }
        else { Write-Host "  read-only mount     $src -> $(ConvertTo-ContainerPath $src)" }
    }

    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Write-Host "  docker              NOT INSTALLED"; return
    }
    & docker info 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host "  docker              UNREACHABLE"; return }
    Write-Host "  docker              ok"

    & docker image inspect $Image 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $built = (& docker image inspect -f '{{index .Config.Labels "sandbox.installer_version"}}' $Image 2>&1 | Out-String).Trim()
        Write-Host "  image               $Image"
        Write-Host "  image built by      installer v$built"
    } else {
        Write-Host "  image               MISSING ($Image)"
    }

    foreach ($v in $Volumes) {
        & docker volume inspect $v 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Host "  volume $v ok" }
        else { Write-Host "  volume $v MISSING" }
    }

    # State recorded before the mount mirrored the host path is pooled under one
    # directory named for the old fixed mount. Nothing can attribute any of it
    # back to a project, so it is reported, never migrated.
    if ($Agent -eq 'claude') {
        & docker image inspect $Image 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            & docker run --rm --user 0:0 -v "${ConfigVol}:/v" $Image sh -c 'test -d /v/projects/-workspace' 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  legacy state        projects/-workspace holds sessions and memory recorded"
                Write-Host "                      before the mount mirrored the host path, pooled across"
                Write-Host "                      every project. Nothing is lost; list it with:"
                Write-Host "                        docker run --rm -v ${ConfigVol}:/v $Image ls /v/projects"
            }
        }
    }

    $manifest = Join-Path (Get-StateDirPath) "$Agent.manifest"
    if (Test-Path -LiteralPath $manifest) { Write-Host "  manifest            $manifest" }
    else { Write-Host "  manifest            missing (installed by hand?)" }

    # Availability only — the credential itself is never printed.
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Host "  git                 NOT INSTALLED on this host"
    } else {
        $n = Get-GitConfigValue 'user.name'
        $e = Get-GitConfigValue 'user.email'
        if ($n -or $e) {
            $nn = if ($n) { $n } else { '?' }
            $ee = if ($e) { $e } else { '?' }
            Write-Host "  git identity        $nn <$ee>"
        } else {
            Write-Host "  git identity        NONE configured — commits will fail"
        }
        $gitHost = Get-GitOriginHost
        if (-not $gitHost) {
            Write-Host "  git credential      no https remote here"
        } elseif ((Get-GitCredential $gitHost).Count -eq 2) {
            Write-Host "  git credential      available for $gitHost — forward with --sandbox-git"
        } else {
            Write-Host "  git credential      none stored for $gitHost"
        }
    }

    try {
        if ($env:SANDBOX_FAKE_UPSTREAM -eq 'fail') { return }
        $latest = if ($env:SANDBOX_FAKE_UPSTREAM) { $env:SANDBOX_FAKE_UPSTREAM }
                  else { ("$(Invoke-RestMethod -Uri "$RawBase/VERSION" -TimeoutSec 3 -ErrorAction Stop)".Trim() -split "`n")[0].Trim() }
        if ($latest -and (Compare-SandboxVersion $latest $SandboxVersion) -gt 0) {
            Write-Host "  upstream            v$latest available — $LauncherName --sandbox-upgrade"
        } elseif ($latest) {
            Write-Host "  upstream            up to date"
        }
    } catch { }
}

function Invoke-Upgrade {
    param([string[]]$Passthrough)
    Write-Note "fetching the latest installer from $RawBase"
    $script = Invoke-RestMethod -Uri "$RawBase/install/$Agent.ps1"
    & ([scriptblock]::Create($script)) @Passthrough
    exit $LASTEXITCODE
}

function Show-LauncherUsage {
    Write-Host @"
$LauncherName — run $AgentName sandboxed in the current directory (v$SandboxVersion)

  $LauncherName [agent arguments...]

Everything is passed through to $AgentBin untouched, except these flags,
which are only recognised in first position:

  --sandbox-git [args...]            also forward a git credential (see below)
  --sandbox-ro PATH [args...]        also mount PATH read-only, repeatable (see below)
  --sandbox-doctor                   report on image, volumes and versions
  --sandbox-upgrade [installer opts] re-run the installer to update
  --sandbox-version                  print the sandbox version
  --sandbox-help                     this message

Your git name and email are always passed through, so the agent can commit.
--sandbox-git additionally forwards a credential for the origin remote's host,
so it can push. That credential is scoped to that one host, but within it the
token's own permissions apply — prefer a fine-grained one.

--sandbox-ro PATH (or --sandbox-ro=PATH) mounts a host directory or file into
the session read-only, at the same path it has on the host (C:\data becomes
/mnt/c/data, like the project). Repeat it for more. Relative paths resolve
against the current directory. Write access stays exactly the project, so a
path that is the project or contains it is refused, as is a path that does not
exist, a system path, and your home directory or anything above it: read-only
is not confidentiality, and egress is open. A path inside the project works,
and pins that part of the project read-only.

There is no --sandbox-tmux on native Windows; for detachable sessions, run
the sandbox from WSL instead (see WINDOWS.md, Route A). Nor is there a
--sandbox-docker: Docker Desktop's daemon cannot resolve this container's
/mnt/c/... paths, so bind mounts made inside the session would be empty. That
route works from WSL2 too.

The project is mounted inside the container at the same path it has on the
host (C:\Users\you\repo becomes /mnt/c/Users/you/repo), so each project keeps
its own agent memory, session history and approvals. SANDBOX_WORKDIR overrides
that if you need the old fixed path.

Environment:
  SANDBOX_NO_UPDATE_CHECK=1   never check upstream for a newer sandbox
  SANDBOX_NO_GIT=1            pass no git identity or credential at all
  SANDBOX_GIT=1               same as --sandbox-git
  SANDBOX_WORKDIR=/workspace  mount the project at this fixed path instead
                              (its agent state is then shared with every
                              other project run the same way)
"@
}

function Invoke-LauncherMain {
    $rest = @($args)
    # Consumed before the dispatch below, so the flags compose in any order and
    # still only count at the front: the loop stops at the first argument that
    # is not one of them, and everything after reaches the agent untouched.
    $script:SandboxGit = [bool]$env:SANDBOX_GIT
    $script:ReadOnlyPaths = @()
    while ($rest.Count -gt 0) {
        $a = $rest[0]
        if ($a -eq '--sandbox-git') {
            $script:SandboxGit = $true
            $rest = @($rest | Select-Object -Skip 1)
        } elseif ($a -eq '--sandbox-ro') {
            if ($rest.Count -lt 2) { Stop-Launcher "--sandbox-ro needs a path" }
            $script:ReadOnlyPaths += $rest[1]
            $rest = @($rest | Select-Object -Skip 2)
        } elseif ($a -like '--sandbox-ro=*') {
            $script:ReadOnlyPaths += $a.Substring(13)
            $rest = @($rest | Select-Object -Skip 1)
        } elseif ($a -eq '--sandbox-docker') {
            # There is no Docker-out-of-Docker on this route. Docker Desktop's
            # daemon runs in a Linux VM that cannot resolve this container's
            # /mnt/c/... paths, so a bind mount issued from inside the session
            # would silently mount an empty directory instead of the project —
            # a wrong answer, not an error. Under WSL2 the daemon and the
            # container agree on paths, and it works.
            Write-Note "--sandbox-docker is not supported on native Windows."
            Write-Note "  Docker Desktop's daemon runs in a Linux VM that cannot resolve this"
            Write-Note "  container's /mnt/c/... paths, so bind mounts made inside the session"
            Write-Note "  would silently be empty. Run the sandbox from WSL2 instead, where the"
            Write-Note "  daemon and the container agree on paths — see WINDOWS.md, Route A."
            exit 1
        } else { break }
    }
    if ($env:SANDBOX_DOCKER) {
        Write-Note "SANDBOX_DOCKER is set, but is ignored on native Windows; see WINDOWS.md"
    }

    $first = if ($rest.Count -gt 0) { $rest[0] } else { '' }
    switch ($first) {
        '--sandbox-help'    { Show-LauncherUsage; exit 0 }
        '--sandbox-version' { Write-Host $SandboxVersion; exit 0 }
        '--sandbox-doctor'  { Show-Doctor; exit 0 }
        '--sandbox-upgrade' { Invoke-Upgrade -Passthrough @($rest | Select-Object -Skip 1) }
    }
    # Resolve and refuse before anything slow or stateful (the image check, a
    # Codex rebuild): a bad path should fail at the prompt.
    $script:ReadOnlyMountArgs = @(Get-ReadOnlyMountArgs)
    Assert-DockerAndImage
    Test-SandboxUpdate
    Invoke-PreRun
    Invoke-Container -Passthrough $rest
}

$Image     = "codex-sandbox-$(Get-User)"
$ConfigVol = "codex-config-$(Get-User)"
$Volumes   = @($ConfigVol)
$MountArgs = @('-v', "${ConfigVol}:/home/agent/.codex")

function Get-CodexSrcDir {
    if ($env:CODEX_SANDBOX_SRC) { return $env:CODEX_SANDBOX_SRC }
    $manifest = Join-Path (Get-StateDirPath) 'codex.manifest'
    if (Test-Path -LiteralPath $manifest) {
        foreach ($line in Get-Content -LiteralPath $manifest) {
            if ($line -like 'src_dir=*') { return $line.Substring(8) }
        }
    }
    return (Join-Path (Get-SandboxHomeDir) 'codex-sandbox')
}

# Codex has no self-updater, so the launcher is where updates happen: ask the
# npm registry and rebuild only when the version actually changed, tracked by
# an image label so an up-to-date launch does no work at all.
function Invoke-PreRun {
    $latest = ''
    try {
        if ($env:SANDBOX_FAKE_NPM -eq 'fail') { throw 'npm unreachable' }
        elseif ($env:SANDBOX_FAKE_NPM) { $latest = $env:SANDBOX_FAKE_NPM }
        else { $latest = "$((Invoke-RestMethod -Uri 'https://registry.npmjs.org/@openai/codex/latest' -TimeoutSec 5 -ErrorAction Stop).version)".Trim() }
    } catch {
        Write-Note "npm version check failed; running the existing image"
        return
    }
    if (-not $latest) { return }

    $current = (& docker image inspect -f '{{index .Config.Labels "codex_version"}}' $Image 2>&1 | Out-String).Trim()
    if ($current -eq $latest) { return }

    $src = Get-CodexSrcDir
    if (-not (Test-Path -LiteralPath (Join-Path $src 'Dockerfile'))) {
        Write-Note "Codex $latest is available but no Dockerfile at $src; running the existing image"
        return
    }

    Write-Note "Codex $latest available (have: $(if ($current) { $current } else { 'none' })); rebuilding — this can take a minute..."
    $sha = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $src 'Dockerfile')).Hash.ToLower()
    & docker build -q `
        --build-arg "CODEX_VERSION=$latest" `
        --label "codex_version=$latest" `
        --label "sandbox.dockerfile_sha=$sha" `
        --label "sandbox.installer_version=$SandboxVersion" `
        -t $Image $src | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Note "now on Codex $latest" }
    else { Write-Note "rebuild failed; running the existing image" }
}

Invoke-LauncherMain @args
'@
$AssetShim = @'
@echo off
rem Shim so `codex-sandbox` works from cmd.exe and never trips execution policy.
rem Installed by the agent-sandbox installer (v1.3.0).
setlocal
set "SANDBOX_PS1=%~dp0codex-sandbox.ps1"
where pwsh >nul 2>nul
if %ERRORLEVEL%==0 (
  pwsh -NoProfile -ExecutionPolicy Bypass -File "%SANDBOX_PS1%" %*
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%SANDBOX_PS1%" %*
)
exit /b %ERRORLEVEL%
'@
$AssetConfigToml = @'
# Codex autonomy inside the container. The container is the security
# boundary, so Codex's own OS-level sandbox is turned off and approvals
# are disabled. Seeded by the agent-sandbox installer (v1.3.0);
# your edits here are preserved across upgrades.
approval_policy = "never"
sandbox_mode = "danger-full-access"
'@

$script:CodexVersion = ''

function Invoke-AgentPreBuild {
    Install-AssetIfAbsent (Join-Path $script:SrcDirPath 'config.toml') $AssetConfigToml | Out-Null
    try {
        if ($env:SANDBOX_FAKE_NPM -eq 'fail') { throw 'npm unreachable' }
        elseif ($env:SANDBOX_FAKE_NPM) { $script:CodexVersion = $env:SANDBOX_FAKE_NPM }
        else {
            $script:CodexVersion = "$((Invoke-RestMethod -Uri 'https://registry.npmjs.org/@openai/codex/latest' -TimeoutSec 10 -ErrorAction Stop).version)".Trim()
        }
    } catch {
        Warn 'could not reach the npm registry; building with CODEX_VERSION=latest'
        $script:CodexVersion = ''
    }
    if (-not $script:CodexVersion) { return }
    Info "pinning Codex $script:CodexVersion into the image"
    # Re-running the installer is the documented upgrade path, so it has to
    # cover the Codex release too — not just the Dockerfile.
    if (Test-DockerImage $script:Image) {
        $current = Get-ImageLabel $script:Image 'codex_version'
        if ($current -and $current -ne $script:CodexVersion) {
            $script:ForceBuild = $true
            $script:ForceBuildReason = "Codex $current -> $script:CodexVersion"
        }
    }
}

function Get-AgentBuildArgs {
    if (-not $script:CodexVersion) { return @() }
    return @('--build-arg', "CODEX_VERSION=$script:CodexVersion", '--label', "codex_version=$script:CodexVersion")
}

# The failure this repo has hit most: a config.toml (or a whole volume) left
# root-owned, after which Codex cannot open its state DB. Docker Desktop hides
# ownership for Windows bind mounts, but named volumes are real Linux
# filesystems, so this still matters on this route.
function Invoke-AgentPostBuild {
    $vol = "codex-config-$(Get-SandboxUser)"
    if ($script:NoBuild -and -not (Test-DockerImage $script:Image)) {
        Warn 'skipping config.toml seeding (no image available)'
        return
    }
    $uid = Get-ImageAgentUid $script:Image
    $cfg = Join-Path $script:SrcDirPath 'config.toml'

    Step "Seeding config.toml into $vol"
    & docker run --rm --user 0:0 -v "${vol}:/cfg" $script:Image test -f /cfg/config.toml 2>&1 | Out-Null
    $present = ($LASTEXITCODE -eq 0)

    if ($script:Force -or -not $present) {
        & docker run --rm --user 0:0 -v "${vol}:/cfg" -v "${cfg}:/src/config.toml:ro" `
            $script:Image cp /src/config.toml /cfg/config.toml 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Warn "could not seed config.toml into $vol — Codex may prompt for approvals"
            return
        }
        Ok 'seeded config.toml'
    } else {
        Info 'config.toml already present in the volume — left alone'
    }

    & docker run --rm --user 0:0 -v "${vol}:/cfg" $script:Image chown -R "${uid}:${uid}" /cfg 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Ok "volume contents owned by $uid (the image's agent user)" }
    else { Warn "could not set ownership on $vol; see the troubleshooting notes in MANUAL.md" }
}

function Show-AgentCheckExtra {
    $cfg = Join-Path $script:SrcDirPath 'config.toml'
    if (Test-Path -LiteralPath $cfg) { Write-Host "  config.toml         present ($cfg)" }
    else { Write-Host "  config.toml         missing" }
    if (Test-DockerImage $script:Image) {
        $v = Get-ImageLabel $script:Image 'codex_version'
        if (-not $v) { $v = 'unknown (built without a pin)' }
        Write-Host "  codex in image      $v"
    }
}

function Remove-AgentExtra {
    $cfg = Join-Path $script:SrcDirPath 'config.toml'
    if (Test-Path -LiteralPath $cfg) { Remove-Item -LiteralPath $cfg -Force; Ok "removed $cfg" }
}

function Show-NextSteps {
    Say ''
    Say 'Next steps'
    Write-PathStep
    Say '  1. Log in once — device code, approve at chatgpt.com from any device:'
    Say '       cd C:\code\some-project'
    Say '       codex-sandbox login --device-auth'
    Say ''
    Say '  2. Daily use, from any project directory (no flag needed — autonomy'
    Say '     comes from config.toml):'
    Say '       codex-sandbox'
    Say ''
    Say '  codex-sandbox --sandbox-help    for the sandbox-specific flags'
    Say "  $script:RepoUrl"
}

function Invoke-Main {
    if ($Help)    { Show-Usage; exit 0 }
    if ($Version) { Write-Host $script:InstallerVersion; exit 0 }

    $script:Force      = [bool]$Force
    $script:Yes        = [bool]$Yes
    $script:Purge      = [bool]$Purge
    $script:NoBuild    = [bool]$NoBuild
    $script:NoPathEdit = [bool]$NoPathEdit
    $script:Quiet      = [bool]$Quiet
    $script:PathWasEdited = $false
    $script:PrintPath = [bool]$PrintPath
    $script:PathNeedsReload = $false
    $script:PathExportLine = ''
    $script:ForceBuild = $false
    $script:ForceBuildReason = ''

    $home_ = Get-SandboxHome
    $script:BinDirPath = if ($Prefix) { $Prefix } else { Join-Path $home_ 'bin' }
    $script:SrcDirPath = if ($SrcDir) { $SrcDir } else { Join-Path $home_ 'codex-sandbox' }
    $script:Image      = "$script:ImageBasename-$(Get-SandboxUser)"

    if ($Check)     { exit (Invoke-Check) }
    if ($Uninstall) { Invoke-Uninstall; exit 0 }
    Invoke-Install
}

Invoke-Main
