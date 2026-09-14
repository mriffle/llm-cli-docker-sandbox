# --- shared launcher machinery (generated; see @@REPO_URL@@) ----------------

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
