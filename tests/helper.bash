# Shared bats setup: a throwaway HOME, a fake docker on PATH, and assertions.
# Nothing here touches the real machine — every test runs against a temp tree.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

common_setup() {
    TESTDIR=$(mktemp -d "${BATS_TMPDIR:-/tmp}/sandbox-test.XXXXXX")
    export TESTDIR
    export HOME="$TESTDIR/home"
    mkdir -p "$HOME"
    export XDG_DATA_HOME="$HOME/.local/share"
    export XDG_CACHE_HOME="$HOME/.cache"
    export FAKE_DOCKER_STATE="$TESTDIR/dockerstate"
    export FAKE_DOCKER_LOG="$TESTDIR/docker.log"
    mkdir -p "$FAKE_DOCKER_STATE"
    : > "$FAKE_DOCKER_LOG"
    export PATH="$REPO_ROOT/tests/fixtures/fakebin:$PATH"
    export SANDBOX_FAKE_USER=testuser
    # Fixed identity so build-args and ownership assertions are deterministic
    # regardless of who runs the suite.
    export SANDBOX_FAKE_UID=4242
    export SANDBOX_FAKE_GID=4343
    export FAKE_DOCKER_NEW_VOL_UID=4242
    export SHELL=/bin/bash
    # Pin platform detection so the suite behaves identically on a CI runner
    # and on the WSL box this was written on.
    export SANDBOX_OS_RELEASE="$REPO_ROOT/tests/fixtures/osrelease/ubuntu"
    export SANDBOX_PROC_VERSION="$REPO_ROOT/tests/fixtures/procversion-linux"
    export NO_COLOR=1
    # Real network calls have no place in a unit or integration test.
    export SANDBOX_NO_UPDATE_CHECK=1
    # Pin the whole git surface. A throwaway HOME is not enough on its own:
    # XDG_CONFIG_HOME, /etc/gitconfig and inherited GIT_* variables all reach
    # around it, and half the launcher tests run with cwd inside this very
    # repository. Left unpinned, a developer's real identity — or, with
    # credential.helper=store, a real token — could be read by the launcher and
    # land in $FAKE_DOCKER_ARGV, which fail_with dumps into the CI log.
    export XDG_CONFIG_HOME="$HOME/.config"
    export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
    export GIT_CONFIG_NOSYSTEM=1
    export GIT_TERMINAL_PROMPT=0
    unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
    unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
    unset GH_TOKEN GITHUB_TOKEN
    # The fake git on PATH answers from these; tests that want an identity or a
    # credential set them explicitly.
    unset FAKE_GIT_NAME FAKE_GIT_EMAIL FAKE_GIT_ORIGIN
    unset FAKE_GIT_CRED_USER FAKE_GIT_CRED_PASS
    unset FAKE_GH_TOKEN
}

common_teardown() {
    [ -n "${TESTDIR:-}" ] && rm -rf "$TESTDIR"
    return 0
}

installer() { printf '%s/install/%s.sh' "$REPO_ROOT" "$1"; }

# macOS has shasum, not sha256sum. The product feature-detects this; the tests
# have to as well, or the macOS CI job fails on the harness rather than the code.
file_sha() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
    else shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

# Run an installer with the given agent and flags.
run_install() {
    local agent=$1; shift
    run bash "$(installer "$agent")" "$@"
}

docker_log() { cat "$FAKE_DOCKER_LOG"; }

# The current PATH with one directory removed. Replacing PATH wholesale with a
# guessed list (say /usr/bin:/bin) is how a test ends up without `rm` on a
# system that puts it somewhere else — macOS keeps /bin/rm, not /usr/bin/rm —
# and bats' own cleanup then fails even though every test passed.
path_excluding() {
    printf '%s' "$PATH" | tr ':' '\n' | grep -vxF "$1" | paste -sd: -
}

# A PATH holding everything the installers need EXCEPT one named tool.
#
# Simulating "docker is not installed" by trimming PATH to /usr/bin:/bin only
# works on a machine where docker happens to live elsewhere. On any CI runner
# (and on any developer box with Docker Engine) /usr/bin/docker exists, and the
# test silently stops testing what it claims to. Build the PATH explicitly.
path_without() {
    local skip=$1 t dir="$TESTDIR/without-$skip"
    mkdir -p "$dir"
    for t in docker curl tmux wsl.exe git gh; do
        [ "$t" = "$skip" ] && continue
        ln -sf "$REPO_ROOT/tests/fixtures/fakebin/$t" "$dir/$t"
    done
    for t in bash sh env id date tr cut head tail find mkdir rmdir rm cp mv ln chmod \
             stat cat grep sed awk sort uniq wc basename dirname mktemp df cksum \
             sha256sum shasum touch tee pwd sleep timeout uname expr getent xargs pwsh; do
        [ "$t" = "$skip" ] && continue
        command -v "$t" >/dev/null 2>&1 && ln -sf "$(command -v "$t")" "$dir/$t"
    done
    printf '%s' "$dir"
}

# --- assertions ------------------------------------------------------------

fail_with() {
    printf '%s\n' "$1" >&2
    printf -- '--- output ---\n%s\n--------------\n' "${output:-<none>}" >&2
    return 1
}

assert_success() {
    [ "$status" -eq 0 ] || fail_with "expected success, got exit $status"
}

assert_failure() {
    [ "$status" -ne 0 ] || fail_with "expected failure, got exit 0"
}

assert_status() {
    [ "$status" -eq "$1" ] || fail_with "expected exit $1, got $status"
}

assert_output_contains() {
    case "$output" in
        *"$1"*) return 0 ;;
        *) fail_with "expected output to contain: $1" ;;
    esac
}

refute_output_contains() {
    case "$output" in
        *"$1"*) fail_with "expected output NOT to contain: $1" ;;
        *) return 0 ;;
    esac
}

assert_file_exists() { [ -f "$1" ] || fail_with "expected file to exist: $1"; }
assert_file_missing() { [ ! -e "$1" ] || fail_with "expected file to be gone: $1"; }
assert_executable() { [ -x "$1" ] || fail_with "expected an executable file: $1"; }

assert_file_mode() {
    local want=$1 file=$2 got
    got=$(stat -c '%a' "$file" 2>/dev/null || stat -f '%Lp' "$file")
    [ "$got" = "$want" ] || fail_with "expected mode $want on $file, got $got"
}

assert_file_contains() {
    grep -qF -- "$2" "$1" || fail_with "expected $1 to contain: $2"
}

refute_file_contains() {
    grep -qF -- "$2" "$1" && fail_with "expected $1 NOT to contain: $2"
    return 0
}

assert_docker_ran() {
    grep -qF -- "$1" "$FAKE_DOCKER_LOG" \
        || { printf -- '--- docker log ---\n%s\n' "$(cat "$FAKE_DOCKER_LOG")" >&2
             fail_with "expected a docker call containing: $1"; }
}

refute_docker_ran() {
    if grep -qF -- "$1" "$FAKE_DOCKER_LOG"; then
        printf -- '--- docker log ---\n%s\n' "$(cat "$FAKE_DOCKER_LOG")" >&2
        fail_with "expected NO docker call containing: $1"
    fi
    return 0
}

count_docker_calls() { grep -cF -- "$1" "$FAKE_DOCKER_LOG" || true; }

# assert_session_flag FLAG IMAGE — the session's own `docker run -it` in
# $FAKE_DOCKER_ARGV carries FLAG *before* IMAGE. After the image it would be an
# argument to the agent, not to docker, so a bare grep for it proves nothing.
# Every session run in the file must carry it, and there must be at least one.
assert_session_flag() {
    awk -v flag="$1" -v img="$2" '
        /^--- invocation ---$/ { n = 0; main = 0; seen = 0; next }
        { n++ }
        n == 1 { first = $0 }
        n == 2 && first == "run" && $0 == "-it" { main = 1 }
        main && $0 == flag { seen = 1 }
        main && $0 == img { runs++; if (!seen) bad = 1; main = 0 }
        END { exit !(runs > 0 && !bad) }
    ' "$FAKE_DOCKER_ARGV" \
        || { printf -- '--- argv ---\n%s\n' "$(cat "$FAKE_DOCKER_ARGV")" >&2
             fail_with "expected every session docker run to pass $1 before $2"; }
}

# container_env_has NAME=value — the last docker invocation (the session's own
# `docker run`, which the launcher execs last) hands the container exactly this
# variable. Reads $FAKE_DOCKER_ENV, where the fake docker resolves a bare
# `-e NAME` from its environment just as real docker does.
container_env_has() {
    awk -v want="$1" '
        /^--- invocation ---$/ { n = 0; next }
        { line[++n] = $0 }
        END { for (i = 1; i <= n; i++) if (line[i] == want) exit 0; exit 1 }
    ' "$FAKE_DOCKER_ENV" \
        || { printf -- '--- container env ---\n%s\n' "$(cat "$FAKE_DOCKER_ENV")" >&2
             fail_with "expected the container to receive: $1"; }
}
