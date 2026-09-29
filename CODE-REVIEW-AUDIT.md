# Code review audit

| | |
| --- | --- |
| Review date | 2026-09-03 |
| Baseline | commit `9d40bf1` on `main`, `VERSION` 1.2.0, clean tree |
| Scope | the whole project (`src/`, `tools/`, `tests/`, docs), not just recent commits |
| Status | **nothing in this file has been fixed yet** |

This file is a work queue. Every item has a checkbox. Tick it, note the commit,
and leave the item in place so the history of what was found and why stays with
the repository. Line numbers are as of the baseline commit; if a file has moved
on, search for the quoted code rather than trusting the number.

## 1. Onboarding for whoever picks this up

### 1.1 How the findings were produced

The review ran ten independent finder passes (line-by-line over the installers,
line-by-line over the launchers, removed-behaviour audit, cross-file tracer,
language pitfalls, bash-to-PowerShell port parity, reuse, simplification,
efficiency, altitude, conventions), then one independent verifier per surviving
candidate, then a gap sweep with two more verifiers. Verifiers reproduced each
item with real Docker 29.1.3 on this WSL2 host, real tmux 3.4, fish 3.7.1 in a
container, the vendored pwsh 7.4.6, or the repository's own bats fakes.

Verdict meanings:

- **CONFIRMED**: reproduced, or the defect is a plain reading of the code that a
  verifier checked line by line.
- **PLAUSIBLE**: the mechanism is documented platform behaviour, but it needs a
  real Windows host (execution policy, Windows PowerShell 5.1, Docker Desktop
  shared between WSL and native) to reproduce. Treat as real; confirm on Windows
  when fixing.
- **UNVERIFIED**: surfaced by the gap sweep with its own evidence but never
  handed to an independent verifier. Verify before fixing.

What could not be exercised in this environment: Windows PowerShell 5.1, a real
execution policy, a rootless Docker daemon (simulated with `unshare` and
`newuidmap` using RootlessKit's exact mapping), and Docker Desktop.

### 1.2 Rules that apply to every fix

`CLAUDE.md` is authoritative. The points that matter most for this queue:

1. Edit `src/`, never `install/`. Then `tools/build.sh`, then `tools/test.sh`.
   CI fails if `install/` does not match a fresh build.
2. bash 3.2 and BSD userland. No associative arrays, no `${v,,}`, no `mapfile`,
   no `sed -i`, no `readlink -f`, no here-document inside `$( )`. Feature-detect
   `sha256sum` vs `shasum`, `stat -c` vs `stat -f`.
3. No jq dependency in the installers. Shellcheck clean at `--severity=style`.
4. Everything before the final `main "$@"` must be definitions only.
5. stdout is a contract: the installers print the `export PATH=…` line and
   nothing else on stdout.
6. Almost every bash change has a PowerShell twin under `src/ps/`. Fix both, or
   write down in the commit why the twin is exempt.
7. Docs change in the same commit as behaviour. `tests/unit/docs.bats` checks
   that README, MANUAL and WINDOWS stay honest; several items below are doc
   promises the code does not keep.
8. Add a test for every fix. Many of these bugs exist precisely because the
   fakes cannot see them; section 1.3 lists the blind spots to close.
9. Test seams are named `SANDBOX_FAKE_*` in production code. Do not add seams
   under other names.

### 1.3 Test harness cheat sheet

```bash
tools/fetch-tools.sh --with-pwsh          # vendors shellcheck, bats, pwsh into ./.bin
tools/build.sh                            # src/ -> install/
tools/test.sh                             # build + lint + unit + intg (+ e2e if docker is up)
tools/test.sh intg                        # one tier
./.bin/bats --filter 'name' tests/integration/launcher.bats   # one test
SANDBOX_FAKE_UNAME_S=Darwin ./.bin/bats tests/unit tests/integration  # Linux-assumption sweep
```

- `tests/helper.bash` provides `common_setup` (throwaway HOME, pinned git
  config, fakes on PATH, `SANDBOX_FAKE_USER=testuser`), `path_without`,
  `path_excluding`, `argv_has`, `argv_lacks`, `assert_docker_ran`,
  `refute_docker_ran`, `fail_with`.
- Fakes live in `tests/fixtures/fakebin/` (`docker`, `curl`, `tmux`, `wsl.exe`,
  `git`, `gh`). Knobs they read: `FAKE_DOCKER_BUILD_RC`, `FAKE_DOCKER_BUILD_OUT`,
  `FAKE_DOCKER_INFO_RC`, `FAKE_DOCKER_INFO_OUT`, `FAKE_DOCKER_SOCK_GID`,
  `FAKE_DOCKER_NEW_VOL_UID`, `FAKE_DOCKER_LEGACY_PROJECTS`, `FAKE_DOCKER_ENDPOINT`,
  `FAKE_DOCKER_LOG`, `FAKE_DOCKER_ARGV`, `FAKE_DOCKER_STATE`, `FAKE_CODEX_VERSION`,
  `FAKE_NPM_FAIL`, `FAKE_UPSTREAM_VERSION`, `FAKE_VERSION_FETCH_FAIL`,
  `FAKE_GIT_NAME`, `FAKE_GIT_EMAIL`, `FAKE_GIT_ORIGIN`, `FAKE_GIT_CRED_USER`,
  `FAKE_GIT_CRED_PASS`, `FAKE_GH_TOKEN`, `FAKE_WSL_MODE`, `FAKE_TMUX_STATE`,
  `FAKE_TMUX_LOG`.
- Production seams: `SANDBOX_FAKE_UID`, `SANDBOX_FAKE_GID`, `SANDBOX_FAKE_EUID`,
  `SANDBOX_FAKE_USER`, `SANDBOX_FAKE_HOME`, `SANDBOX_FAKE_PWD`,
  `SANDBOX_FAKE_UNAME_S`, `SANDBOX_FAKE_PLATFORM`, `SANDBOX_FAKE_NPM`,
  `SANDBOX_FAKE_UPSTREAM`, `SANDBOX_FAKE_USERPATH_FILE`, plus
  `SANDBOX_OS_RELEASE` and `SANDBOX_PROC_VERSION`.

Blind spots the suite has today, each of which hides at least one item below:

- Every test uses a lowercase ASCII user (`testuser`). See F03.
- The fake `docker run` always exits 0 and dispatches on substrings of the whole
  argv tail. Failure paths in `volume_owner_uid`, config seeding, `chown` and
  the doctor's CLI probe are unreachable. See A01, A26.
- The fake `tmux` records `new-session` arguments but never executes the command
  string and does not model tmux's `.` to `_` rename. See F11, F12.
- The PowerShell suite runs only under pwsh 7.4 on Linux, never Windows
  PowerShell 5.1 and never legacy argument passing. See F02, F05.
- `common_setup` does not unset `TMUX` or `SANDBOX_*`, so **run the suite from
  outside tmux** until A21 is fixed, or eight launcher tests fail.
- No CI job runs a rootless daemon. See F06.

### 1.4 Suggested order of work

Group the fixes; several items share a root cause or a decision.

| Cluster | Items | Why together |
| --- | --- | --- |
| 1. Secrets | F01, F05 (helper half), A14 | Small diffs, highest payoff. |
| 2. Silent data loss | F07, F09, F08, A05, A09 | All are "installer overwrote or orphaned a user file without saying so". |
| 3. Windows platform decision | F02, F04, F05, F14, A06, A16, A17, U05 | Decide first whether the PowerShell port requires pwsh 7.3+ (recommended) or must keep working under Windows PowerShell 5.1. Requiring 7.3+ turns F02, F05 and U05 into one version guard plus a doc line. F04, F14, A06 remain either way. |
| 4. Naming and identity | F03, F13, A07 | Who the image, volume and session belong to. |
| 5. tmux mode | F11, F12, A21 | One rewrite of `tmux_launch` covers all three. |
| 6. Rootless Docker | F06 | Needs a product decision: detect and refuse, or support. |
| 7. Installer robustness | F15, A01, A02, A03, A04, A12, A13, A18 | Mostly one-line fixes plus tests. |
| 8. Hygiene and efficiency | F10, A10, A11, A15, A19, A20, A22, A23, A24, A25, A27, U01 to U04 | Low risk, do in batches. |

## 2. Ranked findings

### F01. `--sandbox-git` puts the token into the `docker run` argv

- [ ] Status: open
- Severity: **High**. Verdict: CONFIRMED (real Docker). Category: security.
- Where: `src/assets/launcher-common.sh:240-241` builds
  `GIT_ENV_ARGS+=(-e "SANDBOX_GIT_USER=…" -e "SANDBOX_GIT_TOKEN=$GIT_CRED_TOKEN")`
  after `git_resolve_cred` (:186-221) fills the token from `$GH_TOKEN`,
  `gh auth token` or `git credential fill`; `run_container` execs it at
  :362-367. PowerShell twin: `src/ps/assets/launcher-common.ps1:212`
  (`"SANDBOX_GIT_TOKEN=$($cred[1])"`).
- Problem: the attached `docker` client process carries the token in its
  command line for the whole session. `/proc/<pid>/cmdline` is world-readable
  under the default `hidepid=0`, so every local user can read it with
  `ps -eo args`. `README.md:1-12` targets shared multi-user servers and
  `README.md:241` promises the credential is "environment only … never written
  to a volume or a file". Rootless Docker (`README.md:300`) does not close this.
- Evidence: `ps -eo user,pid,args` showed
  `docker run … -e SANDBOX_GIT_TOKEN=verifytok-IN-ARGV …` while the container
  ran. `FOO=x docker run -e FOO image` (no value) was verified to read the value
  from the launcher's environment and shows nothing in `ps`.
- Fix: export `SANDBOX_GIT_USER` and `SANDBOX_GIT_TOKEN` into the launcher's
  own environment and pass bare `-e SANDBOX_GIT_USER -e SANDBOX_GIT_TOKEN`.
  PowerShell: set `$env:SANDBOX_GIT_TOKEN` and pass `'-e','SANDBOX_GIT_TOKEN'`.
  The values still land in `docker inspect .Config.Env`, which is unavoidable
  and already root-equivalent territory.
- Tests: `tests/integration/launcher.bats` near :489 asserts
  `argv_has "SANDBOX_GIT_TOKEN=s3cret"`, which locks the leak in. Invert it to
  `argv_lacks "s3cret"` plus `argv_has "-e SANDBOX_GIT_TOKEN"`; same in
  `tests/integration/powershell.bats`.
- Docs: `README.md:241` becomes true. `MANUAL.md:233-235` shows the hand-built
  launcher passing the token; update that recipe too.

### F02. Windows PowerShell 5.1: stderr redirects throw under `$ErrorActionPreference = 'Stop'`

- [ ] Status: open
- Severity: **High** on stock Windows without pwsh 7. Verdict: PLAUSIBLE
  (documented 5.1 behaviour; not reproducible on Linux). Category: correctness.
- Where: EAP is set to Stop in `src/ps/claude.ps1:22`, `src/ps/codex.ps1:22`,
  `src/ps/assets/claude-sandbox.ps1:6`, `src/ps/assets/codex-sandbox.ps1:8`.
  Redirected native calls: `src/ps/lib.ps1:170` (`docker info 2>&1` in
  Assert-Docker), `:197` Test-DockerImage, `:198` Test-DockerVolume, `:202`
  Get-ImageLabel, `src/ps/assets/launcher-common.ps1:99-101`
  Assert-DockerAndImage, `:144` `git config --get … 2>$null`, `:166`
  `gh auth token`.
- Problem: in Windows PowerShell 5.1 any `2>` redirection of a native command
  wraps each stderr line as a NativeCommandError; with EAP=Stop the first line
  terminates the script. PowerShell 7.0 removed this (PR #10996). 5.1 is what
  `irm … | iex` runs in on a stock Windows 10/11 machine and is the `.cmd`
  shim's fallback (`claude-sandbox.cmd:9-10`). The happy path dies too:
  `Invoke-Build` calls `Test-ImageCurrent` calls `Test-DockerImage` on the
  not-yet-built image, docker prints "No such image" on stderr, and the script
  ends before `docker build`. A healthy daemon's `WARNING:` lines from
  `docker info` trip Assert-Docker the same way.
- Evidence: PowerShell issues #3996 and #4002, the 7.0.0-preview.5 release
  note. The suite and CI run only pwsh 7 (`tests/integration/powershell.bats:9-11`,
  `.github/workflows/test.yml` `shell: pwsh` throughout). The fake docker writes
  the trigger lines to stderr, so the suite would fail under 5.1.
- Fix: first make the Cluster 3 decision. Option A (recommended): require pwsh
  7.3 or newer. Add a runtime guard at the top of `Invoke-Main` and both
  launchers (`#Requires` is not honoured by `iex` on a string, so it must be a
  check on `$PSVersionTable.PSVersion`), make the `.cmd` shim fail with a clear
  message when `pwsh` is absent instead of falling back to `powershell`, and
  document the prerequisite. Option B: keep 5.1 by wrapping every native call
  in `try {} catch {}` with EAP scoped to Continue, and never redirect stderr on
  a command that may legitimately print to it.
- Tests: GitHub's Windows runner has both shells. Add a `shell: powershell`
  step to `windows-smoke` running `-Version`, `-Help` and `-Check`, which
  either exercises the guard (Option A) or catches NativeCommandError (Option B).
- Docs: `README.md:23-27`, `WINDOWS.md:91-93` must state the PowerShell version
  requirement.

### F03. Raw `$USER` / `$env:USERNAME` in image, volume and container names

- [ ] Status: open
- Severity: **High** (one of four shipped installers fails for a common Windows
  account shape with a misleading remedy). Verdict: CONFIRMED (real daemon).
  Category: correctness.
- Where: `sandbox_user()` at `src/lib/common.sh:63-68` and
  `src/assets/launcher-common.sh:10-15`; `Get-SandboxUser` / `Get-User` at
  `src/ps/lib.ps1:51-55` and `src/ps/assets/launcher-common.ps1:3-7`. Spliced
  verbatim at `common.sh:1006` (`IMAGE="$IMAGE_BASENAME-$(sandbox_user)"`),
  `:781`, `:915`, `:976`; `launcher-common.sh:608`, `:87`;
  `src/assets/claude-sandbox:21-22`; `src/ps/claude.ps1:77`;
  `src/ps/codex.ps1:158`; `lib.ps1:533`, `:644`;
  `src/ps/assets/claude-sandbox.ps1:18-20`; `codex-sandbox.ps1:20-21`.
  Contrast `project_slug` (`launcher-common.sh:83`, `launcher-common.ps1:42`),
  which does sanitise.
- Problem: image repository names must be lowercase; volume and container names
  reject `@`, backslash and spaces. Native Windows account names are commonly
  mixed case (`Michael`) or spaced (`John Smith`); AD/SSSD-joined Linux and WSL
  boxes have `jdoe@corp.example.com` or `CORP\jdoe`. Both installers run
  `docker build` before `docker volume create`, so the first error is the
  build failure plus the remedy "usually a transient network failure … or a
  full disk" (`common.sh:756`, `lib.ps1:394`). `image_exists` /
  `Test-DockerImage` then read the failed inspect as "not built".
- Evidence: `docker build -t claude-sandbox-Michael` fails with "repository
  name must be lowercase"; `docker volume create claude-config-jdoe@corp.example.com`
  fails with "includes invalid characters". Volume names do accept uppercase,
  so mixed case breaks only the image tag; `@` and `\` break all three.
- Fix: one helper (bash: lowercase then `tr -c 'a-z0-9_.-' '-'`; PowerShell:
  `.ToLowerInvariant()` plus a regex replace) used at every splice point,
  including the launchers. Decide how to disambiguate two accounts that slug
  identically (`Michael` and `michael`): append a short hash of the raw name,
  or accept the collision and document it. Existing installs with lowercase
  ASCII names are unaffected because the slug is the identity for them.
- Tests: add cases with `Michael`, `jdoe@corp.example.com`, `CORP\jdoe` and
  `John Smith` via `SANDBOX_FAKE_USER`, asserting the image, volume and
  container names; PowerShell twin.
- Docs: `README.md:12`, `:238-240`, `:300-301`, `MANUAL.md:23`, `WINDOWS.md:64`
  describe `$USER` namespacing; add the sanitisation rule.

### F04. `claude-sandbox.ps1` shadows the `.cmd` shim from a PowerShell prompt

- [ ] Status: open
- Severity: **High** on stock Windows clients (launcher does not run from
  PowerShell at all). Verdict: PLAUSIBLE (command precedence is documented;
  execution policy needs Windows to reproduce). Category: correctness.
- Where: `src/ps/lib.ps1:527-528` writes `<bin>\claude-sandbox.ps1` and
  `<bin>\claude-sandbox.cmd` into the same directory. Promises:
  `WINDOWS.md:98`, `README.md:227` ("works from both PowerShell and cmd.exe,
  and never trips PowerShell's execution policy"), the shim's own header, and
  `Show-NextSteps` (`src/ps/claude.ps1:39`, `src/ps/codex.ps1:122`) which tells
  the user to type `claude-sandbox`.
- Problem: PowerShell command discovery tries `<name>.ps1` before any PATHEXT
  extension, so the bare name runs the `.ps1` and the shim's
  `-ExecutionPolicy Bypass` is never consulted. Under the default Restricted
  policy the user gets "claude-sandbox.ps1 cannot be loaded because running
  scripts is disabled on this system", the well-known `npm.ps1` failure. Only
  cmd.exe or an explicit `claude-sandbox.cmd` works.
- Fix: install the script under a name or directory that does not collide, for
  example `<src-dir>\claude-sandbox.launcher.ps1`, so the `.cmd` is the only
  `claude-sandbox*` on PATH. Update the shim's `%SANDBOX_PS1%`, the file list in
  `Invoke-Uninstall` (`lib.ps1:625-627`), `Invoke-Check`, the manifest's
  `launcher=` key, and the PowerShell bats assertions on installed file names.
- Tests: `windows-smoke` (`test.yml:158-174`) runs the shim only via `cmd /c`.
  Add a `shell: powershell` step that sets
  `Set-ExecutionPolicy Restricted -Scope Process` and runs the bare
  `claude-sandbox --sandbox-version`.
- Docs: `WINDOWS.md:98`, `README.md:227`.

### F05. Legacy native-argument passing strips inner quotes (5.1 and pwsh 7.0 to 7.2)

- [ ] Status: open
- Severity: **High** for the git credential half, Medium for the label half.
  Verdict: CONFIRMED (pwsh with `$PSNativeCommandArgumentPassing='Legacy'` plus
  real docker and git). Category: correctness, security.
- Where: Go-template arguments at `src/ps/lib.ps1:202` (Get-ImageLabel),
  `src/ps/assets/launcher-common.ps1:262` (Show-Doctor),
  `src/ps/assets/codex-sandbox.ps1:51`; the credential helper string at
  `launcher-common.ps1:139` passed at `:214`.
- Problem: before 7.3, PowerShell wraps any argument containing whitespace in
  double quotes without escaping embedded quotes, and docker.exe's argv parser
  drops them. The template becomes
  `{{index .Config.Labels sandbox.dockerfile_sha}}` and docker answers
  `function "sandbox" not defined`, so `Get-ImageLabel` returns empty,
  `Test-ImageCurrent` is always false, the installer rebuilds on every re-run,
  `-Check` never says current, and `codex-sandbox.ps1` runs `docker build` on
  every launch. The helper becomes an unquoted `printf`, sh emits
  `username=alicenpassword=tok123n`, and `git push` fails with the token echoed
  inside the username in git's own error text, while the launcher reported the
  credential as forwarded.
- Evidence: reproduced end to end under Legacy passing with the built image
  and git 2.43. CI runs only pwsh 7.4 (Standard passing).
- Fix: if Cluster 3 chooses to require pwsh 7.3+, the version guard covers
  this. Otherwise avoid embedded quotes entirely: read labels with
  `docker image inspect --format '{{json .Config.Labels}}'` and index the
  parsed object in PowerShell; write the helper with single-quoted sh strings
  or ship it as a tiny script inside the image instead of an inline
  `!f(){ … }`.
- Tests: pwsh 7.4 still honours `$PSNativeCommandArgumentPassing='Legacy'`;
  add a bats case that runs the launcher through
  `pwsh -c "$PSNativeCommandArgumentPassing='Legacy'; & …"` and asserts the
  label read and helper survive.

### F06. UID matching is wrong under rootless Docker

- [ ] Status: open
- Severity: **High** (docs steer users into a configuration where the agent
  cannot edit the project and every diagnostic says healthy). Verdict:
  CONFIRMED (user-namespace simulation with RootlessKit's mapping). Category:
  correctness.
- Where: `src/assets/claude.Dockerfile:51-52` (`ARG UID=1001` / `GID`) and
  `codex.Dockerfile:36-37`; `--build-arg UID=$(host_uid)` at
  `src/lib/common.sh:731-732`; the checks at `common.sh:719` and
  `src/assets/launcher-common.sh:456` only compare the label to the host UID.
  `README.md:172` calls rootless "the configuration to prefer";
  `README.md:300` says "the installers work unchanged". Nothing in `src/`
  looks for `name=rootless` in `docker info`.
- Problem: under rootless dockerd the host user maps to container root and
  container UID 1000 maps to a subordinate UID. The image's `agent` (host UID)
  is therefore an unprivileged subuid on the host: the bind-mounted project
  shows as `drwxr-xr-x 0 0` inside, `touch` fails with Permission denied, and
  anything created in a world-writable directory lands on the host owned by
  subuid-base plus UID minus one. Named volumes are unaffected. `--check`,
  `--sandbox-doctor` and the build label all report a match.
- Evidence: `unshare -U` plus `newuidmap 0 1000 1 1 100000 65536`, then
  `setpriv --reuid=1000 --bounding-set=-all`; `touch proj/x` denied; a file in
  a 1777 subdir appeared as `100999:100999` on the host.
- Fix constraints: building with UID=0 collides with
  `claude.Dockerfile:44-45` (Claude Code refuses
  `--dangerously-skip-permissions` as root), and Docker has no podman-style
  `--userns=keep-id`. The honest fix is detection: read
  `docker info -f '{{json .SecurityOptions}}'` in the installer preflight,
  the launcher's `ensure_docker_and_image` and `doctor`, and refuse (or warn
  loudly) with the reason. Rewrite `README.md:172` and `:300` accordingly. If
  Codex-as-root is acceptable, a rootless mode could build Codex with UID=0;
  that is a product decision.
- Tests: add a `FAKE_DOCKER_INFO_OUT` fixture containing `name=rootless` and
  assert the refusal in `claude-install.bats` and `launcher.bats`. e2e never
  runs against a rootless daemon; a rootless CI job
  (`dockerd-rootless-setuptool.sh install` on ubuntu-latest) is possible but
  optional.

### F07. `--force` resets a customised `config.toml` with no backup, on the host and in the volume

- [ ] Status: open
- Severity: **High** (silent loss of user configuration, including MCP servers
  and model choices Codex persisted). Verdict: CONFIRMED (bash and pwsh).
  Category: data loss.
- Where: `src/lib/common.sh:1032-1037` `install_asset_if_absent` overwrites
  under `FORCE` with no `backup_file` (unlike `install_asset` at `:665-668`);
  `src/codex.sh:77-80` re-seeds the stock file into the `codex-config` volume
  when `FORCE` is set, replacing the copy Codex actually reads. PowerShell:
  `src/ps/lib.ps1:347-351` and `src/ps/codex.ps1:86-91` do the same.
  Contradicting text: `README.md:200` ("a Codex config.toml you've changed is
  left alone entirely"), `src/assets/codex.config.toml:4` header, and the
  usage line at `common.sh:563` / `lib.ps1:492`.
  `tests/integration/codex-install.bats:86` ("--force does restore the shipped
  config.toml") locks the backup-less reset in.
- Evidence: appended `[mcp_servers.myserver]`, ran `--force` / `-Force`; both
  copies reverted to stock, no `.bak` anywhere, only "wrote …/config.toml" and
  "seeded config.toml" printed. Also reachable as
  `codex-sandbox --sandbox-upgrade --force`.
- Fix: back the host file up with `backup_file` before a forced overwrite;
  never re-seed the volume when a config exists unless a new explicit flag
  (for example `--reset-config`) is given, or copy the in-volume file to
  `config.toml.bak.<ts>` first. State the behaviour in `--help` and README.
  Update `codex-install.bats:86` to assert the backup.

### F08. A flagless re-run ignores the manifest's recorded `bin_dir` / `src_dir`

- [ ] Status: open
- Severity: Medium (silent and data-losing for every `--prefix` / `--src-dir`
  user on both platforms). Verdict: CONFIRMED (bash and pwsh). Category:
  correctness.
- Where: `main()` at `src/lib/common.sh:1003-1005` defaults `BIN_DIR` and
  `SRC_DIR`; nothing ever calls `manifest_get bin_dir` or `src_dir`.
  `do_check` `:863-885` and `do_uninstall` `:957-963` test the defaults;
  `src/codex.sh:114-120` removes `config.toml` from the default `SRC_DIR`.
  PowerShell: `src/ps/claude.ps1:75-76`, `src/ps/codex.ps1:156-157`,
  `src/ps/lib.ps1:625-627` (`Invoke-Uninstall`), `codex.ps1:118`.
- Problem: README's documented upgrade path ("re-run the same install
  command", `README.md:187`) and `--sandbox-upgrade` (bare, at `README.md:190`,
  the launcher nudge and the `--check` remedy) install a second copy in the
  default locations and repoint the manifest there. The launcher on PATH never
  updates, and its `codex_src_dir` now resolves to the default directory.
  `--check` reports everything missing. `--uninstall` leaves the custom
  location orphaned. PowerShell `-Uninstall` after `-Prefix`/`-SrcDir` removes
  only the image and manifest, and `-Check` then says "not installed" while
  the launcher still runs.
- Fix: when a manifest exists and the flag was not passed, default
  `BIN_DIR`/`SRC_DIR` from the manifest; have `do_uninstall`,
  `agent_uninstall_extra` and `Invoke-Uninstall` use the manifest's paths.
- Tests: custom prefix, then flagless re-run, `--check` and `--uninstall`;
  assert the same paths throughout. PowerShell twin.
- Related: A09 (relative values), which should be fixed in the same pass.

### F09. `install_asset` overwrites a differing file with no backup when no hash is recorded

- [ ] Status: open
- Severity: Medium (silent loss of a hand-customised Dockerfile). Verdict:
  CONFIRMED. Category: data loss.
- Where: `src/lib/common.sh:666-667`
  (`if [ -n "$recorded" ] && [ "$recorded" != "$cur" ]`); an empty `recorded`
  falls through to `FILE_ACTION=updated` at `:672` and `backup_file` at `:668`
  is never reached. `manifest_write` (`:833`) runs only after `build_image`,
  which exits 1 on failure at `:760`. The Dockerfile header
  (`src/assets/claude.Dockerfile:6-9`) tells users `--src-dir` is "the
  supported way to customise", but `do_install` (`common.sh:820-821`) always
  rewrites the managed file wherever it is. `MANUAL.md:30`, `:95` hand-build
  paths coincide with the installer's.
- Problem: three real paths reach the no-manifest branch. A re-run after a
  failed first `docker build` (say, a proxy) overwrites the user's fix with
  only "updated …/Dockerfile" printed. A first install over MANUAL.md's
  hand-built files replaces them. A `--src-dir` pointed at a customised
  Dockerfile is silently replaced on the first run and then backed up and
  replaced on every upgrade after that.
- Evidence: `FAKE_DOCKER_BUILD_RC=1` first run, edit, re-run: no
  "was modified locally", no `Dockerfile.bak.*`, edit gone.
- Fix: treat an existing file that differs and has no recorded hash as unknown
  provenance and back it up. Either delete the `--src-dir` sentence from the
  Dockerfile header (make it match `codex.Dockerfile:5-6`) or implement an
  opt-in that leaves a non-stock Dockerfile alone. Check `Install-Asset` at
  `src/ps/lib.ps1:321-325` for the same gate.
- Tests: `tests/integration/claude-install.bats:199` covers only the
  manifest-present branch. Add: failed first build, edit, re-run produces a
  `.bak`; `--src-dir` over a pre-existing customised file produces a `.bak`.
- Docs: `README.md:200` describes only the upgrade case.

### F10. Unconditional `-it` breaks every non-terminal invocation

- [ ] Status: open
- Severity: Medium (both agents' headless modes unusable through the launcher).
  Verdict: CONFIRMED (real Docker). Category: correctness.
- Where: `src/assets/launcher-common.sh:362` (`exec docker run -it --rm`);
  `src/ps/assets/launcher-common.ps1:231`; MANUAL.md's hand-built launchers at
  `:207` and `:443`; `tests/e2e/real-docker.bats:216-217` already notes the
  launcher cannot run under bats for this reason.
- Problem: docker errors with "the input device is not a TTY" only when both
  `-i` and `-t` are given and stdin is not a terminal. So `claude -p` or
  `codex exec` fed from a pipe, `< /dev/null`, cron, CI and bats all fail
  before the agent starts. Redirecting only stdout from an interactive
  terminal works but writes `\r\n` line endings because of the pty.
  `README.md:86` promises everything else is "handed to the agent untouched".
- Fix: keep `-i` always; add `-t` only when stdin is a terminal (`[ -t 0 ]`;
  PowerShell `-not [Console]::IsInputRedirected`). Update the MANUAL recipes
  and the e2e comment; e2e can then exercise the launcher directly.
- Tests: `launcher.bats` with stdin from `/dev/null` asserts `-i` present and
  `-t` absent; a case under `script(1)` asserts `-t` present.

### F11. tmux session names keep `.`, and session identity is keyed on the logical `$PWD`

- [ ] Status: open
- Severity: Medium overall, high within `--sandbox-tmux` (unusable for any
  dotted basename such as `example.com`, `next.js`, `.dotfiles`). Verdict:
  CONFIRMED (tmux 3.4, fake tmux). Category: correctness.
- Where: `project_slug` at `src/assets/launcher-common.sh:83` keeps `.`;
  `base="$AGENT-$(project_slug)"` at `:384`; exact-match targets
  `-t "=$session"` at `:385`, `:410`, `:416`, `:430`, `:436`. Identity uses
  bash's logical `$PWD` at `:81`, `:389`, `:390`, `:428`, `:430`, while the
  mount uses `host_workdir` (`pwd -P`, `:112`) at `:356`. The comment at
  `:108-109` states the invariant the tmux path breaks.
- Problem: tmux 3.2 and newer silently rewrite `.` to `_` in session names
  (older tmux refuses with "bad session name"). The first launch creates
  `claude-my_project`, the `attach-session -t =claude-my.project` fails with
  "can't find pane", the agent keeps running detached, and the second launch
  dies with "duplicate session". Separately, reaching one project through a
  symlink (or macOS `/tmp` vs `/private/tmp`) creates a second session and a
  second container on the same mount, bypassing the "already running" guard;
  when the symlink's basename differs the guard is bypassed before the hash
  suffix is even reached.
- Fix: derive a tmux-safe name (replace `.` and `:` with `_`) used only for
  tmux, keep `project_slug` for Docker names; use `$(host_workdir)` at every
  `$PWD` site listed above. Teach `tests/fixtures/fakebin/tmux` the rename.
- Tests: `tests/integration/launcher.bats:289-293` asserts only
  `claude-my-project`. Add a dotted basename and a symlinked project.

### F12. The tmux re-invocation runs under the user's `$SHELL` and drops the launcher's env

- [ ] Status: open
- Severity: Medium (deterministic total failure for fish users of
  `--sandbox-tmux`; silent option loss for everyone with a running tmux
  server). Verdict: CONFIRMED (fish 3.7.1, tmux 3.4). Category: correctness.
- Where: `src/assets/launcher-common.sh:422` builds the command with
  `printf '%q '`, `:426` wraps it as
  `SANDBOX_IN_TMUX=1 … $cmd; ec=$?; if [ $ec -ne 0 ]; then …; fi` prefixing
  only `SANDBOX_GIT` and `SANDBOX_DOCKER`, and `:428` hands it to
  `tmux new-session -d -s … -c "$PWD" "$cmd"` with no `-e` and no
  `set-environment`.
- Problem: tmux runs the string with its default-shell, which follows `$SHELL`.
  fish rejects `ec=$?` ("Unsupported use of '='", exit 127), the session dies
  instantly, and the attach fails with "no sessions". dash under a C locale
  receives `$'r\303\251sum\303\251'` literally for non-ASCII arguments. A new
  session inherits the tmux server's environment, not the client's, so with a
  server already running every other knob is dropped: `SANDBOX_NO_GIT`,
  `SANDBOX_WORKDIR`, `SANDBOX_NO_UPDATE_CHECK`, `SANDBOX_STATE_DIR`,
  `CODEX_SANDBOX_SRC`, `DOCKER_HOST`, `DOCKER_CONTEXT`, `GH_TOKEN`,
  `GITHUB_TOKEN`, `XDG_*`. The launcher then forwards an identity the user
  withheld, or talks to a different daemon inside the session than it
  preflighted outside.
- Fix: stop asking a login shell to parse bash. Write the session body to a
  file under `state_dir` and run it as `/bin/sh <path>` (a simple command every
  shell accepts), or exec `sh -c` explicitly. Carry the env explicitly: extend
  the `%q` prefix to every knob above, emitted only when set, or use
  `tmux new-session -e` (tmux 3.2+; Ubuntu 20.04 ships 3.0a). If the body is
  written to disk, do not put `GH_TOKEN` in it; pass token-bearing variables
  via the prefix or `set-environment` instead.
- Tests: the fake tmux never executes the command. Add a unit test that the
  generated body parses with `sh -n` and that each knob appears in the
  recorded `new-session` arguments when set.

### F13. WSL (Route A) and native (Route B) share image and volume names; the PowerShell build writes no UID label

- [ ] Status: open
- Severity: Medium (`-Uninstall` deletes the other route's image without
  `-Purge`; `-Purge` deletes its login). Verdict: PLAUSIBLE (code confirmed;
  the cross-route scenario needs Windows). Category: correctness.
- Where: names at `src/lib/common.sh:1006`, `:976` vs `src/ps/claude.ps1:77`,
  `src/ps/lib.ps1:533`, `:644`. Labels: `common.sh:732-735` passes
  `--build-arg UID/GID` plus `sandbox.agent_uid`; `lib.ps1:381-385` passes
  only `sandbox.dockerfile_sha` and `sandbox.installer_version`
  (`tests/integration/powershell.bats:115` asserts
  `refute_docker_ran '--build-arg UID='`). Freshness: `common.sh:693-698`
  requires the UID label, `lib.ps1:358-362` compares only the sha.
  `WINDOWS.md:122-123` explicitly steers users to try both routes on one folder.
- Problem: both routes talk to Docker Desktop's single engine. A plain Route B
  `-Uninstall` removes `claude-sandbox-<user>`, after which the WSL launcher
  says the image does not exist. `-Purge` deletes `claude-config-<user>`
  behind a prompt that never says another route uses it. After a Route B build
  the WSL launcher runs the label-less image as the Dockerfile default UID 1001
  against an ext4 project owned by 1000; the launcher checks only existence
  and the doctor prints the empty label as "unknown", not MISMATCH, until the
  next WSL installer run rebuilds once.
- Fix: either add a route marker to Route B names (recommended; keeps each
  route's login volume and image its own and stops cross-route deletes), or
  make the PowerShell build pass UID/GID build args and write
  `sandbox.agent_uid`, and make every destructive prompt say the artefact may
  be shared with the other route. Revisit `powershell.bats:115`.
- Docs: `WINDOWS.md` needs a paragraph on what the two routes share.

### F14. `exit` under `irm … | iex` closes the caller's terminal session

- [ ] Status: open
- Severity: Medium (every failure remedy is unreadable in conhost; `-Check`,
  `-Help`, `-Version`, `-Uninstall` close the tab even on success). Verdict:
  CONFIRMED (pwsh with `-NoExit`). Category: correctness.
- Where: `src/ps/lib.ps1:39` (`Fail` ends in `exit $Code`), `:120`, `:133`,
  `:151`, `:167`, `:180`, `:191` (Assert-*), `:398` (build failure);
  `src/ps/claude.ps1:58-59`, `:79-80`; `src/ps/codex.ps1:139-140`, `:160-161`.
  Documented forms: `README.md:26-27`, `WINDOWS.md:92-93` (`irm | iex`),
  `README.md:213`, `WINDOWS.md:103` (scriptblock form). CI already works
  around it (`test.yml:96-97` forks `pwsh -File` per installer).
- Problem: `iex` runs in the caller's runspace, so `exit` ends the user's
  session. Windows Terminal keeps a tab open on non-zero exit but closes it on
  zero, so the documented `-Check` closes the tab on a healthy install. `irm |
  iex` also leaves `$ErrorActionPreference='Stop'` and every helper function in
  the user's session (the scriptblock form runs in a child scope and does not
  leak).
- Fix: detect `$null -eq $MyInvocation.MyCommand.Path` (scoop's pattern) and
  `throw` or `return` a status instead of `exit` when run from `iex`; keep
  `exit` when run as a file (the shim, CI). Scope EAP inside `Invoke-Main` or
  wrap the body in `& { }`.
- Tests: a bats case that pipes the built installer into `pwsh -NoExit
  -Command` with a failing preflight and asserts a trailing `'still-here'`
  statement prints.

### F15. `ensure_on_path` keeps a promise it cannot keep for a second prefix and for fish/tcsh

- [ ] Status: open
- Severity: Medium (the same "new terminals pick it up" failure class
  CLAUDE.md already records). Verdict: CONFIRMED. Category: correctness.
- Where: `src/lib/common.sh:469` keys on the per-file `$PATH_MARKER`; `:510`
  sets `RC_FILE_EDITED=$rc` regardless of whether anything was written;
  `:406` records it as the manifest's `rc_file`. `rc_file_for_shell`
  (`:419-426`) sends every shell other than bash and zsh a POSIX `case … esac`
  block into `~/.profile`; `login_rc_file` (`:434-436`) bails unless bash.
- Problem: claude with the default prefix, then `codex.sh --prefix ~/bin`,
  prints "PATH entry already present" and "New terminals pick it up", but no
  `~/bin` block exists and `codex-sandbox` is command-not-found in a new
  shell; the manifest and the uninstall notice name a file that was never
  edited. With `SHELL=/usr/bin/fish` the block lands in `~/.profile`, which
  fish never reads; `--check` then loops on "is not on PATH, re-run the
  installer". The printed rescue line is bash syntax and breaks PATH if
  pasted into fish.
- Fix: key on the exact block line for the directory
  (`grep -qxF "$(path_block_line "$literal")" "$rc"`; verified to keep the
  existing `grep -c … -eq 1` assertions green and to append a second guarded
  block for a second directory). Add explicit `fish` (write
  `~/.config/fish/conf.d/agent-sandbox.fish` using `fish_add_path`) and
  `csh|tcsh` arms, and print a shell-appropriate rescue line; keep the `*`
  fallback for sh/dash/ksh, where `~/.profile` is right.
- Tests: `tests/unit/lib.bats:142-146` covers zsh and bash only. Add fish,
  tcsh, and the second-prefix case.
- Docs: `README.md:62-66`, `MANUAL.md:67` document bash/zsh only.

## 3. Confirmed items below the ranking cap

All CONFIRMED unless stated. Terser than section 2, but each has what a fix
needs.

### A01. `volume_owner_uid` failing under `set -e` aborts the installer and `--check` with no message

- [ ] Status: open. Severity: Medium.
- `src/lib/common.sh:346-347` is a `docker run … | tr` pipeline under
  `set -euo pipefail`; `:354` (`owner=$(volume_owner_uid …)`) and `:917`
  (`do_check`) are plain assignments in unconditional call chains, so a failed
  probe exits 125 with an empty stdout, no error line (the daemon message is
  swallowed by `2>/dev/null`), and no manifest written. The function's own
  comment at `:341-342` promises "empty when it cannot be determined".
- Fix: end the function with `|| true`, or `if owner=$(…); then`, the pattern
  `docker_check` already uses at `:634-636`.
- Tests: the fake docker has no knob for a failing `run`. Add one.

### A02. `--check` without the sandbox image pulls `alpine` from Docker Hub

- [ ] Status: open. Severity: Low.
- `helper_image` (`common.sh:771-775`) falls back to `alpine`; `do_check`
  (`:913-921`) uses it unguarded, unlike `setup_volumes` (`:783-786`, which
  prints "skipping volume ownership check (no image to inspect with)").
  `--check` is documented as changing nothing (`common.sh:562`,
  `README.md:205`). The `else … present` branch at `:920-921` would also mask
  an empty probe result.
- Fix: mirror the `:783-786` guard and print "not inspected (no image)".

### A03. `--force` builds without `--pull`, so the base image is never refreshed

- [ ] Status: open. Severity: Medium (the only way to pick up `node:24-slim`
  CVE fixes is a manual `docker pull`).
- `common.sh:731-741` and `lib.ps1:382-386` pass no `--pull`; nothing in the
  installer ever re-resolves `FROM`.
- Fix: add `--pull` (not `--no-cache`) when `FORCE` is set, in both ports;
  mention it in the `--force` usage line. Test with
  `assert_docker_ran 'docker build.*--pull'`.

### A04. `Assert-Wsl2` refuses a working Hyper-V-backend Docker Desktop when a WSL1-only distro exists

- [ ] Status: open. Severity: Medium (hard exit with a misleading remedy on a
  supported configuration).
- `src/ps/lib.ps1:142-151` exits 12 when no listed distro is version 2. The
  "WSL2 is not installed" branch (`:126-139`) is effectively unreachable since
  `wsl.exe` is in-box on every supported Windows, and
  `tests/integration/powershell.bats:43-49` models a state real Windows never
  presents. `WINDOWS.md:131` ("only when WSL is unavailable to you") contradicts
  `WINDOWS.md:75` and this gate.
- Fix: drop the gate in favour of `Assert-Docker`, or downgrade it to a
  warning; reconcile WINDOWS.md.

### A05. `SRC_DIR`, `BIN_DIR`, `FORCE`, `QUIET` and friends inherited from the environment act as flags

- [ ] Status: open. Severity: Medium (an exported `SRC_DIR` from a CI job or a
  sourced `.env` silently overwrites a project's Dockerfile with no backup).
- `common.sh:1003-1004` only defaults when unset; `parse_args` (`:582-606`)
  only ever sets `FORCE`, `QUIET`, `NO_BUILD`, `NO_PATH_EDIT`, `ASSUME_YES`,
  `ALLOW_ROOT`, `PURGE`. PowerShell is unaffected (`param()` entries).
  `common_setup` does not unset them either.
- Fix: initialise every flag variable to empty before `parse_args`; either
  document `BIN_DIR`/`SRC_DIR` as supported overrides or rename them to
  `SANDBOX_*`; unset them in `common_setup`.

### A06. The `.cmd` shim expands `%*` inside a parenthesised block

- [ ] Status: open. Severity: Low to Medium (native Windows, cmd.exe callers,
  unquoted args only; but the double-launch is silent).
- `src/ps/assets/claude-sandbox.cmd:7-11` (codex identical) runs
  `pwsh … %*` inside `if %ERRORLEVEL%==0 ( … ) else ( … )`. cmd.exe expands
  `%*` before parsing the block, so an unquoted `)` (Claude's
  `--allowedTools Bash(git:*)`, a path like `D:\proj(old)`) either aborts with
  "was unexpected at this time" or, when `)` is the last unquoted character,
  runs the launcher twice: once mangled under pwsh, once correct under
  Windows PowerShell.
- Fix: choose the shell inside the block, invoke on one top-level line (npm's
  cmd-shim pattern). Extend `windows-smoke` with an unquoted `f(x)` argument
  and assert a single `shim-args:` line; add a Linux-side test that no `%*`
  line sits between `(` and `)` lines.

### A07. PowerShell `Get-HostWorkdir` is not canonicalised

- [ ] Status: open. Severity: Medium to Low (silent duplicate project
  identities on Route B).
- `src/ps/assets/launcher-common.ps1:54-57` returns `(Get-Location).Path`;
  `:66` lowercases only the drive letter. `cd c:\users\…` vs `C:\Users\…`,
  `subst` drives and `mklink /J` junctions therefore mount and slug as
  different projects. The bash side uses `pwd -P` (`launcher-common.sh:108-113`).
  Note `tests/integration/launcher.bats:60-61` claims the PowerShell launcher
  "has always reported the physical path", which is false.
- Fix: real canonicalisation (`GetFinalPathNameByHandle`, or
  `ResolveLinkTarget` plus per-component on-disk name recovery);
  `.ProviderPath` and `GetFullPath` are not enough. Fix the bats comment.

### A08. The PowerShell launcher forwards `--sandbox-tmux` to the agent, and `--sandbox-doctor` always exits 0

- [ ] Status: open. Severity: Low to Medium.
- `src/ps/assets/launcher-common.ps1:406-411` has four arms; `--sandbox-tmux`
  and `--sandbox-tmux-detached` fall through to the agent's argv.
  `Show-Doctor` (`:254`, `:257`) uses bare `return` where the bash `doctor`
  returns 1, and the arm does `exit 0`. `README.md:92` lists the tmux flags
  with no Windows caveat; the caveat exists only in `Show-LauncherUsage`
  (`:358-359`).
- Fix: add arms that refuse with the "run from WSL" hint; return a status
  from `Show-Doctor` and exit with it. Test the unhealthy doctor path
  (`powershell.bats:389-395` covers only the healthy one).

### A09. Relative `--prefix` / `--src-dir` values are recorded verbatim

- [ ] Status: open. Severity: Low to Medium (unusual invocation, never
  rejected, silent orphaning).
- `common.sh:596-599` store the values as given; `manifest_write`
  (`:389-409`) writes `src_dir=./cdx`, `launcher=./bin/codex-sandbox`;
  `ensure_on_path` (`:487-501`) puts `./bin` on PATH in the rc files and the
  printed export line; `codex_src_dir` (`src/assets/codex-sandbox:27-38`,
  whose comment says "Absolute, because this script runs from arbitrary
  project directories") and `do_uninstall` (`:957-963`) then resolve against
  the reader's cwd. PowerShell: `claude.ps1:75-76`, `codex.ps1:156-157` pass
  the value verbatim, and `Write-AtomicText` (`lib.ps1:88-95`) mixes
  PowerShell-relative `Test-Path`/`New-Item`/`Move-Item` with .NET-relative
  `WriteAllBytes`, so a relative path after `Set-Location` throws
  `DirectoryNotFoundException` and leaves a stray `.tmp*`.
- Fix: absolutise once in `parse_args` (`cd "$d" && pwd -P` after creating
  it, or prefix `$PWD/`); PowerShell:
  `$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath()`.
  Only absolute values are tested today (`claude-install.bats:435-443`,
  `powershell.bats:253`).

### A10. No `--init`, so the agent runs as PID 1 and never reaps orphans

- [ ] Status: open. Severity: Low (hygiene).
- `launcher-common.sh:362-371` and `launcher-common.ps1:230-239` pass no
  `--init`; neither Dockerfile sets an `ENTRYPOINT`, and `node:24-slim`'s
  entrypoint execs the command. Zombies were demonstrated on both real images.
  Both agents do handle SIGTERM, so `docker stop` is not delayed.
- Fix: add `--init` (verified compatible with `--cap-drop=ALL`); update
  MANUAL.md's recipes; `argv_has --init` in `launcher.bats`.

### A11. Documentation drift the docs tests do not catch

- [ ] Status: open. Severity: Medium for the first bullet, Low for the rest.
- `MANUAL.md:549` still says "The images contain no Docker client", the exact
  sentence commit `9d40bf1` removed from README and that
  `tests/unit/docs.bats:118-122` refutes only in README. It contradicts
  `MANUAL.md:120-125` and `:246-252` on the same page. Fix: use the
  `README.md:311` wording; widen the refute to MANUAL.md.
- `tests/unit/docs.bats:108-115` loops only over `claude.Dockerfile`;
  `codex.Dockerfile` is never checked against MANUAL.md. `CLAUDE.md:157` and
  the test name overstate. Fix: loop over `src/assets/*.Dockerfile`.
- `WINDOWS.md:96` still says "open a new terminal afterwards" and never
  mentions `-PrintPath`, which `README.md:210`, `:231` document.
- `SANDBOX_GIT`, `SANDBOX_DOCKER` and `SANDBOX_STATE_DIR` are read by the code
  (`launcher-common.sh:235`, `:313`, `:34`; `common.sh:370`; `lib.ps1:58`) and
  listed in `--sandbox-help` (`launcher-common.sh:596-603`) but absent from
  README and MANUAL. See also A24.

### A12. `do_uninstall` reads `rc_file` after deleting the manifest; re-runs blank it

- [ ] Status: open. Severity: Low.
- `common.sh:994-997` runs `rm -f "$(manifest_path)"` then
  `manifest_get_or rc_file`, which returns empty once the file is gone, so
  the "The PATH line this installer added to … was left alone" notice is dead
  code. Separately, a re-run with the directory already on PATH returns early
  at `:494-497` before `RC_FILE_EDITED` is set, and `manifest_write` (`:406`)
  rewrites `rc_file=` empty.
- Fix: read the value into a local before the `rm`; have `manifest_write`
  carry forward the previous `rc_file` when `RC_FILE_EDITED` is unset.

### A13. `confirm()` tests `[ -r /dev/tty ]`, which is true without a controlling terminal

- [ ] Status: open. Severity: Low (the failure is the safe one).
- `common.sh:202`: `-r` is `access(2)` on a `crw-rw-rw-` node and never opens
  it, so the "Not running interactively — re-run with --yes" branch is dead;
  under cron or `setsid` the `read` at `:208` fails with
  "/dev/tty: No such device or address" and a bash line number.
- Fix: `if ! ( : < /dev/tty ) 2>/dev/null; then` and `2>/dev/null` on the
  `read`. No test exercises `confirm`; add one under `setsid`.

### A14. `http://` remotes are looked up and bound as `https`

- [ ] Status: open. Severity: Low (fails loudly at push time, but the token
  was forwarded for nothing).
- `launcher-common.sh:177` accepts `https://*|http://*` against its own
  comment at `:172` and `README.md:121` ("HTTPS remotes only"); the
  `credential fill` request (`:210`) and the helper key
  (`credential.https://<host>.helper`) are hard-coded to https, and git
  matches protocol exactly. PowerShell `:153` has the same `^https?://`.
- Fix: drop `http://` (the existing "no https remote" warning then applies) or
  carry the scheme through both the fill request and the helper key.

### A15. Four `version_gt` copies with three behaviours, plus a dotless-version bug

- [ ] Status: open. Severity: Low today (VERSION is maintainer-controlled),
  but the drift is real.
- Copies: `common.sh:176`, `launcher-common.sh:17`, `lib.ps1:428`,
  `launcher-common.ps1:24`. `1.2.10-rc1` vs `1.2.9`: installer says newer,
  launcher and both PowerShell copies say not. `1.2.3` vs `1.2.3-dev`: the
  reverse. Both bash copies return true for `version_gt 1 1.0` because
  `cut -d. -f2` echoes the whole line when there is no dot, so a dotless
  upstream VERSION would produce a phantom "upstream v2 available" from
  `--check` (`common.sh:932`). `tests/unit/lib.bats:24-40` tests only the
  installer copy.
- Fix: one canonical body in a small `src/lib/version.sh` pulled in with
  `# @include` by both the installer and the launcher, one PowerShell body,
  and a shared vector set (`1.2.10-rc1`, `1.2.3-dev`, `1`, `2`).

### A16. PowerShell asset hashes mismatch on a CRLF checkout

- [ ] Status: open. Severity: Low (undocumented route; cosmetic churn plus a
  permanently failing `-Check`).
- `lib.ps1:77` hashes the raw here-string, `:93` writes the CRLF-normalised
  file, so `Install-Asset` and `Invoke-Check` never compare equal after a
  `core.autocrlf=true` clone. No `.gitattributes` in the repo.
- Fix: normalise in `Get-AssetSha`; add `.gitattributes` with
  `*.ps1 text eol=lf` and `*.sh text eol=lf`.

### A17. The user PATH is rewritten from `REG_EXPAND_SZ` to `REG_SZ`

- [ ] Status: open. Severity: Low (silent, permanent, harmless until a
  `%VAR%` reference later changes).
- `lib.ps1:274` reads with `GetEnvironmentVariable` (expands `%USERPROFILE%`)
  and `:283` writes with `SetEnvironmentVariable` (infers REG_SZ). A fresh
  profile's `HKCU\Environment\Path` is REG_EXPAND_SZ, so every first-time user
  hits it once; uninstall never touches PATH.
- Fix: read with `DoNotExpandEnvironmentNames`, write with
  `RegistryValueKind.ExpandString`, and broadcast `WM_SETTINGCHANGE` via
  P/Invoke (Chocolatey's pattern), or the "new terminals pick it up" promise
  breaks.

### A18. `(v@@VERSION@@)` in the Dockerfile comment forces a rebuild on every release

- [ ] Status: open. Severity: Medium (a multi-minute rebuild per release when
  the builder cache is cold).
- `claude.Dockerfile:6` and `codex.Dockerfile:5` carry the version;
  `build.sh:95` substitutes it; `install_asset` and `build_image` key on the
  whole-file sha. `tests/integration/claude-install.bats:177-187` ("upgrade
  updates the launcher when only the launcher changed") only seds the
  version lines in the installer and so asserts a property real releases do
  not have.
- Fix: drop the version from the Dockerfile comment (or hash with the comment
  stripped); make the bats test bump the Dockerfile comment the way a real
  release does. MANUAL.md's copies must still match (docs.bats).

### A19. About 234 MB of npm cache is baked into the two images

- [ ] Status: open. Severity: Medium (measured; duplicated per user because
  the layer sits after `USER agent`).
- `claude.Dockerfile:79-80` and `codex.Dockerfile:62-63` run `npm install -g`
  without cleaning `~/.npm/_cacache` (97 MB in the claude layer, 137 MB for
  codex).
- Fix: `npm cache clean --force` (or `rm -rf ~/.npm/_cacache`) in the same
  `RUN`; update MANUAL.md's Dockerfiles in the same commit.
- v1.3.2: the Claude half is gone. That image now installs Claude Code
  natively instead of with npm, so only `codex.Dockerfile` still carries the
  cache.

### A20. `tests/helper.bash:90` `local` expansion-order bug; helper not linted

- [ ] Status: open. Severity: Low (latent; no current test calls
  `path_without` twice).
- `local skip=$1 t dir="$TESTDIR/without-$skip"` expands `$skip` before the
  assignment takes effect (shellcheck SC2318), so every call shares
  `without-`. `tools/test.sh:87-101` never lints `tests/helper.bash` although
  `tools/test.sh:6` says "every shell script".
- Fix: two `local` statements; add the helper to the lint set (needs an
  SC2154 directive for bats' `$status`).

### A21. `common_setup` does not unset `TMUX` or `SANDBOX_*`

- [ ] Status: open. Severity: Low to Medium (the suite fails on a developer
  box for environmental reasons; CI is unaffected).
- `tests/helper.bash:42-49` unsets git and gh variables only. Measured in
  `launcher.bats`: `TMUX` set causes 8 failures, `SANDBOX_WORKDIR` 6,
  `SANDBOX_DOCKER` 2, `SANDBOX_GIT` 2, `CODEX_SANDBOX_SRC` 1. README recommends
  living in tmux, so this is the expected developer setup.
- Fix: unset `TMUX SANDBOX_GIT SANDBOX_DOCKER SANDBOX_WORKDIR SANDBOX_NO_GIT
  SANDBOX_NO_UPDATE_CHECK SANDBOX_STATE_DIR CODEX_SANDBOX_SRC` (and the A05
  flag variables) in `common_setup`; mention the class in CLAUDE.md's Tests
  section next to the git-identity note.

### A22. `remedy()` numbers continuation lines

- [ ] Status: open. Severity: Low (cosmetic, on the most-hit error paths).
- Ten bash call sites (`common.sh:223`, `:226`, `:227`, `:245`, `:270`,
  `:296`, `:618`, `:627`, `:628`, `:757`) and three PowerShell
  (`lib.ps1:118`, `:160`, `:162`) pass indented continuation lines that come
  out as "2.    (or follow …)". Fix: treat a leading space as a continuation
  in `remedy` / `Remedy`; pin the numbering in a test.

### A23. `tools/build.sh` does not escape `&`, `\` or `|` in substituted values

- [ ] Status: open. Severity: Low (only a fork with an undocumented override).
- `build.sh:96` `s|@@RAW_BASE@@|$RAW_BASE|g`: an `&` silently corrupts every
  generated file; a `|` aborts with a sed error. Fix: escape the three
  characters before sed, or substitute with bash parameter expansion.

### A24. Undocumented launcher environment knobs

- [ ] Status: open. Severity: Low.
- `SANDBOX_GIT=1` and `SANDBOX_DOCKER=1` (equivalents of the flags) and
  `SANDBOX_STATE_DIR` (overrides the location `README.md:224` documents) are
  absent from README and MANUAL. `docs.bats:44-50` checks only `--sandbox-*`
  flags. Fix: a README table of env knobs plus a docs.bats check that every
  variable named in `--sandbox-help` is documented.

### A25. The Codex launcher retries a failed rebuild on every launch, forever

- [ ] Status: open. Severity: Medium to Low.
- `src/assets/codex-sandbox:46-47` hits the npm registry on every launch (by
  design, `README.md:198`) but on a failed `docker build` (`:80-81`) writes no
  marker, so the stale `codex_version` label triggers registry plus a full
  build on every subsequent launch until npm publishes an installable
  version. PowerShell twin `codex-sandbox.ps1:44`. No test covers the failed
  rebuild path.
- Fix: record the failed version in `state_dir` and skip it (or back off) on
  later launches; add a `FAKE_DOCKER_BUILD_RC=1` launcher test.

### A26. The fake `docker run` dispatches on substrings of the whole argv tail

- [ ] Status: open. Severity: Low (test fragility).
- `tests/fixtures/fakebin/docker:175-215` matches `*stat*`, `*entrypoint*`,
  `*cp *`, `*chown*` against everything after the options, including `-w`,
  the image, and the agent's arguments. A project path containing `stat` or a
  prompt containing `cp a b` changes what the fake does; a developer whose
  `TMPDIR` contains `stat` would trip it on every launch. `:216-228` then exit
  0 unconditionally, so seed, chown and doctor-CLI failure paths are
  unreachable (`codex.sh:84`, `:97`; `launcher-common.sh:485`;
  `common.sh:362`; `codex.ps1:93`, `:103`).
- Fix: dispatch on the command token after the image, log unmodelled `run`
  shapes to stderr, and add knobs for failing seed/chown/probe runs.

### A27. Miscellaneous low-severity items from the batch verifiers

- [ ] `preflight`'s curl/wget warning (`common.sh:806`, `:801`) is false for
  Claude (nothing in `do_install` downloads) and imprecise for Codex.
- [ ] Dead variables: `SANDBOX_IN_TMUX` (written at `launcher-common.sh:426`,
  read nowhere) and the manifest's `extra_sha` (`codex.sh:34`,
  `common.sh:407`, no reader). `PATH_NEEDS_RELOAD` is redundant with
  `PATH_EXPORT_LINE` but is read.
- [ ] The reserved-mount guard (`launcher-common.sh:130-131`,
  `launcher-common.ps1:83-85`) omits `/usr/local`; a project there hides
  `node` and the docker CLI with no message.
- [ ] The launcher is installed (`common.sh:824`) before the image is built
  (`:829`); on build failure the new launcher sits beside the old image and
  nothing at launch compares the two versions except the
  `--sandbox-docker`-gated `DOCKER_CLI_SINCE` check.
- [ ] A no-op install run makes 9 (claude) or 12 (codex) docker invocations,
  mostly repeated `image inspect` of the same image
  (`image_exists`/`image_label` at `common.sh:326-330` re-called from
  `image_is_current`, `build_image`, `helper_image`, `setup_volumes`).
- [ ] CI has no `actions/cache` for `./.bin`; e2e and macOS jobs vendor
  shellcheck and bats they never run. bats runs serially (1m28s wall for 40s
  CPU); `-j` needs GNU parallel vendored.
- [ ] `free_space_gb` (`common.sh:122-126`, `:643-645`) checks `$HOME`, not
  the daemon's data root; on WSL2 it reports the sparse vhdx and never fires.
  The PowerShell installer has no space check.
- [ ] Three sha256 helpers (`codex-sandbox:66-68`, `common.sh:72-79`,
  `launcher-common.sh:91-94`) and the `LABEL_*` literals are duplicated
  between the installer library and the launcher.
- [ ] `jq -r .version || grep …` (`codex.sh:37`, `codex-sandbox:47`): once jq
  has drained stdin the grep fallback sees nothing; both land in the soft
  warning path, so make grep the single implementation or add a
  `path_without jq` codex test.
- [ ] `docs.bats:30` passes vacuously if its `grep -oh … \(sh\|ps1\)` matches
  nothing; assert a non-zero match count.

## 4. Unverified candidates from the gap sweep

These came with evidence from the sweep pass but were not independently
verified. Confirm before fixing.

### U01. `-v "$src:$dst"` cannot express a project path containing `:`

- [ ] Status: unverified.
- `launcher-common.sh:364`; `codex.sh:127` (`-v "$SRC_DIR/config.toml:…"`).
  The sweep reproduced `docker run -v "$(pwd -P):$(pwd -P)"` from a directory
  named `proj a:b` failing with "invalid volume specification". macOS Finder
  stores a `/` typed in a folder name as `:` on disk. Fix direction:
  `--mount type=bind,src=…,dst=…` (note `--mount` is CSV-parsed, so a comma
  in the path needs quoting).

### U02. The update-check cache treats a future mtime as fresh

- [ ] Status: unverified.
- `launcher-common.sh:54` (`find "$cache" -mmin -1440`) and
  `launcher-common.ps1:119-120` (`TotalHours -lt 24`) both accept negative
  ages. After a clock correction (WSL2 after sleep, a fixed system date) the
  upstream nudge is silently suspended until real time passes the stamp. Fix:
  store the timestamp in the file and compare numerically, treating a future
  stamp as stale.

### U03. `tools/fetch-tools.sh` installs unpinned downloads after a warning

- [ ] Status: unverified.
- `verify_pin` (`fetch-tools.sh:45`) dies only on a mismatch; an absent pin
  warns and `install_shellcheck` (`:77-78`) / `install_pwsh` (`:130-133`)
  proceed. `tool-pins.txt` covers shellcheck linux.x86_64 and darwin, and
  pwsh linux-x64 only, so arm64 Linux and macOS `--with-pwsh` run unverified
  binaries despite the header's "trust-on-first-use is not a security model".
  Fix: die on a missing pin; add the missing pins.

### U04. The PowerShell manifest's `installed_at` is local time labelled `Z`

- [ ] Status: unverified.
- `lib.ps1:252` `Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ'` emits the literal
  `Z` after local time; `common.sh:397` uses `date -u`. Fix:
  `(Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss') + 'Z'`.

### U05. BOM-less UTF-8 `.ps1` launchers with em-dashes mis-decode under Windows PowerShell 5.1

- [ ] Status: unverified. Moot if Cluster 3 requires pwsh 7.
- `Write-AtomicText` (`lib.ps1:94`) writes every asset BOM-less, including
  the `.ps1` launcher that 5.1 decodes as the ANSI code page;
  `launcher-common.ps1:97`, `:103` and `codex-sandbox.ps1:60` contain U+2014.
  Fix: ASCII-only strings in the `.ps1` assets, or write `.ps1` files with a
  BOM while keeping the Dockerfile and config BOM-less.

## 5. Cross-cutting notes

- **Windows PowerShell 5.1 is the platform question.** F02, F05 and U05 exist
  only on 5.1 (and 7.0 to 7.2 for F05). The docs never state a PowerShell
  version, the `.cmd` shim falls back to `powershell`, and nothing in the
  suite runs 5.1. Requiring pwsh 7.3+ with a runtime guard is the smaller
  change; supporting 5.1 means auditing every native call.
- **The bash and PowerShell ports drift.** F13 (labels), A08 (flag arms), A07
  (canonical path), A15 (`version_gt`), U04 (timestamps) are all
  parity gaps. The port-parity finder is worth re-running after the fixes.
- **Promises in docs are load-bearing.** F01, F04, F06, F07, F09, F15, A11 are
  each a sentence in README, MANUAL, WINDOWS or a file header that the code
  contradicts. `tests/unit/docs.bats` is the right place to pin the corrected
  sentences.
- **Extend the fakes before fixing the installer items.** A01, A25, A26 and
  the F06 detection all need the fake docker to be able to fail and to
  dispatch on the command token. Doing that first makes the rest testable.
