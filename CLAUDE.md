# Working in this repository

Docker sandboxes for running Claude Code and Codex CLI in full-autonomy mode,
delivered as four `curl | bash` / `irm | iex` installers. `README.md` is the
user-facing guide; this file is for anyone changing the code.

## The one rule

**`install/` is generated. Never edit it directly.**

Edit `src/`, then rebuild. CI fails if the committed output does not match a
fresh build.

```bash
tools/fetch-tools.sh --with-pwsh   # vendor shellcheck, bats, pwsh into ./.bin (no root)
tools/build.sh                     # src/ -> install/
tools/test.sh                      # build + lint + unit + intg (+ e2e when docker is up)
```

A piped script cannot `source` a sibling, so `tools/build.sh` inlines the
shared library and embeds assets with two comment directives:

- `# @include lib/common.sh` — splice a file in verbatim (recursive)
- `# @embed assets/claude.Dockerfile AS ASSET_DOCKERFILE` — define a variable
  holding the file's contents

`@@VERSION@@`, `@@RAW_BASE@@` and `@@REPO_URL@@` are substituted everywhere.

## Hard constraints

These are not style preferences. Each one has already broken the build.

- **bash 3.2.** macOS still ships it as `/bin/bash`. No associative arrays, no
  `${v,,}`, no `mapfile`, no `local -n`. Critically, **bash 3.2 cannot parse a
  here-document nested inside `$( )`** — which is why assets are emitted as
  `__asset_NAME() { cat <<EOF ... EOF }` and the substitution applied to the
  function call. `tools/check-portability.sh` parses `install/*.sh` with the
  real `bash:3.2` image whenever a docker daemon is reachable.
- **BSD userland.** Feature-detect `sha256sum` vs `shasum`, `stat -c` vs
  `stat -f`; no `sed -i`, no `readlink -f`. This applies to the tests too — the
  macOS CI job runs them.
- **No jq dependency.** The manifest is flat `key=value`, parsed in pure bash.
  The launchers were careful to avoid jq; the installers must not reintroduce it.
- **Truncation safety.** Everything before the final `main "$@"` must be
  definitions only, so a cut-short download does nothing. Tested at six cut points.
- **shellcheck clean at `--severity=style`**, including the generated files and
  the launchers extracted from them.

## Tests

Four tiers, `tools/test.sh [build|lint|unit|intg|e2e]`:

| Tier | What it drives |
| --- | --- |
| `unit` | `src/lib/common.sh` sourced directly |
| `intg` | the built installers and launchers against a scripted fake `docker` |
| `e2e` | real Docker — real images, real UIDs, real volumes |

The fake `docker`, `curl`, `tmux`, `wsl.exe`, `git` and `gh` live in
`tests/fixtures/fakebin`. The last two are not optional niceties: the launcher
reads the host's git identity and, with `--sandbox-git`, its credential store.
Left unfaked, a suite run on a developer box reads a **real** identity — and,
with `credential.helper=store`, a **real token** — straight into
`$FAKE_DOCKER_ARGV`, which `fail_with` dumps into the CI log. `common_setup`
pins `GIT_CONFIG_GLOBAL`, `GIT_CONFIG_NOSYSTEM`, `XDG_CONFIG_HOME` and
`GIT_TERMINAL_PROMPT` for the same reason; a throwaway `HOME` alone does not
close it.
Production code carries deliberate test seams, all named `SANDBOX_FAKE_*`:
`SANDBOX_FAKE_UID`, `SANDBOX_FAKE_UNAME_S`, `SANDBOX_OS_RELEASE`,
`SANDBOX_PROC_VERSION`, `SANDBOX_FAKE_EUID`, `SANDBOX_FAKE_PWD`, and so on.

**Tests must not assume Linux.** Do not invent a `PATH` from scratch (use
`path_excluding` / `path_without` in `tests/helper.bash`); pin the platform with
`SANDBOX_FAKE_UNAME_S=Linux` when asserting Linux-only output; and remember
that both launchers mount the *physical* working directory (`pwd -P`), which on
macOS is the `/private/var` form and not the `/var` one — a test asserting on
bash's logical `$PWD` passes on Linux and fails there.

Sweep for hidden assumptions with:

```bash
SANDBOX_FAKE_UNAME_S=Darwin bats tests/unit tests/integration
```

## CI

`.github/workflows/test.yml` runs on push to `main` and on pull requests:
`generated-files-are-fresh`, `lint-and-test`, `macos` (bash 3.2 + BSD),
`e2e` (real Docker), `windows-smoke` (real PowerShell). Every job is
time-boxed, and `tools/test.sh` time-boxes each bats run, because a wedged
test process otherwise hangs a job until the six-hour limit
(`SANDBOX_TEST_TIMEOUT` overrides the default).

Windows CI cannot do a full install: GitHub's Windows runners offer only
Windows containers and WSL1, and these are Linux images. That job therefore
asserts the installer *refuses* correctly, and the PowerShell behavioural suite
runs under `pwsh` on the Linux runner.

## Bugs worth not reintroducing

- `useradd -u 1000` fails on `node:24-slim`: it already ships a `node` user at
  UID/GID 1000, the first non-root UID on most Linux hosts. The Dockerfiles
  rename the occupying identity instead of erroring.
- `curl … | sh` exits 0 when curl fails, because sh reads empty input. Download
  to a file and chain with `&&` so a failed download is fatal.
- Hash embedded assets with `asset_sha`, not `sha256_string`: `atomic_write`
  appends a newline that `$(cat <<EOF)` stripped, so the raw string never
  matches the file and nothing ever compares as unchanged.
- **`~/.bashrc` is not read by a login shell.** A new Terminal window on macOS
  and every ssh session read `~/.bash_profile`/`~/.bash_login`/`~/.profile`
  instead. Writing the PATH block only to `~/.bashrc` made "new terminals get
  it automatically" a promise the installer did not keep. `login_rc_file`
  covers the second file, and the block is self-guarding so having it in both
  never stacks a PATH entry.
- **"Did I edit an rc file?" is not "is the launcher runnable?"** Installing
  the second agent finds the marker already present and writes nothing — and
  used to say nothing, leaving the launcher un-runnable with no explanation.
  `PATH_NEEDS_RELOAD` keys off the *current* `$PATH`, not off having written.
- **stdout is a contract.** The installers emit the `export PATH=…` line, and
  nothing else, on stdout so that `eval "$(curl … | bash)"` works; every
  diagnostic goes to stderr. The docker build stream is the one that keeps
  trying to leak — `tee "$log" >&2` in `build_image`, and
  `| ForEach-Object { [Console]::Error.WriteLine($_) }` in `Invoke-Build`.
  PowerShell needs the explicit `-PrintPath` switch instead of an
  is-it-captured test: its success stream reaches `| iex` without the
  process's stdout ever being redirected.
- **The docker socket's group must be read from inside a container.** The host's
  own `stat` of `/var/run/docker.sock` answers for the host's filesystem, and on
  Docker Desktop that is not the file the container gets — the socket is re-owned
  inside the VM, so the host's GID is simply the wrong number and `--group-add`
  built from it yields "permission denied" with nothing to point at.
  `docker_socket_gid` mounts the socket into a throwaway container and asks
  `stat -c %g` there, and there is deliberately **no host-side fallback**: it
  would be consulted exactly when the probe failed, and it is wrong precisely on
  the platforms where that is likeliest. Unknown is reported as unknown. For the
  same reason the socket path comes from `docker context inspect`, not a hard-coded
  `/var/run/docker.sock`: rootless daemons, Colima and OrbStack all put it
  elsewhere, and a `tcp://` or `ssh://` endpoint has no socket to mount at all.
- **Compare paths physically, on both sides.** Mount sources are resolved with
  `pwd -P`, so anything they are compared against must be too. `--sandbox-ro`
  first checked a resolved source against the raw `$HOME`; on the macOS runner,
  whose temp tree is `/var/folders` = `/private/var/folders`, the home-directory
  refusal silently stopped applying. Likewise `/etc`, `/tmp` and `/var` on
  macOS resolve into `/private`, so a test that expects `/etc` to be treated
  as a system path passes on Linux and fails there.
- **One mount point is one project identity.** Both agents key their
  per-project state on the working directory *string* — Claude Code's
  `~/.claude/projects/<cwd-slugified>/` (session transcripts *and* memory), the
  per-project approvals in `.claude.json`, and the `cwd` Codex writes into every
  session rollout. Mounting every project at a fixed `/workspace`, as v1.0.0
  did, made every repository on the host one project to the agent: a single
  shared memory store, a `--resume` list mixing them all, and approvals leaking
  between them. The launchers mirror the host path instead (`-v "$PWD:$PWD" -w
  "$PWD"`; on Windows `C:\x` becomes `/mnt/c/x`, matching WSL). Do not
  reintroduce a constant mount path — and if a guard ever sends a project back
  to `/workspace`, it must say so out loud, because a silent fallback rebuilds
  the collision invisibly.

## Docs

`README.md` (installers, daily use), `MANUAL.md` (the hand-build reference),
`WINDOWS.md` (WSL2 vs native). `tests/unit/docs.bats` checks they stay honest —
documented flags exist, URLs resolve, versions are stamped, and MANUAL.md's
Dockerfiles match the shipped ones. Update the docs in the same commit as the
behaviour they describe.
