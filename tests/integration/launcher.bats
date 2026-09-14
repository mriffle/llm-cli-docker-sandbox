#!/usr/bin/env bats
# The installed launchers: argument forwarding, the sandbox-* flags, the tmux
# modes, the update nudge, and the doctor report.

load '../helper'

setup() {
    common_setup
    # The launchers use the real `id -u` (no test seams in a user-facing
    # script), so line the fake identity up with it.
    export SANDBOX_FAKE_UID; SANDBOX_FAKE_UID=$(id -u)
    export SANDBOX_FAKE_GID; SANDBOX_FAKE_GID=$(id -g)
    export FAKE_DOCKER_NEW_VOL_UID="$SANDBOX_FAKE_UID"
    export FAKE_TMUX_STATE="$TESTDIR/tmux"
    export FAKE_TMUX_LOG="$TESTDIR/tmux.log"
    export FAKE_DOCKER_ARGV="$TESTDIR/docker.argv"
    export FAKE_CURL_LOG="$TESTDIR/curl.log"
    export FAKE_INSTALLER_DIR="$REPO_ROOT/install"
    mkdir -p "$FAKE_TMUX_STATE"
    : > "$FAKE_TMUX_LOG"; : > "$FAKE_DOCKER_ARGV"; : > "$FAKE_CURL_LOG"
    # A stand-in for the host's docker socket. --sandbox-docker refuses to
    # mount a path that is not there, and the host running the suite may have
    # no docker at all — GitHub's macOS runners do not — so the fake daemon is
    # pointed at a file this test owns rather than at the real /var/run one.
    FAKE_SOCK="$TESTDIR/docker.sock"
    : > "$FAKE_SOCK"
    export FAKE_DOCKER_ENDPOINT="unix://$FAKE_SOCK"
    bash "$(installer claude)" >/dev/null 2>&1
    LAUNCH="$HOME/.local/bin/claude-sandbox"
    PROJECT="$TESTDIR/my project"
    mkdir -p "$PROJECT"
    : > "$FAKE_DOCKER_LOG"
}
teardown() { common_teardown; }

argv_has() {
    grep -qxF -- "$1" "$FAKE_DOCKER_ARGV" \
        || { printf -- '--- argv ---\n%s\n' "$(cat "$FAKE_DOCKER_ARGV")" >&2
             fail_with "expected an exact argument: $1"; }
}
tmux_log_has() {
    grep -qF -- "$1" "$FAKE_TMUX_LOG" \
        || { printf -- '--- tmux ---\n%s\n' "$(cat "$FAKE_TMUX_LOG")" >&2
             fail_with "expected a tmux call containing: $1"; }
}
refute_tmux_log() {
    if grep -qF -- "$1" "$FAKE_TMUX_LOG"; then
        printf -- '--- tmux ---\n%s\n' "$(cat "$FAKE_TMUX_LOG")" >&2
        fail_with "expected NO tmux call containing: $1"
    fi
    return 0
}

# --- the normal path -------------------------------------------------------

@test "launcher mounts the current directory and nothing else" {
    cd "$PROJECT"
    # The *physical* path, not bash's logical $PWD: one project reached through
    # a symlink must not look like two, or it gets two memory stores. (On macOS
    # these differ — /var vs /private/var. The PowerShell launcher has always
    # reported the physical path; the two now agree.)
    local here; here=$(pwd -P)
    run bash "$LAUNCH"
    assert_success
    argv_has "$here:$here"
    argv_has "claude-config-testuser:/home/agent/.claude"
    argv_has "claude-local-testuser:/home/agent/.local"
    argv_has "--cap-drop=ALL"
    argv_has "--security-opt=no-new-privileges"
}

# --- one mount point would be one project identity -------------------------
# Both agents key their per-project state on the working directory string:
# Claude Code's ~/.claude/projects/<cwd-slug>/ holds the session transcripts
# and memory, and Codex records the cwd in every rollout. Mounting every
# project at a fixed /workspace made them all one project to the agent.

@test "the container's working directory mirrors the host path" {
    cd "$PROJECT"
    # $PROJECT contains a space, so this also proves the path survives as one
    # argument on both the mount and -w (the argv file is one arg per line).
    local here; here=$(pwd -P)
    run bash "$LAUNCH"
    assert_success
    argv_has "-w"
    argv_has "$here"
}

@test "two project directories get two different container paths" {
    local a b
    mkdir -p "$TESTDIR/alpha" "$TESTDIR/beta"
    cd "$TESTDIR/alpha"; a=$(pwd -P)
    run bash "$LAUNCH"
    assert_success
    argv_has "$a:$a"

    : > "$FAKE_DOCKER_ARGV"
    cd "$TESTDIR/beta"; b=$(pwd -P)
    run bash "$LAUNCH"
    assert_success
    argv_has "$b:$b"
    [ "$a" != "$b" ] || fail_with "the fixture directories should differ"
    grep -qxF -- "$a:$a" "$FAKE_DOCKER_ARGV" \
        && fail_with "the second launch reused the first project's path"
    return 0
}

@test "SANDBOX_WORKDIR pins the old fixed mount" {
    cd "$PROJECT"
    local here; here=$(pwd -P)
    SANDBOX_WORKDIR=/workspace run bash "$LAUNCH"
    assert_success
    argv_has "$here:/workspace"
    argv_has "/workspace"
}

@test "a directory that cannot be mirrored falls back to /workspace and says so" {
    cd "$PROJECT"
    local p
    # / and the bare system directories would mount the host over the image;
    # /home/agent is the agent's own home, which a host user actually named
    # `agent` would otherwise expose in full.
    for p in / /usr /home /home/agent /home/agent/work; do
        : > "$FAKE_DOCKER_ARGV"
        SANDBOX_FAKE_PWD="$p" run bash "$LAUNCH"
        assert_success
        assert_output_contains "cannot mirror $p inside the container"
        argv_has "$p:/workspace"
    done
}

@test "a directory beneath a system one is still mirrored" {
    cd "$PROJECT"
    # Only the exact system paths are reserved. /opt/proj (or macOS's
    # /var/folders/xx/proj, where the suite's own temp dirs live) just creates
    # a directory inside the container and is safe to mirror.
    SANDBOX_FAKE_PWD=/opt/proj run bash "$LAUNCH"
    assert_success
    refute_output_contains 'cannot mirror'
    argv_has "/opt/proj:/opt/proj"
}

@test "launcher forwards arguments verbatim, spaces and all" {
    cd "$PROJECT"
    run bash "$LAUNCH" --dangerously-skip-permissions -p "two words here"
    assert_success
    argv_has "claude"
    argv_has "--dangerously-skip-permissions"
    argv_has "-p"
    argv_has "two words here"
}

@test "launcher sanitises the container name but keeps it recognisable" {
    cd "$PROJECT"
    run bash "$LAUNCH"
    assert_success
    grep -qE '^claude-testuser-my-project-[0-9]+$' "$FAKE_DOCKER_ARGV"
}

@test "launcher refuses clearly when the image is missing" {
    rm -f "$FAKE_DOCKER_STATE/images/claude-sandbox-testuser.labels"
    cd "$PROJECT"
    run bash "$LAUNCH"
    assert_failure
    assert_output_contains 'does not exist'
    assert_output_contains 'install/claude.sh | bash'
}

@test "launcher reports an unreachable daemon rather than a docker stack trace" {
    rm -f "$FAKE_DOCKER_STATE/images/claude-sandbox-testuser.labels"
    cd "$PROJECT"
    FAKE_DOCKER_INFO_RC=1 run bash "$LAUNCH"
    assert_failure
    assert_output_contains 'cannot reach the docker daemon'
}

# --- sandbox flags ---------------------------------------------------------

@test "--sandbox-version and --sandbox-help do not start a container" {
    run bash "$LAUNCH" --sandbox-version
    assert_success
    [ "$output" = "$(cat "$REPO_ROOT/VERSION")" ]
    run bash "$LAUNCH" --sandbox-help
    assert_success
    assert_output_contains '--sandbox-tmux'
    refute_docker_ran 'docker run'
}

@test "sandbox flags are only intercepted in first position" {
    cd "$PROJECT"
    run bash "$LAUNCH" --print --sandbox-version
    assert_success
    argv_has "--sandbox-version"
    argv_has "--print"
}

@test "--sandbox-doctor reports image, volumes and UIDs" {
    run bash "$LAUNCH" --sandbox-doctor
    assert_success
    assert_output_contains 'claude-sandbox-testuser'
    assert_output_contains 'volume claude-config-testuser ok'
    assert_output_contains 'volume claude-local-testuser ok'
    assert_output_contains "image agent UID     $(id -u)"
}

@test "--sandbox-doctor flags a UID mismatch instead of hiding it" {
    printf 'sandbox.agent_uid=99999\n' > "$FAKE_DOCKER_STATE/images/claude-sandbox-testuser.labels"
    run bash "$LAUNCH" --sandbox-doctor
    assert_output_contains 'MISMATCH'
    assert_output_contains 're-run the installer'
}

@test "--sandbox-doctor names the mount it will use for this directory" {
    cd "$PROJECT"
    local here; here=$(pwd -P)
    run bash "$LAUNCH" --sandbox-doctor
    assert_success
    assert_output_contains "project mount       $here -> $here"
}

@test "--sandbox-doctor reports state pooled under the old fixed mount" {
    cd "$PROJECT"
    run bash "$LAUNCH" --sandbox-doctor
    assert_success
    refute_output_contains 'legacy state'
    FAKE_DOCKER_LEGACY_PROJECTS=1 run bash "$LAUNCH" --sandbox-doctor
    assert_success
    assert_output_contains 'legacy state        projects/-workspace'
    assert_output_contains 'ls /v/projects'
}

@test "--sandbox-doctor reports a missing image without crashing" {
    rm -f "$FAKE_DOCKER_STATE/images/claude-sandbox-testuser.labels"
    run bash "$LAUNCH" --sandbox-doctor
    assert_success
    assert_output_contains 'image               MISSING'
}

@test "--sandbox-upgrade re-runs the installer" {
    : > "$FAKE_DOCKER_LOG"
    run bash "$LAUNCH" --sandbox-upgrade --force
    assert_success
    grep -q 'install/claude.sh' "$FAKE_CURL_LOG"
    assert_docker_ran 'docker build'
}

# --- the update nudge ------------------------------------------------------

@test "a newer upstream version produces one nudge, not a launch failure" {
    cd "$PROJECT"
    SANDBOX_NO_UPDATE_CHECK= FAKE_UPSTREAM_VERSION=99.0.0 run bash "$LAUNCH"
    assert_success
    assert_output_contains 'of the sandbox is available'
    assert_output_contains '--sandbox-upgrade'
}

@test "an up-to-date upstream version says nothing" {
    cd "$PROJECT"
    SANDBOX_NO_UPDATE_CHECK= FAKE_UPSTREAM_VERSION=0.0.1 run bash "$LAUNCH"
    assert_success
    refute_output_contains 'is available'
}

@test "the version check runs at most once a day" {
    cd "$PROJECT"
    SANDBOX_NO_UPDATE_CHECK= FAKE_UPSTREAM_VERSION=99.0.0 run bash "$LAUNCH"
    SANDBOX_NO_UPDATE_CHECK= FAKE_UPSTREAM_VERSION=99.0.0 run bash "$LAUNCH"
    SANDBOX_NO_UPDATE_CHECK= FAKE_UPSTREAM_VERSION=99.0.0 run bash "$LAUNCH"
    [ "$(grep -c 'VERSION' "$FAKE_CURL_LOG")" -eq 1 ]
}

@test "a failing version check is silent and never blocks the launch" {
    cd "$PROJECT"
    SANDBOX_NO_UPDATE_CHECK= FAKE_VERSION_FETCH_FAIL=1 run bash "$LAUNCH"
    assert_success
    refute_output_contains 'is available'
    assert_docker_ran 'docker run'
}

@test "SANDBOX_NO_UPDATE_CHECK stops the network call entirely" {
    cd "$PROJECT"
    SANDBOX_NO_UPDATE_CHECK=1 FAKE_UPSTREAM_VERSION=99.0.0 run bash "$LAUNCH"
    assert_success
    [ ! -s "$FAKE_CURL_LOG" ]
}

# --- tmux ------------------------------------------------------------------

@test "--sandbox-tmux creates a session named for the project and attaches" {
    cd "$PROJECT"
    run bash "$LAUNCH" --sandbox-tmux --dangerously-skip-permissions
    assert_success
    tmux_log_has 'new-session -d -s claude-my-project'
    tmux_log_has 'attach-session'
    tmux_log_has 'set-environment'
}

@test "--sandbox-tmux passes the agent arguments into the session command" {
    cd "$PROJECT"
    run bash "$LAUNCH" --sandbox-tmux --dangerously-skip-permissions
    assert_success
    tmux_log_has '--dangerously-skip-permissions'
    tmux_log_has 'press Enter to close'
}

@test "--sandbox-tmux attaches to an existing session for the same directory" {
    cd "$PROJECT"
    run bash "$LAUNCH" --sandbox-tmux
    : > "$FAKE_TMUX_LOG"
    run bash "$LAUNCH" --sandbox-tmux
    assert_success
    assert_output_contains 'attaching to the existing session'
    refute_tmux_log 'new-session'
}

@test "two projects with the same basename get separate sessions" {
    mkdir -p "$TESTDIR/a/shared" "$TESTDIR/b/shared"
    cd "$TESTDIR/a/shared"
    run bash "$LAUNCH" --sandbox-tmux
    assert_success
    : > "$FAKE_TMUX_LOG"
    cd "$TESTDIR/b/shared"
    run bash "$LAUNCH" --sandbox-tmux
    assert_success
    tmux_log_has 'new-session'
    [ "$(find "$FAKE_TMUX_STATE/sessions" -type f | wc -l)" -eq 2 ]
    grep -qE 'new-session -d -s claude-shared-[0-9a-f]{6}' "$FAKE_TMUX_LOG"
}

@test "--sandbox-tmux-detached does not attach" {
    cd "$PROJECT"
    run bash "$LAUNCH" --sandbox-tmux-detached
    assert_success
    tmux_log_has 'new-session'
    refute_tmux_log 'attach-session'
    assert_output_contains 'in the background'
}

@test "--sandbox-tmux-detached on a running session just says where it is" {
    cd "$PROJECT"
    run bash "$LAUNCH" --sandbox-tmux-detached
    : > "$FAKE_TMUX_LOG"
    run bash "$LAUNCH" --sandbox-tmux-detached
    assert_success
    assert_output_contains 'already running'
    refute_tmux_log 'new-session'
}

@test "inside tmux, --sandbox-tmux runs directly instead of nesting" {
    cd "$PROJECT"
    TMUX=/tmp/fake-tmux-socket,123,0 run bash "$LAUNCH" --sandbox-tmux
    assert_success
    assert_output_contains 'already inside tmux'
    refute_tmux_log 'new-session'
    assert_docker_ran 'docker run'
}

@test "--sandbox-tmux without tmux installed says how to install it" {
    cd "$PROJECT"
    PATH="$(path_without tmux)" run bash "$LAUNCH" --sandbox-tmux
    assert_failure
    assert_output_contains 'tmux is not installed'
    assert_output_contains 'brew install tmux'
}

@test "--sandbox-tmux checks the image before creating a session" {
    rm -f "$FAKE_DOCKER_STATE/images/claude-sandbox-testuser.labels"
    cd "$PROJECT"
    run bash "$LAUNCH" --sandbox-tmux
    assert_failure
    refute_tmux_log 'new-session'
}

# --- codex launcher --------------------------------------------------------

@test "the codex launcher rebuilds only when npm reports a new version" {
    bash "$(installer codex)" >/dev/null 2>&1
    cd "$PROJECT"
    : > "$FAKE_DOCKER_LOG"
    FAKE_CODEX_VERSION=1.2.3 run bash "$HOME/.local/bin/codex-sandbox"
    assert_success
    refute_docker_ran 'docker build'
    : > "$FAKE_DOCKER_LOG"
    FAKE_CODEX_VERSION=9.9.9 run bash "$HOME/.local/bin/codex-sandbox"
    assert_success
    assert_output_contains 'Codex 9.9.9 available'
    assert_docker_ran '--build-arg CODEX_VERSION=9.9.9'
    assert_docker_ran '--label sandbox.agent_uid='
}

@test "the codex launcher survives an unreachable npm registry" {
    bash "$(installer codex)" >/dev/null 2>&1
    cd "$PROJECT"
    : > "$FAKE_DOCKER_LOG"
    FAKE_NPM_FAIL=1 run bash "$HOME/.local/bin/codex-sandbox"
    assert_success
    assert_output_contains 'npm version check failed'
    assert_docker_ran 'docker run'
}

@test "the codex launcher mounts only its own volume" {
    bash "$(installer codex)" >/dev/null 2>&1
    cd "$PROJECT"
    : > "$FAKE_DOCKER_ARGV"
    FAKE_CODEX_VERSION=1.2.3 run bash "$HOME/.local/bin/codex-sandbox"
    assert_success
    argv_has "codex-config-testuser:/home/agent/.codex"
    argv_has "codex"
    refute_output_contains 'claude'
}

# --- git identity and credentials ------------------------------------------
# All of these run against the fake git and gh in fixtures/fakebin, never the
# real ones: see the git pinning in common_setup for why that matters.

argv_lacks() {
    if grep -qF -- "$1" "$FAKE_DOCKER_ARGV"; then
        printf -- '--- argv ---\n%s\n' "$(cat "$FAKE_DOCKER_ARGV")" >&2
        fail_with "expected NO argument containing: $1"
    fi
    return 0
}

@test "the host git identity is passed through so the agent can commit" {
    cd "$PROJECT"
    export FAKE_GIT_NAME="Ada Lovelace" FAKE_GIT_EMAIL=ada@example.com
    run bash "$LAUNCH"
    assert_success
    argv_has "GIT_CONFIG_KEY_0=user.name"
    argv_has "GIT_CONFIG_VALUE_0=Ada Lovelace"
    argv_has "GIT_CONFIG_KEY_1=user.email"
    argv_has "GIT_CONFIG_VALUE_1=ada@example.com"
    argv_has "GIT_CONFIG_COUNT=2"
}

@test "an email but no name still yields a usable, correctly counted config" {
    cd "$PROJECT"
    export FAKE_GIT_EMAIL=ada@example.com
    run bash "$LAUNCH"
    assert_success
    argv_has "GIT_CONFIG_KEY_0=user.email"
    argv_has "GIT_CONFIG_COUNT=1"
}

@test "no git identity on the host means no git environment at all" {
    cd "$PROJECT"
    run bash "$LAUNCH"
    assert_success
    argv_lacks "GIT_CONFIG_COUNT"
    argv_lacks "GIT_CONFIG_KEY_0"
}

@test "a host without git launches normally rather than failing" {
    cd "$PROJECT"
    PATH="$(path_without git)" run bash "$LAUNCH"
    assert_success
    argv_has "--cap-drop=ALL"
    argv_lacks "GIT_CONFIG_COUNT"
}

@test "SANDBOX_NO_GIT suppresses identity and credentials entirely" {
    cd "$PROJECT"
    export FAKE_GIT_NAME="Ada Lovelace" FAKE_GIT_EMAIL=ada@example.com
    export SANDBOX_NO_GIT=1
    run bash "$LAUNCH"
    assert_success
    argv_lacks "GIT_CONFIG_COUNT"
}

@test "no credential is forwarded unless --sandbox-git is given" {
    cd "$PROJECT"
    export FAKE_GIT_NAME=Ada FAKE_GIT_EMAIL=ada@example.com
    export FAKE_GIT_ORIGIN=https://github.com/ada/looms.git
    export FAKE_GIT_CRED_USER=ada FAKE_GIT_CRED_PASS=s3cret
    run bash "$LAUNCH"
    assert_success
    argv_has "GIT_CONFIG_KEY_0=user.name"
    argv_lacks "SANDBOX_GIT_TOKEN"
    argv_lacks "s3cret"
    argv_lacks "credential."
}

@test "--sandbox-git forwards a credential scoped to the origin's host" {
    cd "$PROJECT"
    export FAKE_GIT_NAME=Ada FAKE_GIT_EMAIL=ada@example.com
    export FAKE_GIT_ORIGIN=https://github.com/ada/looms.git
    export FAKE_GIT_CRED_USER=ada FAKE_GIT_CRED_PASS=s3cret
    run bash "$LAUNCH" --sandbox-git
    assert_success
    argv_has "SANDBOX_GIT_USER=ada"
    argv_has "SANDBOX_GIT_TOKEN=s3cret"
    argv_has "GIT_CONFIG_KEY_2=credential.https://github.com.helper"
    argv_has "GIT_CONFIG_COUNT=3"
    # The helper must name the container's variables, not expand them here.
    grep -qF 'SANDBOX_GIT_TOKEN"' "$FAKE_DOCKER_ARGV" \
        || fail_with "the credential helper did not reach the container intact"
}

@test "--sandbox-git strips the flag rather than passing it to the agent" {
    cd "$PROJECT"
    run bash "$LAUNCH" --sandbox-git --dangerously-skip-permissions
    assert_success
    argv_has "--dangerously-skip-permissions"
    argv_lacks "--sandbox-git"
}

@test "--sandbox-git on an ssh remote says so instead of forwarding nothing quietly" {
    cd "$PROJECT"
    export FAKE_GIT_ORIGIN=git@github.com:ada/looms.git
    export FAKE_GIT_CRED_USER=ada FAKE_GIT_CRED_PASS=s3cret
    run bash "$LAUNCH" --sandbox-git
    assert_success
    assert_output_contains "no https remote"
    argv_lacks "SANDBOX_GIT_TOKEN"
}

@test "--sandbox-git with nothing in the credential store warns and still launches" {
    cd "$PROJECT"
    export FAKE_GIT_ORIGIN=https://github.com/ada/looms.git
    run bash "$LAUNCH" --sandbox-git
    assert_success
    assert_output_contains "no credential stored"
    argv_lacks "SANDBOX_GIT_TOKEN"
    argv_has "--cap-drop=ALL"
}

@test "GH_TOKEN is preferred over the credential store for github.com" {
    cd "$PROJECT"
    export FAKE_GIT_ORIGIN=https://github.com/ada/looms.git
    export FAKE_GIT_CRED_USER=ada FAKE_GIT_CRED_PASS=from-store
    export GH_TOKEN=from-env
    run bash "$LAUNCH" --sandbox-git
    assert_success
    argv_has "SANDBOX_GIT_TOKEN=from-env"
    argv_lacks "from-store"
}

@test "gh supplies the token when the credential store has none" {
    cd "$PROJECT"
    export FAKE_GIT_ORIGIN=https://github.com/ada/looms.git
    export FAKE_GH_TOKEN=from-gh
    run bash "$LAUNCH" --sandbox-git
    assert_success
    argv_has "SANDBOX_GIT_TOKEN=from-gh"
    argv_has "SANDBOX_GIT_USER=x-access-token"
}

@test "a non-github https remote still gets its own scoped helper" {
    cd "$PROJECT"
    export FAKE_GIT_ORIGIN=https://gitlab.example.org/ada/looms.git
    export FAKE_GIT_CRED_USER=ada FAKE_GIT_CRED_PASS=s3cret
    run bash "$LAUNCH" --sandbox-git
    assert_success
    argv_has "GIT_CONFIG_KEY_0=credential.https://gitlab.example.org.helper"
}

@test "userinfo in the remote URL does not confuse the host scoping" {
    cd "$PROJECT"
    export FAKE_GIT_ORIGIN=https://ada@github.com/ada/looms.git
    export FAKE_GIT_CRED_USER=ada FAKE_GIT_CRED_PASS=s3cret
    run bash "$LAUNCH" --sandbox-git
    assert_success
    argv_has "GIT_CONFIG_KEY_0=credential.https://github.com.helper"
}

@test "--sandbox-git composes with --sandbox-tmux by way of the session env" {
    cd "$PROJECT"
    export FAKE_GIT_ORIGIN=https://github.com/ada/looms.git
    export FAKE_GIT_CRED_USER=ada FAKE_GIT_CRED_PASS=s3cret
    run bash "$LAUNCH" --sandbox-git --sandbox-tmux
    assert_success
    tmux_log_has "SANDBOX_GIT=1"
}

@test "--sandbox-git is only honoured in first position" {
    cd "$PROJECT"
    export FAKE_GIT_ORIGIN=https://github.com/ada/looms.git
    export FAKE_GIT_CRED_USER=ada FAKE_GIT_CRED_PASS=s3cret
    run bash "$LAUNCH" --print --sandbox-git
    assert_success
    argv_has "--sandbox-git"
    argv_lacks "SANDBOX_GIT_TOKEN"
}

@test "--sandbox-doctor reports git state without ever printing the token" {
    cd "$PROJECT"
    export FAKE_GIT_NAME="Ada Lovelace" FAKE_GIT_EMAIL=ada@example.com
    export FAKE_GIT_ORIGIN=https://github.com/ada/looms.git
    export FAKE_GIT_CRED_USER=ada FAKE_GIT_CRED_PASS=s3cret
    run bash "$LAUNCH" --sandbox-doctor
    assert_success
    assert_output_contains "Ada Lovelace <ada@example.com>"
    assert_output_contains "available for github.com"
    refute_output_contains "s3cret"
}

@test "--sandbox-doctor names a missing identity as the reason commits fail" {
    cd "$PROJECT"
    run bash "$LAUNCH" --sandbox-doctor
    assert_success
    assert_output_contains "NONE configured"
}

# --- --sandbox-docker (Docker-out-of-Docker) --------------------------------
# The flag mounts the host daemon's socket into the session, which removes the
# boundary the sandbox exists to provide. These pin down that it happens only
# when asked, that it is loud when it does, and that it fails honestly when the
# host cannot support it.

@test "no docker socket is mounted unless --sandbox-docker is given" {
    cd "$PROJECT"
    run bash "$LAUNCH"
    assert_success
    argv_lacks "/var/run/docker.sock"
    argv_lacks "--group-add"
    # The rest of the hardening is untouched by the feature.
    argv_has "--cap-drop=ALL"
}

@test "--sandbox-docker mounts the socket and joins its group" {
    cd "$PROJECT"
    run bash "$LAUNCH"
    : > "$FAKE_DOCKER_ARGV"
    run bash "$LAUNCH" --sandbox-docker
    assert_success
    argv_has "-v"
    argv_has "$FAKE_SOCK:/var/run/docker.sock"
    argv_has "--group-add"
    argv_has "999"
    # Dropping capabilities does not stop a supplementary group from working,
    # so the hardening stays exactly as it was.
    argv_has "--cap-drop=ALL"
    argv_has "--security-opt=no-new-privileges"
    # A current image carries the CLI, so there is nothing to complain about.
    refute_output_contains "predates the bundled docker CLI"
}

@test "--sandbox-docker says out loud that the boundary is gone" {
    cd "$PROJECT"
    run bash "$LAUNCH" --sandbox-docker
    assert_success
    assert_output_contains "can reach the host Docker daemon"
    assert_output_contains "mount any host path"
}

@test "the warning is printed on every launch, not just the first" {
    cd "$PROJECT"
    run bash "$LAUNCH" --sandbox-docker
    assert_output_contains "can reach the host Docker daemon"
    run bash "$LAUNCH" --sandbox-docker
    assert_output_contains "can reach the host Docker daemon"
}

@test "SANDBOX_DOCKER=1 is the same as the flag" {
    cd "$PROJECT"
    SANDBOX_DOCKER=1 run bash "$LAUNCH"
    assert_success
    argv_has "$FAKE_SOCK:/var/run/docker.sock"
}

@test "--sandbox-docker is stripped rather than passed to the agent" {
    cd "$PROJECT"
    run bash "$LAUNCH" --sandbox-docker --dangerously-skip-permissions
    assert_success
    argv_has "--dangerously-skip-permissions"
    argv_lacks "--sandbox-docker"
}

@test "--sandbox-docker composes with --sandbox-git in either order" {
    cd "$PROJECT"
    export FAKE_GIT_ORIGIN=https://github.com/ada/looms.git
    export FAKE_GIT_CRED_USER=ada FAKE_GIT_CRED_PASS=s3cret
    run bash "$LAUNCH" --sandbox-docker --sandbox-git
    assert_success
    argv_has "SANDBOX_GIT_TOKEN=s3cret"
    argv_has "$FAKE_SOCK:/var/run/docker.sock"
    : > "$FAKE_DOCKER_ARGV"
    run bash "$LAUNCH" --sandbox-git --sandbox-docker
    assert_success
    argv_has "SANDBOX_GIT_TOKEN=s3cret"
    argv_has "$FAKE_SOCK:/var/run/docker.sock"
}

@test "--sandbox-docker composes with --sandbox-tmux by way of the session env" {
    cd "$PROJECT"
    run bash "$LAUNCH" --sandbox-docker --sandbox-tmux
    assert_success
    tmux_log_has "SANDBOX_DOCKER=1"
}

@test "--sandbox-docker is only honoured in first position" {
    cd "$PROJECT"
    run bash "$LAUNCH" --print --sandbox-docker
    assert_success
    argv_has "--sandbox-docker"
    argv_lacks "/var/run/docker.sock"
}

@test "an endpoint that is not a unix socket is refused, not half-honoured" {
    cd "$PROJECT"
    export FAKE_DOCKER_ENDPOINT='tcp://192.0.2.1:2375'
    run bash "$LAUNCH" --sandbox-docker
    assert_failure
    assert_output_contains "is not a unix socket"
    argv_lacks "--group-add"
}

@test "a socket whose group cannot be determined warns but still launches" {
    cd "$PROJECT"
    # A socket that is there but whose group the probe cannot read. There is no
    # host-side fallback on purpose — a guessed GID is wrong exactly where it
    # would be used — so this must degrade to no --group-add at all, which is
    # still correct for a 0666 socket.
    : > "$TESTDIR/fake.sock"
    export FAKE_DOCKER_ENDPOINT="unix://$TESTDIR/fake.sock"
    export FAKE_DOCKER_SOCK_GID=''
    run bash "$LAUNCH" --sandbox-docker
    assert_success
    assert_output_contains "could not determine the socket's group"
    argv_has "$TESTDIR/fake.sock:/var/run/docker.sock"
    argv_lacks "--group-add"
}

@test "an endpoint naming a socket that does not exist is refused" {
    cd "$PROJECT"
    # Mounting it would make docker create a directory on the host and hand the
    # agent that, where it expects a socket.
    export FAKE_DOCKER_ENDPOINT="unix://$TESTDIR/absent/docker.sock"
    run bash "$LAUNCH" --sandbox-docker
    assert_failure
    assert_output_contains "which does not exist"
    argv_lacks "$TESTDIR/absent/docker.sock"
}

@test "--sandbox-docker warns when the image predates the bundled docker CLI" {
    cd "$PROJECT"
    local labels="$FAKE_DOCKER_STATE/images/claude-sandbox-testuser.labels"
    assert_file_exists "$labels"
    sed 's/^sandbox.installer_version=.*/sandbox.installer_version=1.1.0/' \
        "$labels" > "$labels.new"
    mv "$labels.new" "$labels"
    run bash "$LAUNCH" --sandbox-docker
    assert_success
    assert_output_contains "predates the bundled docker CLI"
    # Still launches — the socket is mounted, it just may have nothing to use it.
    argv_has "$FAKE_SOCK:/var/run/docker.sock"
}

@test "the socket the launcher mounts is the one the active context names" {
    cd "$PROJECT"
    # A rootless daemon keeps its socket under $XDG_RUNTIME_DIR, not /var/run,
    # and that is the configuration worth supporting properly.
    mkdir -p "$TESTDIR/rootless"
    : > "$TESTDIR/rootless/docker.sock"
    export FAKE_DOCKER_ENDPOINT="unix://$TESTDIR/rootless/docker.sock"
    run bash "$LAUNCH" --sandbox-docker
    assert_success
    argv_has "$TESTDIR/rootless/docker.sock:/var/run/docker.sock"
    argv_lacks "$FAKE_SOCK:/var/run/docker.sock"
}

@test "--sandbox-doctor reports the socket, its group, and the CLI" {
    cd "$PROJECT"
    run bash "$LAUNCH" --sandbox-doctor
    assert_success
    assert_output_contains "docker socket       $FAKE_SOCK (group 999 inside)"
    assert_output_contains "docker CLI in image present"
}

@test "--sandbox-doctor says when the host cannot support the flag at all" {
    cd "$PROJECT"
    export FAKE_DOCKER_ENDPOINT='tcp://192.0.2.1:2375'
    run bash "$LAUNCH" --sandbox-doctor
    assert_success
    assert_output_contains "--sandbox-docker cannot work here"
}

# --- --sandbox-ro (read-only host mounts) -----------------------------------
# The flag mounts a host directory or file read-only at its own path. These pin
# down that it happens only when asked, lands at the physical path, refuses the
# paths that would widen what the agent can read or write, and survives the
# tmux round trip.

# The physical path, as the launcher will mount it. On macOS $TESTDIR is under
# /var/folders, which is really /private/var.
phys() { (cd "$1" && pwd -P); }

ro_setup() {
    DATA="$TESTDIR/shared data"
    mkdir -p "$DATA"
    echo shared > "$DATA/in.csv"
    DATA=$(phys "$DATA")
    cd "$PROJECT"
    : > "$FAKE_DOCKER_ARGV"
}

@test "no read-only mount unless --sandbox-ro is given" {
    ro_setup
    run bash "$LAUNCH"
    assert_success
    argv_lacks ":ro"
    refute_output_contains "read-only:"
}

@test "--sandbox-ro mounts the path read-only, at its own path, and says so" {
    ro_setup
    run bash "$LAUNCH" --sandbox-ro "$DATA"
    assert_success
    argv_has "-v"
    argv_has "$DATA:$DATA:ro"
    assert_output_contains "read-only: $DATA"
    # The hardening is untouched by the feature.
    argv_has "--cap-drop=ALL"
    argv_has "--security-opt=no-new-privileges"
}

@test "--sandbox-ro=PATH is the same flag" {
    ro_setup
    run bash "$LAUNCH" "--sandbox-ro=$DATA"
    assert_success
    argv_has "$DATA:$DATA:ro"
}

@test "--sandbox-ro is repeatable, and the mounts keep their order" {
    ro_setup
    mkdir -p "$TESTDIR/second"
    local second; second=$(phys "$TESTDIR/second")
    run bash "$LAUNCH" --sandbox-ro "$DATA" "--sandbox-ro=$second"
    assert_success
    argv_has "$DATA:$DATA:ro"
    argv_has "$second:$second:ro"
    local a b
    a=$(grep -nxF -- "$DATA:$DATA:ro" "$FAKE_DOCKER_ARGV" | cut -d: -f1)
    b=$(grep -nxF -- "$second:$second:ro" "$FAKE_DOCKER_ARGV" | cut -d: -f1)
    [ "$a" -lt "$b" ] || fail_with "expected $DATA before $second in argv"
}

@test "the same path given twice is mounted once" {
    ro_setup
    run bash "$LAUNCH" --sandbox-ro "$DATA" --sandbox-ro "$DATA/"
    assert_success
    [ "$(grep -cxF -- "$DATA:$DATA:ro" "$FAKE_DOCKER_ARGV")" -eq 1 ] \
        || fail_with "expected exactly one mount of $DATA"
}

@test "a relative path resolves against the current directory" {
    ro_setup
    run bash "$LAUNCH" --sandbox-ro "../shared data"
    assert_success
    argv_has "$DATA:$DATA:ro"
    argv_lacks "../shared data"
}

@test "a symlinked directory is mounted at its physical path" {
    ro_setup
    ln -s "$DATA" "$TESTDIR/alias"
    run bash "$LAUNCH" --sandbox-ro "$TESTDIR/alias"
    assert_success
    argv_has "$DATA:$DATA:ro"
    argv_lacks "alias"
}

@test "a single file can be mounted read-only" {
    ro_setup
    run bash "$LAUNCH" --sandbox-ro "$DATA/in.csv"
    assert_success
    argv_has "$DATA/in.csv:$DATA/in.csv:ro"
}

@test "a path that does not exist is refused, and nothing starts" {
    ro_setup
    : > "$FAKE_DOCKER_LOG"
    run bash "$LAUNCH" --sandbox-ro "$TESTDIR/nope"
    assert_failure
    assert_output_contains "--sandbox-ro: $TESTDIR/nope does not exist"
    refute_docker_ran 'docker run'
}

@test "a system path is refused" {
    ro_setup
    : > "$FAKE_DOCKER_LOG"
    run bash "$LAUNCH" --sandbox-ro /etc
    assert_failure
    assert_output_contains "/etc is a system path inside the container"
    refute_docker_ran 'docker run'
}

@test "the home directory is refused, and so is anything above it" {
    ro_setup
    : > "$FAKE_DOCKER_LOG"
    run bash "$LAUNCH" --sandbox-ro "$HOME"
    assert_failure
    assert_output_contains "contains your home directory"
    assert_output_contains "read-only is not confidentiality"
    run bash "$LAUNCH" --sandbox-ro "$TESTDIR"
    assert_failure
    assert_output_contains "contains your home directory"
    refute_docker_ran 'docker run'
}

@test "the project itself is refused" {
    ro_setup
    : > "$FAKE_DOCKER_LOG"
    run bash "$LAUNCH" --sandbox-ro .
    assert_failure
    assert_output_contains "is the project, which is already mounted writable"
    refute_docker_ran 'docker run'
}

@test "a directory containing the project is refused" {
    ro_setup
    mkdir -p "$TESTDIR/tree/proj"
    cd "$TESTDIR/tree/proj"
    : > "$FAKE_DOCKER_LOG"
    # HOME is moved aside so the home rule does not answer first: this is the
    # project rule under test. XDG_* keep the launcher's own state where it was.
    HOME="$TESTDIR/elsewhere" run bash "$LAUNCH" --sandbox-ro ..
    assert_failure
    assert_output_contains "contains the project, which is mounted writable"
    refute_docker_ran 'docker run'
}

@test "SANDBOX_WORKDIR does not change which directory counts as the project" {
    ro_setup
    : > "$FAKE_DOCKER_LOG"
    SANDBOX_WORKDIR=/workspace run bash "$LAUNCH" --sandbox-ro .
    assert_failure
    assert_output_contains "is the project"
    refute_docker_ran 'docker run'
}

@test "a path inside the project is accepted, and pins that part read-only" {
    ro_setup
    mkdir -p "$PROJECT/fixtures"
    local fx; fx=$(phys "$PROJECT/fixtures")
    run bash "$LAUNCH" --sandbox-ro fixtures
    assert_success
    argv_has "$fx:$fx:ro"
}

@test "--sandbox-ro is stripped rather than passed to the agent" {
    ro_setup
    run bash "$LAUNCH" --sandbox-ro "$DATA" --dangerously-skip-permissions
    assert_success
    argv_has "--dangerously-skip-permissions"
    argv_lacks "--sandbox-ro"
}

@test "--sandbox-ro is only honoured in first position" {
    ro_setup
    run bash "$LAUNCH" --print --sandbox-ro /etc
    assert_success
    argv_has "--sandbox-ro"
    argv_has "/etc"
    argv_lacks ":ro"
}

@test "--sandbox-ro without a path is refused" {
    ro_setup
    : > "$FAKE_DOCKER_LOG"
    run bash "$LAUNCH" --sandbox-ro
    assert_failure
    assert_output_contains "--sandbox-ro needs a path"
    refute_docker_ran 'docker run'
}

@test "--sandbox-ro composes with --sandbox-git and --sandbox-docker in any order" {
    ro_setup
    export FAKE_GIT_ORIGIN=https://github.com/ada/looms.git
    export FAKE_GIT_CRED_USER=ada FAKE_GIT_CRED_PASS=s3cret
    run bash "$LAUNCH" --sandbox-docker --sandbox-ro "$DATA" --sandbox-git
    assert_success
    argv_has "$DATA:$DATA:ro"
    argv_has "$FAKE_SOCK:/var/run/docker.sock"
    argv_has "SANDBOX_GIT_TOKEN=s3cret"
    : > "$FAKE_DOCKER_ARGV"
    run bash "$LAUNCH" --sandbox-git --sandbox-docker "--sandbox-ro=$DATA"
    assert_success
    argv_has "$DATA:$DATA:ro"
    argv_has "SANDBOX_GIT_TOKEN=s3cret"
}

@test "--sandbox-ro composes with --sandbox-tmux by re-emitting the resolved flag" {
    ro_setup
    # Given relative, carried absolute: the session re-runs the launcher, and
    # %q keeps the space in the path as one argument.
    run bash "$LAUNCH" --sandbox-ro "../shared data" --sandbox-tmux
    assert_success
    tmux_log_has "--sandbox-ro=$(printf '%q' "$DATA")"
    refute_tmux_log "../shared"
}

@test "a refused path creates no tmux session" {
    ro_setup
    run bash "$LAUNCH" --sandbox-ro "$TESTDIR/nope" --sandbox-tmux
    assert_failure
    assert_output_contains "does not exist"
    refute_tmux_log "new-session"
}

@test "--sandbox-doctor lists read-only mounts, and says why one would be refused" {
    ro_setup
    run bash "$LAUNCH" --sandbox-ro "$DATA" --sandbox-ro "$TESTDIR/nope" --sandbox-ro . --sandbox-doctor
    assert_success
    assert_output_contains "read-only mount     $DATA -> $DATA"
    assert_output_contains "$TESTDIR/nope REFUSED — does not exist"
    assert_output_contains ". REFUSED — "
    assert_output_contains "is the project"
    refute_docker_ran 'docker run -it'
}

@test "the codex launcher takes --sandbox-ro too" {
    bash "$(installer codex)" >/dev/null 2>&1
    ro_setup
    FAKE_CODEX_VERSION=1.2.3 run bash "$HOME/.local/bin/codex-sandbox" --sandbox-ro "$DATA"
    assert_success
    argv_has "$DATA:$DATA:ro"
    argv_has "codex-config-testuser:/home/agent/.codex"
    argv_lacks "--sandbox-ro"
}
