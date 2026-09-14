#!/usr/bin/env bats
# End-to-end against a real Docker daemon. Builds real images, so it is slow;
# tools/test.sh skips this tier when no daemon is reachable.
#
# Everything is namespaced with a throwaway user so it can never collide with
# (or clean up) the images and volumes of whoever is running it.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup_file() {
    if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
        skip "no reachable docker daemon"
    fi
    export E2E_USER="e2e$$"
    export E2E_HOME="${BATS_FILE_TMPDIR:-/tmp}/e2e-home"
    mkdir -p "$E2E_HOME"
}

teardown_file() {
    command -v docker >/dev/null 2>&1 || return 0
    docker info >/dev/null 2>&1 || return 0
    for agent in claude codex; do
        docker image rm -f "$agent-sandbox-$E2E_USER" >/dev/null 2>&1 || true
    done
    for vol in claude-config claude-local codex-config; do
        docker volume rm -f "$vol-$E2E_USER" >/dev/null 2>&1 || true
    done
    rm -rf "$E2E_HOME"
}

setup() {
    command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || skip "no reachable docker daemon"
    export HOME="$E2E_HOME"
    export SANDBOX_FAKE_USER="$E2E_USER"
    export XDG_DATA_HOME="$E2E_HOME/.local/share"
    export SANDBOX_NO_UPDATE_CHECK=1
    export NO_COLOR=1
    CLAUDE_IMAGE="claude-sandbox-$E2E_USER"
    CODEX_IMAGE="codex-sandbox-$E2E_USER"
}

file_sha() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
    else shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

fail_with() { printf '%s\n' "$1" >&2; printf -- '--- output ---\n%s\n' "${output:-<none>}" >&2; return 1; }
assert_success() { [ "$status" -eq 0 ] || fail_with "expected success, got $status"; }
assert_output_contains() { case "$output" in *"$1"*) return 0 ;; *) fail_with "expected output to contain: $1" ;; esac; }

@test "e2e: the Claude installer builds a real image" {
    run bash "$REPO_ROOT/install/claude.sh" --no-path-edit
    assert_success
    docker image inspect "$CLAUDE_IMAGE" >/dev/null
    [ -f "$HOME/claude-sandbox/Dockerfile" ]
    [ -x "$HOME/.local/bin/claude-sandbox" ]
}

@test "e2e: the image's agent user has the host UID — the bug this repo kept hitting" {
    run docker run --rm "$CLAUDE_IMAGE" id -u
    assert_success
    [ "$output" = "$(id -u)" ]
    run docker run --rm "$CLAUDE_IMAGE" id -g
    [ "$output" = "$(id -g)" ]
}

@test "e2e: the freshness labels are on the image" {
    run docker image inspect -f '{{index .Config.Labels "sandbox.agent_uid"}}' "$CLAUDE_IMAGE"
    [ "$output" = "$(id -u)" ]
    run docker image inspect -f '{{index .Config.Labels "sandbox.dockerfile_sha"}}' "$CLAUDE_IMAGE"
    [ "$output" = "$(file_sha "$HOME/claude-sandbox/Dockerfile")" ]
}

@test "e2e: the project is mounted at its host path, and is writable there" {
    # The mount the launchers actually use. The container's cwd being the
    # host's path is the whole point: Claude Code keys its memory and session
    # transcripts on it, and Codex records it in every rollout, so a fixed
    # /workspace made every project on the machine one project. The space in
    # the directory name is deliberate — it has to survive as one argument.
    local proj="$BATS_TEST_TMPDIR/some project"
    mkdir -p "$proj"
    run docker run --rm -v "$proj:$proj" -w "$proj" --cap-drop=ALL \
        --security-opt=no-new-privileges "$CLAUDE_IMAGE" \
        sh -c 'pwd; echo written-by-agent > proof.txt'
    assert_success
    assert_output_contains "$proj"
    [ "$(cat "$proj/proof.txt")" = "written-by-agent" ]
    [ -O "$proj/proof.txt" ]
}

@test "e2e: two projects mounted this way have two different cwds" {
    local a="$BATS_TEST_TMPDIR/alpha" b="$BATS_TEST_TMPDIR/beta" out_a out_b
    mkdir -p "$a" "$b"
    out_a=$(docker run --rm -v "$a:$a" -w "$a" "$CLAUDE_IMAGE" pwd)
    out_b=$(docker run --rm -v "$b:$b" -w "$b" "$CLAUDE_IMAGE" pwd)
    [ "$out_a" = "$a" ] || fail_with "expected cwd $a, got $out_a"
    [ "$out_b" = "$b" ] || fail_with "expected cwd $b, got $out_b"
    [ "$out_a" != "$out_b" ] || fail_with "both projects reported the same cwd"
}

@test "e2e: claude actually runs inside the image" {
    run docker run --rm "$CLAUDE_IMAGE" claude --version
    assert_success
    assert_output_contains "."
}

@test "e2e: the everyday toolchains are present" {
    run docker run --rm "$CLAUDE_IMAGE" sh -c 'git --version && python3 --version && cargo --version && rg --version && jq --version'
    assert_success
}

@test "e2e: the docker CLI is in the image, and inert without a socket" {
    run docker run --rm "$CLAUDE_IMAGE" sh -c 'docker --version && docker buildx version && docker compose version'
    assert_success
    # Shipped unconditionally, so it must be harmless when --sandbox-docker is
    # not given: no socket, no daemon, and a clear error rather than a hang.
    run docker run --rm "$CLAUDE_IMAGE" docker ps
    [ "$status" -ne 0 ] || fail_with "docker ps worked with no socket mounted"
    assert_output_contains "docker.sock"
}

@test "e2e: the volumes exist and are owned by the host user" {
    docker volume inspect "claude-config-$E2E_USER" >/dev/null
    docker volume inspect "claude-local-$E2E_USER" >/dev/null
    run docker run --rm --user 0:0 -v "claude-config-$E2E_USER:/v" "$CLAUDE_IMAGE" stat -c %u /v
    assert_success
    [ "$output" = "$(id -u)" ]
}

@test "e2e: re-running the installer rebuilds nothing" {
    run bash "$REPO_ROOT/install/claude.sh" --no-path-edit
    assert_success
    assert_output_contains "is up to date"
}

@test "e2e: --check reports a healthy install" {
    PATH="$HOME/.local/bin:$PATH" run bash "$REPO_ROOT/install/claude.sh" --check --no-path-edit
    assert_success
    assert_output_contains "image               current"
}

@test "e2e: --sandbox-doctor agrees with reality" {
    run "$HOME/.local/bin/claude-sandbox" --sandbox-doctor
    assert_success
    assert_output_contains "$CLAUDE_IMAGE"
    assert_output_contains "image agent UID     $(id -u)"
}

@test "e2e: a shipped Dockerfile change triggers exactly one rebuild" {
    # A real upgrade arrives as a *new installer* carrying a different embedded
    # Dockerfile. Editing the installed copy instead is a hand-edit, which the
    # installer is supposed to back up and overwrite — a different path, covered
    # in the integration suite.
    awk '{ print } /^ENV CLAUDE_CONFIG_DIR=/ { print "# e2e upgrade marker" }' \
        "$REPO_ROOT/install/claude.sh" > "$BATS_TEST_TMPDIR/claude-v2.sh"
    grep -q 'e2e upgrade marker' "$BATS_TEST_TMPDIR/claude-v2.sh" \
        || fail_with "the v2 fixture did not change the embedded Dockerfile"

    run bash "$BATS_TEST_TMPDIR/claude-v2.sh" --no-path-edit
    assert_success
    assert_output_contains "the Dockerfile changed"
    grep -q 'e2e upgrade marker' "$HOME/claude-sandbox/Dockerfile"

    # Every layer is a cache hit, but the labels are rewritten, so the next run
    # must consider the image current again.
    run bash "$BATS_TEST_TMPDIR/claude-v2.sh" --no-path-edit
    assert_success
    assert_output_contains "is up to date"
}

@test "e2e: a hand-edited Dockerfile is backed up and the shipped one restored" {
    printf '\n# a local edit\n' >> "$HOME/claude-sandbox/Dockerfile"
    run bash "$REPO_ROOT/install/claude.sh" --no-path-edit
    assert_success
    assert_output_contains "was modified locally"
    grep -q 'a local edit' "$HOME"/claude-sandbox/Dockerfile.bak.*
    ! grep -q 'a local edit' "$HOME/claude-sandbox/Dockerfile"
}

@test "e2e: a UID-mismatched volume is repaired without losing its contents" {
    docker run --rm --user 0:0 -v "claude-config-$E2E_USER:/v" "$CLAUDE_IMAGE" \
        sh -c 'echo secret-token > /v/auth.json && chown -R 0:0 /v'
    run bash "$REPO_ROOT/install/claude.sh" --no-path-edit
    assert_success
    assert_output_contains "owned by UID 0"
    run docker run --rm --user 0:0 -v "claude-config-$E2E_USER:/v" "$CLAUDE_IMAGE" cat /v/auth.json
    [ "$output" = "secret-token" ]
    run docker run --rm --user 0:0 -v "claude-config-$E2E_USER:/v" "$CLAUDE_IMAGE" stat -c %u /v/auth.json
    [ "$output" = "$(id -u)" ]
}

@test "e2e: the Codex installer builds, seeds config.toml and pins a version" {
    run bash "$REPO_ROOT/install/codex.sh" --no-path-edit
    assert_success
    docker image inspect "$CODEX_IMAGE" >/dev/null
    [ -f "$HOME/codex-sandbox/config.toml" ]
    run docker run --rm --user 0:0 -v "codex-config-$E2E_USER:/cfg" "$CODEX_IMAGE" cat /cfg/config.toml
    assert_success
    assert_output_contains 'approval_policy = "never"'
}

@test "e2e: codex runs inside its image and its volume is agent-owned" {
    run docker run --rm "$CODEX_IMAGE" codex --version
    assert_success
    run docker run --rm --user 0:0 -v "codex-config-$E2E_USER:/cfg" "$CODEX_IMAGE" stat -c %u /cfg/config.toml
    [ "$output" = "$(id -u)" ]
}


# What the fake-docker tier cannot prove: that the environment the launcher
# builds is one a *real* git, in the real image, actually accepts. That the
# launcher emits exactly these arguments is asserted in launcher.bats; here we
# check the other half of the contract, against a real container.
#
# The launcher itself is not invoked: it runs `docker run -it`, which cannot
# attach under bats (stdin is not a terminal). The env below is verbatim what
# launcher.bats asserts on.
#
# GIT_CONFIG_COUNT needs git >= 2.31, so a commit succeeding here is also the
# check that the image's git is new enough.
@test "e2e: the identity env the launcher passes makes a real commit work" {
    local proj="$BATS_TEST_TMPDIR/repo"
    mkdir -p "$proj"
    git -C "$proj" init -q
    printf 'hello\n' > "$proj/f.txt"
    git -C "$proj" add f.txt

    run docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp \
        -v "$proj:/workspace" \
        -e GIT_CONFIG_COUNT=2 \
        -e GIT_CONFIG_KEY_0=user.name  -e "GIT_CONFIG_VALUE_0=E2E Tester" \
        -e GIT_CONFIG_KEY_1=user.email -e GIT_CONFIG_VALUE_1=e2e@example.com \
        --cap-drop=ALL --security-opt=no-new-privileges \
        "$CLAUDE_IMAGE" git commit -m "from the sandbox"
    assert_success

    run git -C "$proj" log -1 --format='%an <%ae>'
    assert_success
    [ "$output" = "E2E Tester <e2e@example.com>" ] \
        || fail_with "commit landed with the wrong author: $output"

    # And the config reads back, which GIT_AUTHOR_* would not give us.
    run docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp \
        -v "$proj:/workspace" \
        -e GIT_CONFIG_COUNT=2 \
        -e GIT_CONFIG_KEY_0=user.name  -e "GIT_CONFIG_VALUE_0=E2E Tester" \
        -e GIT_CONFIG_KEY_1=user.email -e GIT_CONFIG_VALUE_1=e2e@example.com \
        "$CLAUDE_IMAGE" git config --get user.email
    assert_success
    [ "$output" = "e2e@example.com" ] || fail_with "config did not read back: $output"
}

@test "e2e: with no identity the same commit fails, as it did before this feature" {
    local proj="$BATS_TEST_TMPDIR/repo-noident"
    mkdir -p "$proj"
    git -C "$proj" init -q
    printf 'hello\n' > "$proj/f.txt"
    git -C "$proj" add f.txt

    run docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp \
        -v "$proj:/workspace" \
        --cap-drop=ALL --security-opt=no-new-privileges \
        "$CLAUDE_IMAGE" git commit -m nope
    [ "$status" -ne 0 ] || fail_with "expected the commit to fail without an identity"
    assert_output_contains "Please tell me who you are"
}

# The credential helper is a shell snippet that survives two levels of embedding
# (build.sh splices it into a quoted heredoc inside the installer). This proves
# it arrives intact and that a real git will call it — and that it is scoped to
# one host, so another host gets nothing.
@test "e2e: the forwarded credential helper works and is scoped to one host" {
    local helper
    helper='!f(){ test "$1" = get && printf "username=%s\npassword=%s\n" "$SANDBOX_GIT_USER" "$SANDBOX_GIT_TOKEN"; }; f'

    run docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp \
        -e SANDBOX_GIT_USER=ada -e SANDBOX_GIT_TOKEN=s3cret \
        -e GIT_CONFIG_COUNT=1 \
        -e "GIT_CONFIG_KEY_0=credential.https://github.com.helper" \
        -e "GIT_CONFIG_VALUE_0=$helper" \
        "$CLAUDE_IMAGE" sh -c 'printf "protocol=https\nhost=github.com\n\n" | git credential fill'
    assert_success
    assert_output_contains "username=ada"
    assert_output_contains "password=s3cret"

    run docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp \
        -e SANDBOX_GIT_USER=ada -e SANDBOX_GIT_TOKEN=s3cret \
        -e GIT_TERMINAL_PROMPT=0 \
        -e GIT_CONFIG_COUNT=1 \
        -e "GIT_CONFIG_KEY_0=credential.https://github.com.helper" \
        -e "GIT_CONFIG_VALUE_0=$helper" \
        "$CLAUDE_IMAGE" sh -c 'printf "protocol=https\nhost=gitlab.com\n\n" | git credential fill'
    [ "$status" -ne 0 ] || fail_with "another host was served the credential"
    case "$output" in *s3cret*) fail_with "the token leaked to another host" ;; esac
}

# --- --sandbox-docker against the real daemon ------------------------------
# The socket path the launcher would hand to --sandbox-docker, or non-zero when
# this host's daemon is not on a unix socket (ssh://, tcp://, a Windows pipe).
e2e_docker_sock() {
    local ep
    ep=$(docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null | head -1 | tr -d ' \r\n')
    [ -n "$ep" ] || ep=${DOCKER_HOST:-unix:///var/run/docker.sock}
    case "$ep" in unix://*) printf '%s' "${ep#unix://}" ;; *) return 1 ;; esac
}

# The group as the daemon presents it once mounted — not the host's view of the
# same file, which Docker Desktop makes wrong.
e2e_sock_gid() {
    docker run --rm -v "$1:/var/run/docker.sock" "$CLAUDE_IMAGE" stat -c %g /var/run/docker.sock 2>/dev/null | head -1 | tr -d ' \r\n'
}

@test "e2e: the mounted socket really reaches the daemon, hardening and all" {
    local sock gid
    sock=$(e2e_docker_sock) || skip "this daemon is not on a unix socket"
    gid=$(e2e_sock_gid "$sock")
    [ -n "$gid" ] || skip "could not read the socket's group"
    # --cap-drop=ALL and no-new-privileges stay on: a supplementary group is
    # applied before capabilities are dropped, so it still works.
    run docker run --rm -v "$sock:/var/run/docker.sock" --group-add "$gid" \
        --cap-drop=ALL --security-opt=no-new-privileges "$CLAUDE_IMAGE" docker version -f '{{.Server.Version}}'
    assert_success
}

@test "e2e: a container the agent starts sees the project at the same path" {
    # The whole feature rests on this. Because the project is mounted at its
    # host path, a -v issued *inside* the session names a directory the host
    # daemon can resolve. Under a fixed /workspace mount this silently mounted
    # the wrong thing, so it is a regression guard for container_workdir too.
    local sock gid proj
    sock=$(e2e_docker_sock) || skip "this daemon is not on a unix socket"
    gid=$(e2e_sock_gid "$sock")
    [ -n "$gid" ] || skip "could not read the socket's group"
    proj="$BATS_TEST_TMPDIR/dood project"
    mkdir -p "$proj"
    echo "written-on-the-host" > "$proj/proof.txt"
    # The sibling image is the sandbox image itself: already local, so the test
    # neither pulls nor depends on a registry.
    run docker run --rm -v "$proj:$proj" -w "$proj" \
        -v "$sock:/var/run/docker.sock" --group-add "$gid" \
        -e "SIBLING=$CLAUDE_IMAGE" \
        --cap-drop=ALL --security-opt=no-new-privileges "$CLAUDE_IMAGE" \
        sh -c 'docker run --rm -v "$PWD:/m" "$SIBLING" cat /m/proof.txt'
    assert_success
    assert_output_contains "written-on-the-host"
}

# --- --sandbox-ro against the real daemon ----------------------------------
# The launcher's own argv is pinned by the integration tests; these check that
# the mount docker actually makes behaves as promised.

@test "e2e: a read-only mount can be read, cannot be written, and leaves the project writable" {
    local data="$BATS_TEST_TMPDIR/shared data" proj="$BATS_TEST_TMPDIR/ro project"
    mkdir -p "$data" "$proj"
    echo shared-on-the-host > "$data/in.txt"
    run docker run --rm -v "$proj:$proj" -w "$proj" -v "$data:$data:ro" \
        --cap-drop=ALL --security-opt=no-new-privileges "$CLAUDE_IMAGE" \
        sh -c 'cat "$1/in.txt"; touch "$1/out.txt" 2>&1; echo written-by-agent > proof.txt' sh "$data"
    assert_success
    assert_output_contains "shared-on-the-host"
    assert_output_contains "Read-only file system"
    [ ! -e "$data/out.txt" ] || fail_with "the read-only mount took a write"
    [ "$(cat "$proj/proof.txt")" = "written-by-agent" ]
}

@test "e2e: a read-only path inside the project pins that part, and only that part" {
    # The launcher allows a --sandbox-ro path under the project. It works
    # because docker applies the deeper mount on top of the shallower one; if
    # that ever changes, the launcher must start refusing such paths.
    local proj="$BATS_TEST_TMPDIR/nested project"
    mkdir -p "$proj/fixtures"
    echo fixture > "$proj/fixtures/a.txt"
    run docker run --rm -v "$proj:$proj" -w "$proj" -v "$proj/fixtures:$proj/fixtures:ro" \
        --cap-drop=ALL --security-opt=no-new-privileges "$CLAUDE_IMAGE" \
        sh -c 'cat fixtures/a.txt; touch fixtures/b.txt 2>&1; echo written-by-agent > proof.txt'
    assert_success
    assert_output_contains "fixture"
    assert_output_contains "Read-only file system"
    [ ! -e "$proj/fixtures/b.txt" ] || fail_with "the nested read-only mount took a write"
    [ "$(cat "$proj/proof.txt")" = "written-by-agent" ]
}

@test "e2e: --sandbox-doctor reports a read-only mount as it would be made" {
    local data="$BATS_TEST_TMPDIR/doctor data"
    mkdir -p "$data"
    run "$HOME/.local/bin/claude-sandbox" --sandbox-ro "$data" --sandbox-doctor
    assert_success
    assert_output_contains "read-only mount     $data -> $data"
}

@test "e2e: uninstall removes the image but keeps the login volumes" {
    run bash "$REPO_ROOT/install/codex.sh" --uninstall
    assert_success
    run docker image inspect "$CODEX_IMAGE"
    [ "$status" -ne 0 ]
    docker volume inspect "codex-config-$E2E_USER" >/dev/null
}

@test "e2e: uninstall --purge --yes finally removes the volumes" {
    run bash "$REPO_ROOT/install/claude.sh" --no-path-edit
    run bash "$REPO_ROOT/install/claude.sh" --uninstall --purge --yes
    assert_success
    run docker volume inspect "claude-config-$E2E_USER"
    [ "$status" -ne 0 ]
}
