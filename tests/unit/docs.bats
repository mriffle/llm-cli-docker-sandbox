#!/usr/bin/env bats
# Documentation is part of the deliverable: these check that what the README
# promises is what the shipped scripts actually do.

load '../helper'

setup() { common_setup; }
teardown() { common_teardown; }

RAW_BASE="https://raw.githubusercontent.com/mriffle/llm-cli-docker-sandbox/main"

@test "the version in VERSION is stamped into all four installers" {
    local v
    v=$(tr -d ' \n' < "$REPO_ROOT/VERSION")
    grep -q "INSTALLER_VERSION=\"$v\"" "$REPO_ROOT/install/claude.sh"
    grep -q "INSTALLER_VERSION=\"$v\"" "$REPO_ROOT/install/codex.sh"
    grep -q "InstallerVersion = '$v'" "$REPO_ROOT/install/claude.ps1"
    grep -q "InstallerVersion = '$v'" "$REPO_ROOT/install/codex.ps1"
}

@test "the version is stamped into the embedded launchers too" {
    local v
    v=$(tr -d ' \n' < "$REPO_ROOT/VERSION")
    grep -q "SANDBOX_VERSION=\"$v\"" "$REPO_ROOT/install/claude.sh"
    grep -q "SandboxVersion = '$v'" "$REPO_ROOT/install/claude.ps1"
}

@test "every install URL in the docs points at a file that exists" {
    local url path
    grep -oh "$RAW_BASE/install/[a-z]*\.\(sh\|ps1\)" \
        "$REPO_ROOT/README.md" "$REPO_ROOT/WINDOWS.md" "$REPO_ROOT/MANUAL.md" \
        | sort -u | while read -r url; do
            path="$REPO_ROOT/${url#"$RAW_BASE"/}"
            [ -f "$path" ] || fail_with "docs reference a missing file: $url"
        done
}

@test "the docs' raw base matches the one compiled into the installers" {
    grep -q "RAW_BASE=\"$RAW_BASE\"" "$REPO_ROOT/install/claude.sh"
    grep -q "RawBase          = '$RAW_BASE'" "$REPO_ROOT/install/claude.ps1"
}

@test "every --sandbox-* flag the README documents is handled by the launcher" {
    local flag
    for flag in $(grep -oh -- '--sandbox-[a-z-]*' "$REPO_ROOT/README.md" | sort -u); do
        grep -qE -- "[[:space:]]$flag[|)]" "$REPO_ROOT/install/claude.sh" \
            || fail_with "README documents $flag but the launcher does not handle it"
    done
}

@test "every installer flag the README documents is accepted" {
    run_install claude --check
    local flag
    for flag in --check --force --uninstall --purge --no-build --no-path-edit --yes --quiet --help; do
        grep -qE -- "[[:space:]]$flag[|)]" "$REPO_ROOT/install/claude.sh" \
            || fail_with "README documents $flag but parse_args does not accept it"
    done
    for flag in --prefix --src-dir; do
        grep -qE -- "[[:space:]]$flag[|)=]" "$REPO_ROOT/install/claude.sh" \
            || fail_with "README documents $flag but parse_args does not accept it"
    done
}

@test "every -Flag the README documents is a real PowerShell parameter" {
    local flag
    for flag in Check Force Uninstall Purge Prefix PrintPath; do
        grep -q "\[switch\]\$$flag\|\[string\]\$$flag" "$REPO_ROOT/install/claude.ps1" \
            || fail_with "README documents -$flag but claude.ps1 has no such parameter"
    done
}

# The README tells people to wrap the installer in eval. That only works while
# the installer actually emits the line, and while nothing else reaches stdout.
@test "the eval form the README documents is a thing the installers support" {
    grep -qF 'eval "$(curl -fsSL' "$REPO_ROOT/README.md" \
        || fail_with "README no longer documents the eval install form"
    local agent
    for agent in claude codex; do
        grep -q 'emit_shell_eval' "$REPO_ROOT/install/$agent.sh" \
            || fail_with "$agent.sh does not emit the PATH line the README promises"
        grep -qF 'tee "$log" >&2' "$REPO_ROOT/install/$agent.sh" \
            || fail_with "$agent.sh lets the docker build stream reach stdout, breaking eval"
    done
}

@test "the README's paste-me PATH line is the one the installer prints" {
    grep -qF 'export PATH="$HOME/.local/bin:$PATH"' "$REPO_ROOT/README.md" \
        || fail_with "README no longer shows the export line the installer prints"
    grep -qF 'PATH_EXPORT_LINE="export PATH=' "$REPO_ROOT/install/claude.sh" \
        || fail_with "the installer no longer builds that line"
}

@test "the persistence table names the volumes the installers actually create" {
    local vol
    for vol in claude-config claude-local codex-config; do
        grep -qF "$vol" "$REPO_ROOT/README.md" || fail_with "README omits the $vol volume"
    done
    grep -q 'VOLUME_BASENAMES="claude-config claude-local"' "$REPO_ROOT/install/claude.sh"
    grep -q 'VOLUME_BASENAMES="codex-config"' "$REPO_ROOT/install/codex.sh"
}

@test "MANUAL.md still carries the hand-build path it is there to document" {
    grep -q 'FROM node:24-slim' "$REPO_ROOT/MANUAL.md"
    grep -q 'docker build --build-arg UID' "$REPO_ROOT/MANUAL.md"
    grep -q 'approval_policy = "never"' "$REPO_ROOT/MANUAL.md"
}

@test "the Dockerfiles the installers embed match the ones MANUAL.md documents" {
    # Not byte-identical (the shipped ones carry a managed-by header), but the
    # build instructions themselves must not drift apart.
    local line
    while IFS= read -r line; do
        grep -qF "$line" "$REPO_ROOT/MANUAL.md" \
            || fail_with "MANUAL.md is missing a Dockerfile line the installer ships: $line"
    done < <(grep -E '^(FROM|RUN|ENV|ARG|USER|WORKDIR|COPY) ' "$REPO_ROOT/src/assets/claude.Dockerfile")
}

@test "the README's security notes describe the socket as it now behaves" {
    # From v1.2.0 the images ship the Docker CLI and --sandbox-docker can mount
    # the host socket. The old note promised the opposite, which would leave a
    # false claim in the section people read to decide whether to trust this.
    refute_file_contains "$REPO_ROOT/README.md" 'The images contain no Docker client'
    assert_file_contains "$REPO_ROOT/README.md" '--sandbox-docker'
    grep -qF -- '--sandbox-docker' "$REPO_ROOT/install/claude.ps1" \
        || fail_with "the PowerShell launcher never mentions --sandbox-docker"
}

@test "the README documents the mount the launchers actually use" {
    # The fixed /workspace mount gave every project one agent identity; the
    # README has to describe the mirrored mount and the way back out of it.
    assert_file_contains "$REPO_ROOT/README.md" 'SANDBOX_WORKDIR'
    grep -qF -- 'container_workdir' "$REPO_ROOT/install/claude.sh" \
        || fail_with "README documents SANDBOX_WORKDIR but the launcher has no such override"
    grep -qF -- 'SANDBOX_WORKDIR' "$REPO_ROOT/install/claude.ps1" \
        || fail_with "the PowerShell launcher is missing the SANDBOX_WORKDIR override"
    refute_file_contains "$REPO_ROOT/README.md" '| `/workspace` | bind mount'
}

@test "CLAUDE.md documents the constraints that have actually broken the build" {
    local f="$REPO_ROOT/CLAUDE.md"
    assert_file_exists "$f"
    # The generated-file rule is the one a contributor must not miss.
    assert_file_contains "$f" 'install/` is generated'
    assert_file_contains "$f" 'tools/build.sh'
    # Each of these corresponds to a real failure this repo has already had.
    assert_file_contains "$f" 'bash 3.2'
    assert_file_contains "$f" 'here-document nested inside'
    assert_file_contains "$f" 'must not assume Linux'
    assert_file_contains "$f" 'jq'
}

@test "CLAUDE.md names the tools and tiers that actually exist" {
    local f="$REPO_ROOT/CLAUDE.md" t
    for t in tools/build.sh tools/test.sh tools/fetch-tools.sh tools/check-portability.sh; do
        assert_file_contains "$f" "$t"
        [ -x "$REPO_ROOT/$t" ] || fail_with "CLAUDE.md names $t but it is not executable"
    done
    # Every SANDBOX_FAKE_* seam it advertises must exist in the shipped code.
    local seam
    for seam in SANDBOX_FAKE_UID SANDBOX_FAKE_UNAME_S SANDBOX_OS_RELEASE SANDBOX_PROC_VERSION SANDBOX_FAKE_EUID; do
        grep -qF "$seam" "$f" || fail_with "CLAUDE.md should mention the $seam seam"
        grep -qF "$seam" "$REPO_ROOT/install/claude.sh" \
            || fail_with "CLAUDE.md documents $seam but the installer has no such seam"
    done
}

@test "CLAUDE.md's CI job names match the workflow" {
    local job
    for job in generated-files-are-fresh lint-and-test macos e2e windows-smoke; do
        assert_file_contains "$REPO_ROOT/CLAUDE.md" "$job"
        assert_file_contains "$REPO_ROOT/.github/workflows/test.yml" "$job"
    done
}

@test "the README documents --sandbox-ro as both launchers implement it" {
    # From v1.3.0 a launch can mount extra host paths, read-only. The security
    # note that promised "no host path but $PWD" would otherwise be a false
    # claim in the section people read to decide whether to trust this.
    assert_file_contains "$REPO_ROOT/README.md" '--sandbox-ro'
    refute_file_contains "$REPO_ROOT/README.md" 'the one exception being the Docker socket'
    grep -qF -- '--sandbox-ro' "$REPO_ROOT/install/claude.ps1" \
        || fail_with "the PowerShell launcher never mentions --sandbox-ro"
    grep -qF -- ':ro' "$REPO_ROOT/MANUAL.md" \
        || fail_with "MANUAL.md does not show the hand-built read-only mount"
}
