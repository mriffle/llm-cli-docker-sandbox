#!/usr/bin/env bats
# The generated PowerShell installers and launchers, driven under pwsh with
# the same fake docker the shell suite uses. Runs on Linux and on Windows.

load '../helper'

setup() {
    common_setup
    if [ -x "$REPO_ROOT/.bin/pwsh" ]; then PWSH="$REPO_ROOT/.bin/pwsh"
    elif command -v pwsh >/dev/null 2>&1; then PWSH=$(command -v pwsh)
    else skip "pwsh not available (run tools/fetch-tools.sh --with-pwsh)"; fi

    export SANDBOX_FAKE_PLATFORM=windows
    export SANDBOX_FAKE_HOME="$HOME"
    export SANDBOX_FAKE_USER=testuser
    export SANDBOX_STATE_DIR="$HOME/state"
    export SANDBOX_FAKE_USERPATH_FILE="$TESTDIR/userpath"
    export SANDBOX_FAKE_UPSTREAM=fail
    export SANDBOX_FAKE_NPM=1.2.3
    export FAKE_DOCKER_ARGV="$TESTDIR/docker.argv"
    : > "$FAKE_DOCKER_ARGV"
    DF="$HOME/claude-sandbox/Dockerfile"
    LAUNCHER="$HOME/bin/claude-sandbox.ps1"
    SHIM="$HOME/bin/claude-sandbox.cmd"
    MANIFEST="$HOME/state/claude.manifest"
}
teardown() { common_teardown; }

ps_install() {
    local agent=$1; shift
    run "$PWSH" -NoProfile -File "$REPO_ROOT/install/$agent.ps1" "$@"
}

# --- preflight -------------------------------------------------------------

@test "ps: refuses to run on a non-Windows host and points at the shell script" {
    SANDBOX_FAKE_PLATFORM=linux ps_install claude
    assert_status 78
    assert_output_contains 'for native Windows'
    assert_output_contains 'install/claude.sh | bash'
}

@test "ps: missing WSL gives the elevated wsl --install instruction" {
    PATH="$(path_without wsl.exe)" ps_install claude
    assert_status 12
    assert_output_contains 'WSL2 is not installed'
    assert_output_contains 'wsl --install'
    assert_output_contains 'PowerShell as Administrator'
}

@test "ps: WSL1-only distributions are named and the upgrade command given" {
    FAKE_WSL_MODE=v1 ps_install claude
    assert_status 12
    assert_output_contains 'still on WSL1'
    assert_output_contains 'wsl --set-version'
}

@test "ps: missing Docker Desktop gives the winget command and the licensing note" {
    PATH="$(path_without docker)" ps_install claude
    assert_status 10
    assert_output_contains 'winget install -e --id Docker.DockerDesktop'
    assert_output_contains 'paid subscription'
}

@test "ps: an unreachable daemon is reported as such" {
    FAKE_DOCKER_INFO_RC=1 ps_install claude
    assert_status 11
    assert_output_contains 'not responding'
    assert_output_contains 'Start Docker Desktop'
}

@test "ps: Windows-container mode is diagnosed precisely and changes nothing" {
    # Mirrors the assertion the windows-latest CI job makes on a real runner,
    # where Docker genuinely is in Windows-container mode.
    FAKE_DOCKER_OSTYPE=windows ps_install claude -NoBuild
    assert_status 11
    assert_output_contains 'Windows-container mode'
    assert_output_contains 'Switch to Linux containers'
    # It must refuse before writing anything at all.
    assert_file_missing "$DF"
    assert_file_missing "$LAUNCHER"
    assert_file_missing "$SHIM"
    assert_file_missing "$MANIFEST"
    refute_docker_ran 'docker build'
}

@test "ps: codex also refuses in Windows-container mode" {
    FAKE_DOCKER_OSTYPE=windows ps_install codex -NoBuild
    assert_status 11
    assert_output_contains 'Switch to Linux containers'
    assert_file_missing "$HOME/codex-sandbox/Dockerfile"
}

# --- install ---------------------------------------------------------------

@test "ps: fresh install writes the Dockerfile, launcher and cmd shim" {
    ps_install claude
    assert_success
    assert_file_exists "$DF"
    assert_file_exists "$LAUNCHER"
    assert_file_exists "$SHIM"
    assert_file_exists "$MANIFEST"
    assert_file_contains "$DF" 'FROM node:24-slim'
    assert_file_contains "$SHIM" 'ExecutionPolicy Bypass'
}

@test "ps: the Dockerfile is written with LF endings and no BOM" {
    ps_install claude
    assert_success
    run bash -c "head -c 3 '$DF' | od -An -tx1 | tr -d ' '"
    [ "$output" != "efbbbf" ]
    refute_file_contains "$DF" $'\r'
}

@test "ps: no UID build args on this route, but the freshness labels are set" {
    ps_install claude
    assert_success
    assert_docker_ran '-t claude-sandbox-testuser'
    assert_docker_ran 'sandbox.dockerfile_sha='
    refute_docker_ran '--build-arg UID='
}

@test "ps: both volumes are created, namespaced per user" {
    ps_install claude
    assert_docker_ran 'volume create claude-config-testuser'
    assert_docker_ran 'volume create claude-local-testuser'
}

@test "ps: the bin directory is added to the user PATH exactly once" {
    ps_install claude
    assert_success
    assert_file_contains "$SANDBOX_FAKE_USERPATH_FILE" "$HOME/bin"
    ps_install claude
    [ "$(tr ';' '\n' < "$SANDBOX_FAKE_USERPATH_FILE" | grep -c "^$HOME/bin$")" -eq 1 ]
}

@test "ps: says how to make the launcher runnable in this session" {
    ps_install claude
    assert_success
    assert_output_contains 'Make claude-sandbox runnable in this terminal'
    assert_output_contains '$env:Path = "$env:Path;'
}

# The persisted user PATH is already correct by the time the second agent is
# installed; the session's PATH is not. Keying off the wrong one is what left
# the second launcher un-runnable with nothing said about it.
@test "ps: installing the second agent still explains how to run it now" {
    ps_install claude
    assert_success
    ps_install codex
    assert_success
    assert_output_contains 'Make codex-sandbox runnable in this terminal'
}

# PowerShell's success stream reaches `| iex` without the process's stdout ever
# being redirected, so unlike the shell installers this needs an explicit
# switch rather than an is-it-captured test.
@test "ps: -PrintPath puts the session PATH command on the success stream" {
    local out
    out=$("$PWSH" -NoProfile -File "$REPO_ROOT/install/claude.ps1" -PrintPath 2>/dev/null)
    case "$out" in
        '$env:Path = "$env:Path;'*"$HOME/bin"'"') ;;
        *) fail_with "unexpected success-stream output: [$out]" ;;
    esac
}

@test "ps: without -PrintPath the success stream stays empty" {
    local out
    out=$("$PWSH" -NoProfile -File "$REPO_ROOT/install/claude.ps1" 2>/dev/null)
    [ -z "$out" ] || fail_with "expected empty success stream, got: [$out]"
}

@test "ps: re-running changes nothing and does not rebuild" {
    ps_install claude
    : > "$FAKE_DOCKER_LOG"
    ps_install claude
    assert_success
    assert_output_contains 'is already current'
    assert_output_contains 'is up to date'
    refute_docker_ran 'docker build'
}

@test "ps: upgrade rewrites the Dockerfile and rebuilds" {
    ps_install claude
    sed -e "s/^\\\$script:InstallerVersion = '[^']*'/\$script:InstallerVersion = '9.9.9'/" \
        -e 's/    jq ripgrep procps/    jq ripgrep procps fd-find/' \
        "$REPO_ROOT/install/claude.ps1" > "$TESTDIR/v2.ps1"
    grep -q 'fd-find' "$TESTDIR/v2.ps1"
    : > "$FAKE_DOCKER_LOG"
    run "$PWSH" -NoProfile -File "$TESTDIR/v2.ps1"
    assert_success
    assert_output_contains 'upgrading from v'
    assert_file_contains "$DF" 'fd-find'
    assert_docker_ran 'docker build'
}

@test "ps: a hand-edited Dockerfile is backed up rather than discarded" {
    ps_install claude
    printf 'FROM my-own-base\n' > "$DF"
    sed -e 's/    jq ripgrep procps/    jq ripgrep procps fd-find/' \
        "$REPO_ROOT/install/claude.ps1" > "$TESTDIR/v2.ps1"
    run "$PWSH" -NoProfile -File "$TESTDIR/v2.ps1"
    assert_success
    assert_output_contains 'was modified locally'
    [ -f "$HOME"/claude-sandbox/Dockerfile.bak.* ]
}

@test "ps: a failed build exits non-zero and records no install" {
    FAKE_DOCKER_BUILD_RC=4 ps_install claude
    assert_failure
    assert_output_contains 'docker build failed'
    assert_file_missing "$MANIFEST"
}

# --- check and uninstall ---------------------------------------------------

@test "ps: -Check reports not installed, then reports everything current" {
    ps_install claude -Check
    assert_status 1
    assert_output_contains 'not installed'
    ps_install claude
    ps_install claude -Check
    assert_success
    assert_output_contains 'Dockerfile          current'
    assert_output_contains 'cmd shim            present'
    assert_output_contains 'PATH                ok'
}

@test "ps: -Uninstall keeps the volumes, -Purge -Yes removes them" {
    ps_install claude
    ps_install claude -Uninstall
    assert_success
    assert_file_missing "$LAUNCHER"
    assert_file_missing "$SHIM"
    assert_file_missing "$MANIFEST"
    refute_docker_ran 'volume rm'
    ps_install claude
    ps_install claude -Uninstall -Purge -Yes
    assert_docker_ran 'volume rm claude-config-testuser'
}

@test "ps: -Help and -Version touch nothing" {
    ps_install claude -Version
    assert_success
    assert_output_contains "$(cat "$REPO_ROOT/VERSION")"
    ps_install claude -Help
    assert_success
    assert_output_contains 'scriptblock'
    assert_file_missing "$DF"
}

@test "ps: -Prefix and -SrcDir are honoured" {
    ps_install claude -Prefix "$TESTDIR/mybin" -SrcDir "$TESTDIR/mysrc"
    assert_success
    assert_file_exists "$TESTDIR/mybin/claude-sandbox.ps1"
    assert_file_exists "$TESTDIR/mysrc/Dockerfile"
    assert_file_missing "$DF"
}

# --- codex -----------------------------------------------------------------

@test "ps: codex install seeds config.toml and normalises volume ownership" {
    ps_install codex
    assert_success
    assert_file_exists "$HOME/codex-sandbox/config.toml"
    assert_output_contains 'seeded config.toml'
    assert_output_contains "owned by 1001"
    assert_docker_ran '--user 0:0'
    grep -q 'config.toml' "$FAKE_DOCKER_STATE/volumes/codex-config-testuser.files"
}

@test "ps: codex pins the npm version into the image" {
    SANDBOX_FAKE_NPM=0.44.0 ps_install codex
    assert_success
    assert_output_contains 'pinning Codex 0.44.0'
    assert_docker_ran '--build-arg CODEX_VERSION=0.44.0'
}

@test "ps: codex survives an unreachable npm registry" {
    SANDBOX_FAKE_NPM=fail ps_install codex
    assert_success
    assert_output_contains 'could not reach the npm registry'
    assert_file_exists "$HOME/state/codex.manifest"
}

@test "ps: a user-edited config.toml is kept" {
    ps_install codex
    printf 'approval_policy = "on-request"\n' > "$HOME/codex-sandbox/config.toml"
    ps_install codex
    assert_output_contains 'keeping your config.toml'
    assert_file_contains "$HOME/codex-sandbox/config.toml" 'on-request'
}

# --- launcher --------------------------------------------------------------

@test "ps launcher: mounts the current directory and the right volumes" {
    ps_install claude
    mkdir -p "$TESTDIR/proj"
    cd "$TESTDIR/proj"
    # PowerShell reports the *physical* working directory, so on macOS this is
    # the /private/var form. (The shell launcher now agrees; it used to mount
    # bash's logical $PWD. See launcher.bats.)
    local here; here=$(pwd -P)
    : > "$FAKE_DOCKER_ARGV"
    run "$PWSH" -NoProfile -File "$LAUNCHER" --dangerously-skip-permissions
    assert_success
    grep -qxF -- "$here:$here" "$FAKE_DOCKER_ARGV"
    grep -qxF -- "-w" "$FAKE_DOCKER_ARGV"
    grep -qxF -- "claude-config-testuser:/home/agent/.claude" "$FAKE_DOCKER_ARGV"
    grep -qxF -- "--dangerously-skip-permissions" "$FAKE_DOCKER_ARGV"
    grep -qxF -- "--cap-drop=ALL" "$FAKE_DOCKER_ARGV"
}

# --- one mount point would be one project identity -------------------------
# The launcher mirrors the host path so each project keeps its own agent memory
# and session history. A Windows path is not a Linux path, so it is translated
# to the form WSL uses — which also means the same folder reached from
# PowerShell and from WSL is one project, not two. This job usually runs under
# pwsh on Linux, where Get-Location is already POSIX, so the translation is
# driven through SANDBOX_FAKE_PWD.

@test "ps launcher: a Windows path is mirrored as /mnt/<drive>" {
    ps_install claude
    : > "$FAKE_DOCKER_ARGV"
    SANDBOX_FAKE_PWD='C:\Users\mike\dev\my project' \
        run "$PWSH" -NoProfile -File "$LAUNCHER"
    assert_success
    # The source keeps its native form; only the destination is translated.
    grep -qxF -- 'C:\Users\mike\dev\my project:/mnt/c/Users/mike/dev/my project' "$FAKE_DOCKER_ARGV" \
        || fail_with "expected the mirrored mount; argv was: $(cat "$FAKE_DOCKER_ARGV")"
    grep -qxF -- '/mnt/c/Users/mike/dev/my project' "$FAKE_DOCKER_ARGV" \
        || fail_with "expected -w to carry the same path"
}

@test "ps launcher: a UNC path gets its own namespace" {
    ps_install claude
    : > "$FAKE_DOCKER_ARGV"
    SANDBOX_FAKE_PWD='\\srv\share\repo' run "$PWSH" -NoProfile -File "$LAUNCHER"
    assert_success
    grep -qxF -- '\\srv\share\repo:/mnt/unc/srv/share/repo' "$FAKE_DOCKER_ARGV" \
        || fail_with "expected a UNC mirror; argv was: $(cat "$FAKE_DOCKER_ARGV")"
}

@test "ps launcher: two Windows directories get two container paths" {
    ps_install claude
    : > "$FAKE_DOCKER_ARGV"
    SANDBOX_FAKE_PWD='C:\dev\alpha' run "$PWSH" -NoProfile -File "$LAUNCHER"
    assert_success
    grep -qxF -- '/mnt/c/dev/alpha' "$FAKE_DOCKER_ARGV"
    : > "$FAKE_DOCKER_ARGV"
    SANDBOX_FAKE_PWD='C:\dev\beta' run "$PWSH" -NoProfile -File "$LAUNCHER"
    assert_success
    grep -qxF -- '/mnt/c/dev/beta' "$FAKE_DOCKER_ARGV"
    grep -qxF -- '/mnt/c/dev/alpha' "$FAKE_DOCKER_ARGV" \
        && fail_with "the second launch reused the first project's path"
    return 0
}

@test "ps launcher: SANDBOX_WORKDIR pins the old fixed mount" {
    ps_install claude
    : > "$FAKE_DOCKER_ARGV"
    SANDBOX_WORKDIR=/workspace SANDBOX_FAKE_PWD='C:\dev\alpha' \
        run "$PWSH" -NoProfile -File "$LAUNCHER"
    assert_success
    grep -qxF -- 'C:\dev\alpha:/workspace' "$FAKE_DOCKER_ARGV"
}

@test "ps launcher: a directory that cannot be mirrored falls back and says so" {
    ps_install claude
    : > "$FAKE_DOCKER_ARGV"
    SANDBOX_FAKE_PWD=/home/agent run "$PWSH" -NoProfile -File "$LAUNCHER"
    assert_success
    assert_output_contains 'cannot mirror /home/agent'
    grep -qxF -- '/home/agent:/workspace' "$FAKE_DOCKER_ARGV"
}

@test "ps launcher: --sandbox-version and --sandbox-help start no container" {
    ps_install claude
    : > "$FAKE_DOCKER_LOG"
    run "$PWSH" -NoProfile -File "$LAUNCHER" --sandbox-version
    assert_success
    assert_output_contains "$(cat "$REPO_ROOT/VERSION")"
    run "$PWSH" -NoProfile -File "$LAUNCHER" --sandbox-help
    assert_success
    assert_output_contains 'no --sandbox-tmux on native Windows'
    refute_docker_ran 'docker run'
}

@test "ps launcher: --sandbox-doctor reports image and volumes" {
    ps_install claude
    run "$PWSH" -NoProfile -File "$LAUNCHER" --sandbox-doctor
    assert_success
    assert_output_contains 'claude-sandbox-testuser'
    assert_output_contains 'volume claude-config-testuser ok'
}

@test "ps launcher: a missing image tells you to run the installer" {
    ps_install claude
    rm -f "$FAKE_DOCKER_STATE/images/claude-sandbox-testuser.labels"
    run "$PWSH" -NoProfile -File "$LAUNCHER"
    assert_failure
    assert_output_contains 'does not exist'
    assert_output_contains 'install/claude.ps1 | iex'
}

@test "ps launcher: a newer upstream version produces a nudge" {
    ps_install claude
    mkdir -p "$TESTDIR/proj"; cd "$TESTDIR/proj"
    SANDBOX_NO_UPDATE_CHECK= SANDBOX_FAKE_UPSTREAM=99.0.0 run "$PWSH" -NoProfile -File "$LAUNCHER"
    assert_success
    assert_output_contains 'of the sandbox is available'
}

@test "ps launcher: the nudge is checked at most once a day" {
    ps_install claude
    mkdir -p "$TESTDIR/proj"; cd "$TESTDIR/proj"
    SANDBOX_NO_UPDATE_CHECK= SANDBOX_FAKE_UPSTREAM=99.0.0 run "$PWSH" -NoProfile -File "$LAUNCHER"
    assert_output_contains 'is available'
    SANDBOX_NO_UPDATE_CHECK= SANDBOX_FAKE_UPSTREAM=99.0.0 run "$PWSH" -NoProfile -File "$LAUNCHER"
    refute_output_contains 'is available'
}

@test "ps launcher: codex rebuilds only when npm reports a new version" {
    SANDBOX_FAKE_NPM=1.2.3 ps_install codex
    mkdir -p "$TESTDIR/proj"; cd "$TESTDIR/proj"
    : > "$FAKE_DOCKER_LOG"
    SANDBOX_FAKE_NPM=1.2.3 run "$PWSH" -NoProfile -File "$HOME/bin/codex-sandbox.ps1"
    assert_success
    refute_docker_ran 'docker build'
    : > "$FAKE_DOCKER_LOG"
    SANDBOX_FAKE_NPM=9.9.9 run "$PWSH" -NoProfile -File "$HOME/bin/codex-sandbox.ps1"
    assert_success
    assert_output_contains 'Codex 9.9.9 available'
    assert_docker_ran '--build-arg CODEX_VERSION=9.9.9'
}

@test "ps: re-running the codex installer picks up a new Codex release" {
    SANDBOX_FAKE_NPM=0.44.0 ps_install codex
    assert_success
    : > "$FAKE_DOCKER_LOG"
    SANDBOX_FAKE_NPM=0.45.0 ps_install codex
    assert_success
    assert_output_contains 'Codex 0.44.0 -> 0.45.0'
    assert_docker_ran '--build-arg CODEX_VERSION=0.45.0'
}

@test "ps: re-running with the same Codex release rebuilds nothing" {
    SANDBOX_FAKE_NPM=0.44.0 ps_install codex
    : > "$FAKE_DOCKER_LOG"
    SANDBOX_FAKE_NPM=0.44.0 ps_install codex
    assert_success
    refute_docker_ran 'docker build'
}

@test "ps: first-run instructions appear on a first run and not on a re-run" {
    ps_install claude
    assert_output_contains 'Log in once'
    ps_install claude
    assert_success
    refute_output_contains 'Log in once'
    assert_output_contains '--sandbox-doctor'
}

# --- git identity and credentials (mirrors launcher.bats) ------------------

ps_argv_lacks() {
    if grep -qF -- "$1" "$FAKE_DOCKER_ARGV"; then
        printf -- '--- argv ---\n%s\n' "$(cat "$FAKE_DOCKER_ARGV")" >&2
        fail_with "expected NO argument containing: $1"
    fi
    return 0
}

@test "ps launcher: the host git identity is passed through" {
    ps_install claude
    mkdir -p "$TESTDIR/proj"; cd "$TESTDIR/proj"
    export FAKE_GIT_NAME="Ada Lovelace" FAKE_GIT_EMAIL=ada@example.com
    : > "$FAKE_DOCKER_ARGV"
    run "$PWSH" -NoProfile -File "$LAUNCHER"
    assert_success
    # A whole-line match, so a value containing a space is still exact.
    grep -qxF -- "GIT_CONFIG_VALUE_0=Ada Lovelace" "$FAKE_DOCKER_ARGV"
    grep -qxF -- "GIT_CONFIG_KEY_1=user.email" "$FAKE_DOCKER_ARGV"
    grep -qxF -- "GIT_CONFIG_COUNT=2" "$FAKE_DOCKER_ARGV"
}

@test "ps launcher: no identity means no git environment and no empty -e" {
    ps_install claude
    mkdir -p "$TESTDIR/proj"; cd "$TESTDIR/proj"
    : > "$FAKE_DOCKER_ARGV"
    run "$PWSH" -NoProfile -File "$LAUNCHER"
    assert_success
    ps_argv_lacks "GIT_CONFIG_COUNT"
    # An empty value must never reach docker as a bare `-e ''`. PowerShell will
    # happily splat one: @('-e','') becomes a real, malformed argv entry, and
    # the fake docker records every argument on its own line — so an empty line
    # here is exactly that bug.
    if grep -qx -- '' "$FAKE_DOCKER_ARGV"; then
        fail_with "an empty argument reached docker"
    fi
}

@test "ps launcher: --sandbox-git forwards a host-scoped credential" {
    ps_install claude
    mkdir -p "$TESTDIR/proj"; cd "$TESTDIR/proj"
    export FAKE_GIT_NAME=Ada FAKE_GIT_EMAIL=ada@example.com
    export FAKE_GIT_ORIGIN=https://github.com/ada/looms.git
    export FAKE_GIT_CRED_USER=ada FAKE_GIT_CRED_PASS=s3cret
    : > "$FAKE_DOCKER_ARGV"
    run "$PWSH" -NoProfile -File "$LAUNCHER" --sandbox-git
    assert_success
    grep -qxF -- "SANDBOX_GIT_USER=ada" "$FAKE_DOCKER_ARGV"
    grep -qxF -- "SANDBOX_GIT_TOKEN=s3cret" "$FAKE_DOCKER_ARGV"
    grep -qxF -- "GIT_CONFIG_KEY_2=credential.https://github.com.helper" "$FAKE_DOCKER_ARGV"
    ps_argv_lacks "--sandbox-git"
}

@test "ps launcher: no credential without the flag" {
    ps_install claude
    mkdir -p "$TESTDIR/proj"; cd "$TESTDIR/proj"
    export FAKE_GIT_ORIGIN=https://github.com/ada/looms.git
    export FAKE_GIT_CRED_USER=ada FAKE_GIT_CRED_PASS=s3cret
    : > "$FAKE_DOCKER_ARGV"
    run "$PWSH" -NoProfile -File "$LAUNCHER"
    assert_success
    ps_argv_lacks "s3cret"
}

@test "ps launcher: SANDBOX_NO_GIT suppresses everything" {
    ps_install claude
    mkdir -p "$TESTDIR/proj"; cd "$TESTDIR/proj"
    export FAKE_GIT_NAME=Ada FAKE_GIT_EMAIL=ada@example.com
    export SANDBOX_NO_GIT=1
    : > "$FAKE_DOCKER_ARGV"
    run "$PWSH" -NoProfile -File "$LAUNCHER"
    assert_success
    ps_argv_lacks "GIT_CONFIG_COUNT"
}

@test "ps launcher: --sandbox-doctor reports git state without the token" {
    ps_install claude
    mkdir -p "$TESTDIR/proj"; cd "$TESTDIR/proj"
    export FAKE_GIT_NAME="Ada Lovelace" FAKE_GIT_EMAIL=ada@example.com
    export FAKE_GIT_ORIGIN=https://github.com/ada/looms.git
    export FAKE_GIT_CRED_USER=ada FAKE_GIT_CRED_PASS=s3cret
    run "$PWSH" -NoProfile -File "$LAUNCHER" --sandbox-doctor
    assert_success
    assert_output_contains 'Ada Lovelace <ada@example.com>'
    assert_output_contains 'available for github.com'
    refute_output_contains 's3cret'
}

@test "ps launcher: --sandbox-docker is refused and points at WSL2" {
    ps_install claude
    : > "$FAKE_DOCKER_LOG"
    run "$PWSH" -NoProfile -File "$LAUNCHER" --sandbox-docker
    assert_failure
    assert_output_contains 'not supported on native Windows'
    assert_output_contains 'WINDOWS.md'
    # A refusal, not a half-honoured launch: no container, no socket.
    refute_docker_ran 'docker run'
    refute_docker_ran 'docker.sock'
}

@test "ps launcher: SANDBOX_DOCKER in the environment is ignored, and says so" {
    ps_install claude
    : > "$FAKE_DOCKER_LOG"
    SANDBOX_DOCKER=1 run "$PWSH" -NoProfile -File "$LAUNCHER"
    assert_success
    assert_output_contains 'ignored on native Windows'
    refute_docker_ran 'docker.sock'
}

# --- --sandbox-ro (read-only host mounts) -----------------------------------
# The mirror of the shell launcher's flag. This job runs under pwsh on Linux,
# so the host paths are POSIX; the Windows-path translation is driven through
# SANDBOX_FAKE_PWD plus the SANDBOX_FAKE_RO_EXISTS seam, since C:\ cannot exist
# here.

ps_ro_setup() {
    ps_install claude
    DATA="$TESTDIR/shared data"
    mkdir -p "$DATA" "$TESTDIR/proj"
    echo shared > "$DATA/in.csv"
    DATA=$(cd "$DATA" && pwd -P)
    cd "$TESTDIR/proj"
    : > "$FAKE_DOCKER_ARGV"
}

@test "ps launcher: --sandbox-ro mounts the path read-only at its own path" {
    ps_ro_setup
    run "$PWSH" -NoProfile -File "$LAUNCHER" --sandbox-ro "$DATA" --dangerously-skip-permissions
    assert_success
    grep -qxF -- "-v" "$FAKE_DOCKER_ARGV"
    grep -qxF -- "$DATA:$DATA:ro" "$FAKE_DOCKER_ARGV"
    grep -qxF -- "--dangerously-skip-permissions" "$FAKE_DOCKER_ARGV"
    assert_output_contains "read-only: $DATA"
    ps_argv_lacks "--sandbox-ro"
    if grep -qx -- '' "$FAKE_DOCKER_ARGV"; then fail_with "an empty argument reached docker"; fi
}

@test "ps launcher: --sandbox-ro=PATH, repeated, relative, and a file" {
    ps_ro_setup
    run "$PWSH" -NoProfile -File "$LAUNCHER" "--sandbox-ro=../shared data" --sandbox-ro "$DATA/in.csv" --sandbox-ro "$DATA"
    assert_success
    grep -qxF -- "$DATA:$DATA:ro" "$FAKE_DOCKER_ARGV"
    grep -qxF -- "$DATA/in.csv:$DATA/in.csv:ro" "$FAKE_DOCKER_ARGV"
    [ "$(grep -cxF -- "$DATA:$DATA:ro" "$FAKE_DOCKER_ARGV")" -eq 1 ] \
        || fail_with "expected exactly one mount of $DATA"
}

@test "ps launcher: a Windows path is mounted at its /mnt/<drive> translation" {
    ps_ro_setup
    SANDBOX_FAKE_RO_EXISTS=1 SANDBOX_FAKE_PWD='C:\Users\mike\proj' \
        run "$PWSH" -NoProfile -File "$LAUNCHER" --sandbox-ro 'D:\data' --sandbox-ro 'C:\Users\mike\proj\fixtures'
    assert_success
    # The source keeps its native form, which is what Docker Desktop expects;
    # only the destination is translated, exactly like the project mount.
    grep -qxF -- 'D:\data:/mnt/d/data:ro' "$FAKE_DOCKER_ARGV"
    grep -qxF -- 'C:\Users\mike\proj\fixtures:/mnt/c/Users/mike/proj/fixtures:ro' "$FAKE_DOCKER_ARGV"
}

@test "ps launcher: --sandbox-ro refuses a missing path, home, the project, and their ancestors" {
    ps_ro_setup
    : > "$FAKE_DOCKER_LOG"
    run "$PWSH" -NoProfile -File "$LAUNCHER" --sandbox-ro "$TESTDIR/nope"
    assert_failure
    assert_output_contains "does not exist"
    run "$PWSH" -NoProfile -File "$LAUNCHER" --sandbox-ro "$HOME"
    assert_failure
    assert_output_contains "contains your home directory"
    run "$PWSH" -NoProfile -File "$LAUNCHER" --sandbox-ro .
    assert_failure
    assert_output_contains "is the project, which is already mounted writable"
    SANDBOX_FAKE_RO_EXISTS=1 SANDBOX_FAKE_PWD='C:\Users\mike\proj' SANDBOX_FAKE_HOME='D:\elsewhere' \
        run "$PWSH" -NoProfile -File "$LAUNCHER" --sandbox-ro 'C:\Users\mike'
    assert_failure
    assert_output_contains "contains the project, which is mounted writable"
    run "$PWSH" -NoProfile -File "$LAUNCHER" --sandbox-ro /etc
    assert_failure
    assert_output_contains "is a system path inside the container"
    refute_docker_ran 'docker run'
}

@test "ps launcher: --sandbox-ro without a path is refused, and past first position it is forwarded" {
    ps_ro_setup
    : > "$FAKE_DOCKER_LOG"
    run "$PWSH" -NoProfile -File "$LAUNCHER" --sandbox-ro
    assert_failure
    assert_output_contains "--sandbox-ro needs a path"
    refute_docker_ran 'docker run'
    run "$PWSH" -NoProfile -File "$LAUNCHER" --print --sandbox-ro /etc
    assert_success
    grep -qxF -- "--sandbox-ro" "$FAKE_DOCKER_ARGV"
    ps_argv_lacks ":ro"
}

@test "ps launcher: --sandbox-doctor lists read-only mounts and refusals" {
    ps_ro_setup
    run "$PWSH" -NoProfile -File "$LAUNCHER" --sandbox-ro "$DATA" --sandbox-ro "$TESTDIR/nope" --sandbox-doctor
    assert_success
    assert_output_contains "read-only mount     $DATA -> $DATA"
    assert_output_contains "$TESTDIR/nope REFUSED — does not exist"
    refute_docker_ran 'docker run -it'
}
