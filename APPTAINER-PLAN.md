# Apptainer mode: implementation plan and onboarding guide

> **For the agent picking this up.** This document is self-contained. It records
> what was decided, what was measured on a real Apptainer install, and what is
> still unverified. Read `CLAUDE.md` first: it holds the non-negotiable
> constraints (generated `install/`, bash 3.2, BSD userland, no jq, truncation
> safety, shellcheck at `--severity=style`). Everything below assumes them.
> Line numbers refer to v1.5.2 and are approximate (`~`); re-locate them before
> editing.

---

## 1. Context

The sandboxes run Claude Code and Codex CLI in full-autonomy mode inside
Docker. Shared Linux systems (HPC clusters, lab servers) often do not let users
run Docker, because access to the Docker daemon is root-equivalent. They often
do provide **Apptainer**, which runs unprivileged.

**Goal:** a user picks the runtime per launch, and everything else works the
same way. The Apptainer mode must lock down the host **as tightly as the Docker
mode does**, and it may require nothing on the host except Apptainer itself.

A feasibility study (v1.5.2, Apptainer 1.4.5 unprivileged on Ubuntu 24.04/WSL2)
concluded this is feasible, with one deliberate behavioural difference:
**network access is proxy-only.**

## 2. Decisions already made (do not re-litigate)

| # | Decision | Why |
|---|---|---|
| D1 | **Runtime is chosen per launch**: `--sandbox-runtime=docker\|apptainer` (also `--sandbox-runtime X`), or `SANDBOX_RUNTIME`. The installer sets up every runtime the user asks for (`--runtime all` sets up both). | Owner's choice. Images and state differ per runtime, so the user must say which runtime a session uses. **Refinement:** with no `--runtime` flag, a host where Docker works gets Apptainer only when asked, or when the manifest already records it (§5.3). Otherwise every Docker user who also has Apptainer installed would get an unrequested ~3-minute fakeroot build on `--sandbox-upgrade`. |
| D2 | **Apptainer images are built locally** with `apptainer build --fakeroot` from a hand-maintained `.def` next to each Dockerfile. A test keeps the `.def` and the Dockerfile in step. | Owner's choice. It keeps the current model: readable source, built where it runs. Building from a Dockerfile needs Apptainer ≥1.5 plus a BuildKit or Docker daemon, so it is out. |
| D3 | **Network is proxy-only egress.** The sandbox has no network namespace route out. An HTTP CONNECT proxy runs outside it and is reached over a unix socket. There is no SOCKS and no host-network opt-in. | Owner's choice. Unprivileged Apptainer offers only host networking or none. This is the same pattern as Anthropic's `sandbox-runtime`. |
| D4 | **Linux and WSL2 only.** The PowerShell launcher refuses `apptainer` with a pointer to WSL2. | Apptainer does not run natively on macOS or Windows. |
| D5 | **Nothing beyond Apptainer.** No pasta, slirp4netns or socat. The proxy and relay are node scripts run with the image's own `node`. | Owner's constraint. Both images are `FROM node:24-slim`. |

## 3. What was measured (evidence)

All of this was done by hand on Apptainer 1.4.5 in non-setuid mode, with
`/etc/subuid` present.

| Behaviour | Result |
|---|---|
| Plain `apptainer exec`, no flags | **Unsafe.** Host `$HOME` is mounted read-write (including `~/.ssh`), the host environment passes in (a test `SECRET_TOKEN` leaked), host PIDs are visible, and the host `/tmp` is shared. |
| `--containall` | Home is an empty tmpfs, the environment is cleaned (`TERM` kept, `LANG` dropped), there is a PID namespace with `appinit` as PID 1, IPC is private, and `/tmp` is a 64 MiB tmpfs. |
| Zombie reaping under `--containall` | 0 zombies (`appinit` reaps). |
| `/tmp` capacity | A 100 MB write is silently truncated at 64 MiB. With `--workdir DIR`, `/tmp` is disk-backed and the full write succeeds. |
| Current directory | It is **not** mounted under `--containall`; `--bind "$PWD" --pwd "$PWD"` mirrors it. |
| Site binds from `apptainer.conf` (`/etc/hosts`, `/etc/localtime`) | Still applied under `--containall`; `--no-mount bind-paths` removes them. |
| Capabilities and privileges | `CapEff=0`, `NoNewPrivs=1` by default. The root filesystem is read-only, so writes to `/usr` and to image directories return EROFS. |
| File ownership | Files written to binds are owned by the invoking host UID. The image's baked UID label (4242) was irrelevant. |
| `--home DIR:/home/agent` | Sets `HOME=/home/agent`, but **shadows everything the image installed under `/home/agent`**: `claude` was no longer found. |
| Default networking | Shares the host network: a service on the host's `127.0.0.1` was reachable, and 7 host abstract sockets (systemd and D-Bus) were visible. |
| `--net --network=none`, unprivileged | Works: no route out, host loopback unreachable, 0 abstract sockets. `--net` with a bridge, unprivileged, fails ("network requires root or a suid installation"). |
| Unix-socket egress proxy (prototype, Appendix A) | `api.anthropic.com` reachable, `git ls-remote https://github.com/...` OK, `npm view` OK, `pip download` OK. Host loopback refused by the proxy; no DNS inside. |
| Unix socket path length | Longer than 108 bytes fails with `EINVAL`, so the socket dir must be bound at a short path (`/egress`). |
| Docker image to SIF (`docker-daemon://`) | 25 s; 1.74 GB image became a 677 MB SIF. Labels survive (`apptainer inspect --labels`). |
| `apptainer build --fakeroot` from a `.def` (Codex: apt + `npm install -g`) | 3 min 12 s, no root, no Docker; 454 MB SIF. |
| Claude Code under `--containall` with config bound | First-run TUI renders; `.claude.json`, sessions and cache persist to the bind. |
| Apptainer nested inside a launcher-made `unshare --user --net` | Works. Not needed, since `--network=none` does the same. |

## 4. Architecture

```
host (user's own UID, no root)
├─ launcher: claude-sandbox --sandbox-runtime=apptainer ...
│   ├─ session dir (0700, local disk): sock/ work/ home/ life.fifo
│   ├─ [A] egress proxy   apptainer exec --containall --no-eval --no-privs
│   │                     --no-mount bind-paths  (HOST network)
│   │                     node /opt/agent-sandbox/egress-proxy.js /egress/e.sock
│   │                     └─ exits when life.fifo hits EOF (launcher gone)
│   └─ [B] sandbox        apptainer run --containall --no-eval --no-privs
│                         --no-mount bind-paths --net --network=none
│                         --workdir work --home home:/home/agent
│                         --bind <sorted binds> --pwd <project>  claude.sif
│                         runscript: start relay 127.0.0.1:3128 -> /egress/e.sock,
│                                    wait until listening, exec agent
└─ state (0700): ${XDG_DATA_HOME}/agent-sandbox/apptainer/
     claude.sif  codex.sif  *.labels  claude-config/  claude-local/  codex-config/
```

Docker stays exactly as it is today, apart from the image-layout prep in M0.

## 5. Design

### 5.1 Image layout (both runtimes, M0)

- Move tooling out of `/home/agent` into **`/opt/agent-sandbox/`**:
  - the Claude seed and entrypoint, now `/opt/agent-sandbox/claude-seed/` and `/opt/agent-sandbox/entrypoint`
  - Codex, via `npm install -g --prefix /opt/agent-sandbox/codex`
  - the proxy and relay scripts
- `/home/agent` keeps only empty mount points.
- **Keep the Docker image's populated `/home/agent/.local`.** Docker fills a *new*
  volume from the image, and `tests/e2e/real-docker.bats` (~:147, "no download")
  depends on that. Allowlist that step in the parity test.
- Set `ENV NPM_CONFIG_PREFIX=/home/agent/.npm-global` in both images. Today
  `npm config set prefix` writes `~/.npmrc`, which `--home` hides.
- **Reshape the Dockerfiles so every `RUN` runs as root** with absolute paths and
  an explicit `HOME=`, before `USER agent`. Apptainer's `%post` runs as fake root
  with `HOME=/root` and without the `ENV` lines, so this is what makes the RUN
  bodies identical. The Claude native installer must run with
  `HOME=/opt/agent-sandbox/claude-home` (or similar) and its binary is then
  hard-linked into the seed. Download into the rootfs, not `/tmp` (see §8).
- `reserved_container_path` (`launcher-common.sh` ~:127) must reserve:
  - `/opt/agent-sandbox` and everything under it
  - `/egress`
  - `/.singularity.d`, `/singularity` and `/environment`

  `SANDBOX_WORKDIR` (~:139) must also be checked against this list. That is an
  existing gap.
- Sync `MANUAL.md`, whose Claude Dockerfile is checked line by line by
  `tests/unit/docs.bats` (~:108).

### 5.2 `.def` files (M1)

- Add `src/assets/claude.def` and `src/assets/codex.def`. Each is
  `Bootstrap: docker` / `From: node:24-slim`.
- Omit the Docker-only steps: the UID rename and `COPY --from=docker:29-cli`.
- Add the Apptainer-only steps:
  - `userdel node`, so `id -un` and `getpwuid` don't resolve to `node`/`/home/node`
  - `APT::Sandbox::User "root";`, for root-mapped fakeroot without subuid
  - `%runscript` (relay + exec)
  - `%environment` mirroring the Dockerfile `ENV`s
- **Codex is not baked into `codex.sif`** (see §5.8).
- **Parity test** (`tests/unit/images.bats`): every `RUN` body in a Dockerfile must
  appear verbatim in the matching `.def`'s `%post`, and every `ENV` must appear in
  `%environment`, except an explicit allowlist with a comment per entry.
- **Freshness:** a `key=value` sidecar next to the SIF (`claude.sif.labels`)
  records `def_sha`, `installer_version` and, for Codex, `codex_version`. Read it
  in pure bash. Don't parse `apptainer inspect`, and don't depend on
  version-gated `--build-arg` templating.

### 5.3 Installer (M1)

- **Runtime detection** replaces the hard Docker preflight (`src/lib/common.sh`
  `preflight` ~:609, `docker_check` ~:318).
- **"Usable" means usable.** A docker CLI without daemon permission counts as
  absent, quietly. Apptainer is usable when all of these hold:
  - `apptainer` is present, at a version ≥ the minimum (to be set; see §8, item 6)
  - it can run (user namespaces or setuid)
  - for building, it can do `--fakeroot` (subuid, or a fallback mode)
  - Ubuntu's `kernel.apparmor_restrict_unprivileged_userns` is handled
- Decide whether to accept SingularityCE (`singularity` only) or refuse it
  explicitly.
- **`--runtime docker|apptainer|all`.** With no flag:
  - Docker if it is usable.
  - Otherwise Apptainer.
  - Plus whatever runtimes the manifest already records, so upgrades keep them.

  **A Docker user who happens to have Apptainer installed never gets a surprise
  fakeroot build** on `--sandbox-upgrade`. In auto mode, an Apptainer failure is
  a warning. Keep exit codes 10 and 11 for "no runtime usable", so the existing
  preflight tests keep their meaning.
- **When a runtime is missing or only partly usable:**
  1. **Neither runtime is usable.**
     - Exit **10** when neither is installed at all. Exit **11** when at least
       one is installed but none can be used.
     - The message covers *both* runtimes:
       - one line each saying why it's unusable (not installed, no daemon
         permission, version too old, cannot build, …)
       - then both remedies: the existing Docker install help
         (`docker_missing_help` / `docker_unreachable_help`), and an Apptainer
         route ("ask your administrators for Apptainer ≥ X in unprivileged mode,
         with a subordinate UID range for your account")
     - On macOS the Apptainer line says it is Linux and WSL2 only.
  2. **A runtime asked for by name can't be set up.** If `--runtime docker` or
     `--runtime apptainer` names a runtime that can't be set up, **fail loudly**:
     - print that runtime's reason
     - use the same exit-code rule as above
     - install nothing for the other runtime

     A build failure for a runtime asked for by name is fatal, as a failed
     `docker build` is today (exit 1).
     **`--runtime all`** sets up whatever is usable. It prints one line per
     skipped runtime saying why, and fails only if none is usable. In auto mode
     (no flag), an Apptainer failure stays a warning.
  3. **Apptainer can run containers but cannot build images.** This happens with
     an older setuid install, no subordinate UID range, or no working fakeroot
     fallback. Images are built locally (D2), so these users get nothing. **The
     installer must say so precisely** rather than fail inside `apptainer build`:
     - what is missing, e.g. "no subordinate UID range for `<user>` in
       `/etc/subuid`, and the fakeroot fallback is unavailable"
     - what an administrator would change (e.g. `usermod --add-subuids`, or
       allowing unprivileged user namespaces)

     Detect this *before* building. How to probe it is open (§8, item 6);
     candidates are a subuid/libsubid lookup plus `apptainer buildcfg`. When
     Apptainer was the only candidate, this counts as unusable (exit 11).
     *Open question for the owner:* a SIF built from the same `.def` is not
     UID-specific, so an `--import-sif PATH` escape hatch could let these users
     build on another machine and copy the image in. It would check the
     sidecar's `def_sha` and refuse if the SIF and its directory are group- or
     world-writable. It is not part of the plan until the owner decides.
- **Manifest** (`manifest_write` ~:389) gains:
  - `runtimes=docker apptainer`
  - `default_runtime=` (Docker if it was usable at install time, else Apptainer)
  - `sif_dir=`
  - `def_sha=`
- **SIF build:**
  1. Build into a temp file, then `mv` it into place. Never overwrite a SIF a
     running session has mounted.
  2. Take a `mkdir` lock first.
  3. Point `APPTAINER_TMPDIR` at **local** `/tmp`, after a free-space check:
     fakeroot fails on NFS, Lustre and GPFS.
  4. Keep `APPTAINER_CACHEDIR` under `XDG_CACHE_HOME`, so each rebuild doesn't
     re-pull from Docker Hub. `--purge` clears it.
  5. Name the temp dir predictably, and document how to remove a leftover tree
     owned by subordinate UIDs.
- **State dirs** replace the named volumes:
  - Create `apptainer/`, `claude-config/`, `claude-local/` and `codex-config/`
    **mode 0700**. Docker volumes live in root-only `/var/lib/docker`, and
    `claude-config` holds `.credentials.json`.
  - Seed Codex's `config.toml` with a plain `cp`.
  - The UID-repair functions are not needed.
- `--check`, `--uninstall` and `--purge` cover Apptainer. `--check` re-verifies
  the directory modes and that the SIF and its directory are not group- or
  world-writable.
- Neutralise the agent hooks:
  - Codex's `agent_post_build` and `volume_has_config` call `docker run`.
  - `BUILD_EXTRA_ARGS` holds Docker `--label` flags, which `apptainer build`
    lacks.
  - `do_check` returns early with no Docker (~:893).
- The installer, the launcher and the tests all refuse Apptainer on Darwin.

### 5.4 Neutral data model (M0, prerequisite)

`GIT_ENV_ARGS` (Docker `-e` pairs, `launcher-common.sh` ~:169, ~:253, ~:260) and
`HOST_MOUNT_ARGS` (`-v` pairs, ~:507-509) are Docker-shaped. Replace them with
neutral lists, and let each runtime render its own syntax:
- env name/value pairs
- secret names
- bind src/dst/mode triples

Docker renders exactly today's argv; M0 proves that by changing nothing in the
existing tests.

### 5.5 Launcher: selection and dispatch (M2)

- Parse `--sandbox-runtime[=]X` in the **prefix loop** (`launcher_main`
  ~:838-850), so it combines with `--sandbox-doctor` and `--sandbox-tmux`.
- **Resolution order:** the flag, then `SANDBOX_RUNTIME`, then the manifest's
  `default_runtime`, then Docker.
- **Never fall back silently.** If Docker is the choice and its daemon is down,
  fail as today rather than switching to Apptainer. Apptainer has separate logins
  and memory.
- **Point at the other runtime, but never switch to it.** When the chosen
  runtime is unavailable at launch and the *other* runtime's image exists, the
  error ends with a hint. For example: "Apptainer is also set up here: rerun with
  `--sandbox-runtime=apptainer` (it keeps separate logins and memory)." The user
  still chooses. The same hint goes in `--sandbox-doctor`.
- **The chosen runtime's image doesn't exist.** This happens, for example, when
  `--sandbox-runtime=apptainer` is used before Apptainer was ever set up. The
  launcher stops and prints the install command for *that* runtime, as
  `ensure_docker_and_image` does today for a missing Docker image
  (`launcher-common.sh` ~:66):
  `curl -fsSL <RAW_BASE>/install/claude.sh | bash -s -- --runtime apptainer`.
  The `--runtime` part matters: without it, the installer on a machine where
  Docker works would not build the Apptainer image (§5.3). **Never build an
  image on first launch.** That would be a multi-minute stall at the prompt, and
  it fails unpredictably where fakeroot is unavailable.
- Print the runtime whenever it isn't Docker.
- **Every Docker-only call goes through a dispatcher:**
  - `ensure_docker_and_image` (~:864, and in `tmux_launch` ~:576 and ~:595)
  - the `doctor` early returns (~:651)
  - `docker_sock_args` (~:325)
  - Codex's `pre_run_hook` (`codex-sandbox` ~:43-83). It would otherwise run
    `docker build` on *every* Apptainer launch.
- `--sandbox-docker` is refused under Apptainer.
- **tmux:**
  - Re-emit the *resolved* runtime, plus any SIF or state-dir override, with
    `%q` in the command prefix (~:603). A tmux server that already exists
    doesn't pass the client environment to the new pane. That is an existing
    bug for `SANDBOX_WORKDIR` and `SANDBOX_NO_GIT` too; fix it at the same time.
  - Warn when attaching to a session that was started under the other runtime.
- **PowerShell** (`src/ps/assets/launcher-common.ps1`, mirroring the
  `--sandbox-docker` refusal at ~:572):
  - accept `=docker`
  - refuse `=apptainer` with a pointer to WSL2
  - ignore `SANDBOX_RUNTIME=apptainer` from the environment, with a note

### 5.6 Launcher: the Apptainer run path (M2)

The launcher cannot `exec`, because it must own the proxy's lifetime.

1. **Sweep** stale session dirs whose owner PID is dead.
2. **Create the session dir**, mode 0700:
   - `sock/` lives in `$XDG_RUNTIME_DIR` if set, else `mktemp -d` under `/tmp`.
   - `work/` and `home/` live on local disk.
   - `life.fifo` is the lifeline.
3. **Scrub the environment** for both `apptainer` invocations with `env -i` and an
   allowlist (`PATH`, `TERM`, `HOME`, `USER`, `LANG`, `XDG_RUNTIME_DIR`, plus the
   launcher's own `APPTAINERENV_*`). Module systems export `APPTAINER_BIND*`,
   `APPTAINERENV_*`, `SINGULARITY*`, `APPTAINER_NV` and others, and
   `--no-mount bind-paths` does not cover them. Doctor reports any it finds.
4. **Start the proxy** (§5.7) *before* exporting any secret, so the proxy (which
   sits on the host network) never holds the token:
   - stdio goes to `session/proxy.log`
   - fd 3 is closed, or bats hangs
   - it reads `life.fifo`, and the launcher holds the fifo open on fd 9 via
     `exec 9>`
   - wait for its `ready` marker, with a timeout
5. **Export the variables:**
   - every value as `APPTAINERENV_NAME`; **never `--env`**, which splits on
     commas and fails on bare quotes
   - git identity, `GIT_CONFIG_*`, and the token (never on argv)
   - the proxy variables: `HTTPS_PROXY`, `HTTP_PROXY`, `https_proxy`,
     `http_proxy` = `http://127.0.0.1:3128`, `NO_PROXY=localhost,127.0.0.1,::1`,
     and `NODE_USE_ENV_PROXY=1`, because Node 24's `fetch` ignores the proxy
     variables without it
6. **Build the bind list:**
   - project `src:dst`, the state dirs onto `/home/agent/.claude` and
     `.local` (or `.codex`), `sock/` at `/egress` **read-only**, and the
     ro/rw paths
   - **sort it by destination depth** (shallow first). Apptainer applies binds
     in argv order; Docker sorts them itself. Without sorting,
     `--sandbox-ro <parent of project>` would cover the project and make it
     read-only.
   - **Refuse paths containing `,` or `:`**. `--bind` splits on them. An
     alternative is `--mount` with CSV quoting.
   - Refuse a SIF, state dir or session dir that sits inside the project or any
     rw path.
7. **Run in the foreground:**
   `apptainer run --containall --no-eval --no-privs --no-mount bind-paths --net --network=none --workdir work --home home:/home/agent <binds> --pwd dst SIF <agent> "$@"`
   - `--no-eval` stops Apptainer shell-evaluating environment values. Without
     it, the credential helper's literal `$SANDBOX_GIT_TOKEN` text is expanded
     away, and a token containing `$` or a backtick is mangled or executed.
   - `--no-privs` drops any site-granted capabilities.
   - Keep `rc`.
8. **Clean up**, from a trap on EXIT, INT, TERM and HUP:
   - close fd 9, so the proxy exits
   - `chmod -R u+w`, then `rm -rf` the session
   - `exit "$rc"`; the tmux wrapper reads `$?`
9. **If `--net --network=none` is rejected** (setuid installs, site config, old
   versions), **refuse the launch with an explanation. Never retry without
   `--net`.**

### 5.7 Egress proxy and relay (contract fixed in M1, because it lives in the image)

**The contract.** Changing any of these later forces every user to rebuild:
- socket: `/egress/e.sock`
- relay: `127.0.0.1:3128`
- readiness: the proxy writes `/egress/ready` after it starts listening, and the
  relay logs to stderr
- the environment variables set in §5.6 step 5

**Proxy** (`/opt/agent-sandbox/egress-proxy.js`, in the SIF):
- It listens on the unix socket, mode 0600, inside a 0700 directory. Other local
  users cannot connect.
- It handles `CONNECT host:port`. Decide whether to also support absolute-form
  `GET http://`. The prototype handles only CONNECT, so `http://` URLs fail.
- **Destination policy, matching Docker:**
  1. Resolve the name and check **every** returned address.
  2. Connect to the *checked* address. Never pass the hostname to
     `net.connect`, or DNS rebinding gets around the check.
  3. Refuse:
     - loopback (`127/8`, `::1`, `::ffff:127.*`)
     - `0.0.0.0/8` and `::`, which reach localhost on Linux
     - link-local (`169.254/16`, cloud metadata, `fe80::/10`)
     - multicast
     - decimal, octal and hex IPv4 forms (normalise before checking)
  4. **Allow RFC1918 and ULA**, as Docker's bridge does. Cluster git servers and
     package mirrors live there. A deny-private mode can be an env knob later.
- Log refusals to `proxy.log`.
- Exit on EOF of the lifeline fifo.

**Relay** (`/opt/agent-sandbox/egress-relay.js`): accepts TCP on
`127.0.0.1:3128` and pipes each connection to `/egress/e.sock`. The runscript
starts it, **polls until it is listening**, then runs `exec "$@"`. The relay
must be up before the Claude entrypoint's `claude install`, because a new
`claude-local` dir always downloads through the proxy.

### 5.8 Codex under Apptainer (M2, not later)

- **Don't rebuild a SIF per Codex release.** Apptainer has no layer cache, so
  each release would cost about 3 minutes, and Codex ships several times a week.
- Instead, install Codex into a **versioned host state dir** with `npm install
  --prefix`, run through `apptainer exec` with host networking. Bind it
  read-only at `/opt/agent-sandbox/codex`.
- Switch versions with an atomic symlink, under a `mkdir` lock. If the update
  fails, keep the old version.
- The Codex `pre_run_hook` dispatches: under Docker it behaves as today, under
  Apptainer it updates the state dir.
- Codex's localhost login callback can't work under either runtime. Keep
  pointing users at device auth.

### 5.9 Doctor (M2)

The Apptainer section reports:
- the Apptainer version, its mode (setuid or unprivileged), userns and fakeroot
  capability
- the SIF path and labels sidecar
- state dir modes
- free space on the work dir
- any `APPTAINER_*`, `SINGULARITY*` or `APPTAINERENV_*` variables found in the
  host environment
- site binds and `always use nv`
- a proxy self-test

Doctor must not return early when Docker is absent.

## 6. Security parity

| Control | Docker | Apptainer mode |
|---|---|---|
| Host home and secrets not mounted | not mounted | `--containall` (default exposure is unsafe) |
| Host environment isolation | only `-e` | `env -i` allowlist + `--containall`, and `--no-eval` |
| Capabilities, `no_new_privs` | `--cap-drop=ALL`, `no-new-privileges` | default 0 and 1, plus `--no-privs` |
| PID 1 reaps orphans | `--init` | `appinit` (pid namespace) |
| Network | bridge: no host loopback, open egress | `--network=none` + proxy: no host loopback, no abstract sockets, HTTP(S)-only egress, no DNS |
| Persistent state privacy | root-only volumes | 0700 dirs, checked |
| Secrets off the command line | bare `-e NAME` | `APPTAINERENV_*`, exported after the proxy starts |
| Root filesystem | writable, ephemeral | read-only SIF (stricter); writable `/tmp` and home are per session |

**Residual differences.** Document all of these in the README security notes:
- **No seccomp profile.** Docker's default profile blocks `unshare`, `bpf`,
  `keyctl`, `mount` and similar. Under Apptainer, `unshare -Urm` probably works
  inside. That is not an escape, since inherited mounts stay locked and the
  network stays isolated, but the kernel attack surface is larger.
- The host's hostname (UTS) and `/sys` are shared.
- Site `always use nv` binds GPU devices.
- **Proxy-only egress:** git over ssh, raw TCP and DNS lookups don't work.
- State is separate per runtime: two logins and two memory stores.
- SQLite on NFS homes (Codex's state DB) is unreliable.

## 7. Work plan

Each milestone leaves the tree green. **Release only after M0, and after M2.**
M1 by itself would ship a SIF that nothing can run.

- **M0: prepare (Docker only, released as a minor version).**
  - §5.1: `/opt` layout, root-only `RUN`s, `NPM_CONFIG_PREFIX`, reserved paths,
    MANUAL sync.
  - §5.4: neutral env and bind model.
  - Fix the tmux env re-emission bug.

  This rebuilds every user's image; say so in the release notes.
  Files:
  - `src/assets/claude.Dockerfile`, `src/assets/codex.Dockerfile`
  - `src/assets/launcher-common.sh`, `src/assets/claude-sandbox`, `src/assets/codex-sandbox`
  - `MANUAL.md`, plus the matching tests
- **M1: Apptainer image and installer** (§5.2, §5.3, §5.7 contract):
  - `src/assets/{claude,codex}.def`
  - `src/assets/egress-proxy.js`, `src/assets/egress-relay.js` (embedded with
    `# @embed` or `%files`)
  - `src/lib/common.sh`, `src/codex.sh`
  - `tests/fixtures/fakebin/apptainer`
  - `tests/unit/images.bats`
  - intg tests in `tests/integration/claude-install.bats` and `codex-install.bats`
- **M2: the Apptainer launcher, end to end** (§5.5–5.9):
  - the run path, the proxy lifecycle, Codex state-dir installs, doctor,
    PowerShell refusal
  - `tests/e2e/real-apptainer.bats`
  - a `tools/test.sh` `e2e-apptainer` tier
  - an `apptainer` CI job
  - docs: README, MANUAL, WINDOWS, CLAUDE.md
  - release

## 8. Verify before you build on it

Each item is an assumption from docs or the design review that was **not**
measured. Check it on a real Apptainer and record the result in this file.

1. Do `APPTAINERENV_*` variables reach the container under `--containall`? Does
   `--no-eval` keep `$`, backticks and `"` byte-identical (the credential helper)?
2. Is bind order really applied in argv order, so that depth sorting is required?
   Does a `--sandbox-ro` *file* on a path missing from the SIF work (via underlay)?
3. Is `/egress` bound read-only still connectable as a unix socket?
4. Inside `%post` under fakeroot: is `/tmp` the 64 MiB tmpfs (the 200 MB Claude
   download)? Does the native installer work with `HOME` overridden? Does
   `apt-get` work with and without a subuid entry?
5. Do `claude install`, Claude Code, Codex (Rust), npm, pip, cargo and git all
   honour the proxy variables? Is `NODE_USE_ENV_PROXY` needed in practice?
6. What is the minimum Apptainer version? Check `--no-mount`, `--no-eval`,
   unprivileged `--network=none` and `--no-privs` on the oldest version you claim.
   How do setuid installs and SingularityCE differ?
7. Can the GitHub `ubuntu-latest` runner do unprivileged Apptainer? (AppArmor
   userns sysctl or the PPA's profile, plus a subuid entry for `runner`.)
8. Is `/dev/shm` usable under `--contain`? (Browsers, Playwright.)

## 9. Testing

- **Fake `apptainer`** (`tests/fixtures/fakebin/apptainer`), modelled on the fake
  `docker`:
  - **Opt-in only:** it behaves as "not installed" (`exit 127`) unless
    `FAKE_APPTAINER=1`. Otherwise every existing installer test changes in auto
    mode.
  - It records argv (`FAKE_APPTAINER_ARGV`) and the resolved `APPTAINERENV_*`
    (`FAKE_APPTAINER_ENV`).
  - `build` writes the SIF and sidecar into state.
  - `exec` of the proxy writes the `ready` marker. Don't fake a unix socket;
    a real one isn't portable.
  - It must be BSD-portable, for the macOS job.
  - **It lands in the same commit as runtime detection.** Otherwise a developer
    box with real Apptainer runs real fakeroot builds inside the intg tier.
- **Wire the fake in:**
  - Add it to the explicit shellcheck list in `tools/test.sh` (~:89).
  - Make `path_without` (`tests/helper.bash` ~:89) accept several tools, so
    `path_without docker` stays a no-runtime host. The six "docker missing → exit
    10" tests depend on that.
  - If a host-side `stat -c` gets added, extend `check-portability.sh`.
- **Integration:**
  - The installer with only Apptainer, with both, and with neither.
  - Neither runtime: exit 10 when neither is installed, 11 when one is installed
    but unusable. The message names both runtimes and both remedies.
  - `--runtime apptainer` or `--runtime docker` naming an unusable runtime fails
    and installs nothing else. `--runtime all` with one unusable runtime sets up
    the other and names the skipped one.
  - Apptainer that can run but not build gets the specific "cannot build"
    explanation, with no `apptainer build` attempted. The fake `apptainer` needs
    a knob for this.
  - An upgrade on a Docker+Apptainer host must not build a SIF unless asked.
  - At launch:
    - A missing image prints the install command with `--runtime <that runtime>`
      and builds nothing.
    - An unavailable chosen runtime hints at the other only when the other's
      image exists, and never switches to it.
  - Launcher argv must contain `--containall`, `--no-eval`, `--no-privs`,
    `--no-mount bind-paths`, `--net --network=none`, sorted binds and the
    read-only `/egress`. The token must be absent from argv and present in the
    environment.
  - Comma paths are refused, `--sandbox-docker` is refused, the runtime is
    re-emitted into tmux, doctor reports correctly, and the proxy and session
    are cleaned up.
  - Pin `SANDBOX_FAKE_UNAME_S=Linux`; Darwin must refuse.
- **Unit:** the proxy's destination-policy table (via `node` in CI, or a
  bash-tested pure function), runtime resolution, and the parity test.
- **docs.bats:**
  - README `--sandbox-runtime` needs a literal `--sandbox-runtime)` case arm.
  - Add `--runtime` to the installer flag list (~:58).
  - Add the `apptainer` CI job to the job list (~:170) and to CLAUDE.md.
  - Add a state-dir equivalent of the volume test.
  - Add a MANUAL `.def` mirror check.
- **e2e** (`tests/e2e/real-apptainer.bats`, gated on a usable Apptainer):
  - Port the parity checks: zombie reaping, `CapEff`/`NoNewPrivs`, no route out,
    0 abstract sockets, proxy refusals, the API and `git ls-remote` via the
    proxy, bind ownership, read-only mounts return EROFS, ro/rw nesting, the
    credential helper intact, `/tmp` capacity, state persistence.
  - Run the real launcher end to end (e.g. `claude-sandbox --sandbox-runtime=apptainer --version`).
    Apptainer needs no `-it`, so this is possible.
- **CI:** a new `apptainer` job on `ubuntu-latest`, installing from
  `ppa:apptainer/ppa`, with the userns/AppArmor fix and a subuid entry, and a
  timeout of 45 minutes or more.

## 10. Pitfalls already found

- Apptainer's defaults are the opposite of a sandbox. Every invocation, including
  the proxy and the build helpers, needs `--containall`.
- Unix socket paths are limited to 108 bytes, so bind the socket dir at `/egress`.
- `/tmp` is 64 MiB unless `--workdir` is passed, and writes past that fail
  quietly.
- `--home` hides everything in the image under that path. That is why the tools
  move to `/opt`.
- `--bind` splits on `,` and `:`. `--env` splits on `,` and fails on `"`.
- Values are shell-evaluated without `--no-eval`.
- Host `APPTAINER_*` and `APPTAINERENV_*` variables leak in unless the
  environment is scrubbed.
- The design review also flagged the plain bash background-job trap: a
  backgrounded proxy shares the terminal's process group (Ctrl-C reaches it),
  and a SIGKILL'd launcher orphans it. Hence the lifeline fifo.
- bats hangs while a background child holds fd 3.

## 11. Done when

- `claude-sandbox --sandbox-runtime=apptainer` and `codex-sandbox
  --sandbox-runtime=apptainer` work on a host with Apptainer and **no** Docker,
  with every `--sandbox-*` flag except `--sandbox-docker`.
- Every §6 control is asserted by an e2e test.
- All tiers are green locally and in CI, including the new `apptainer` job and
  macOS.
- The docs describe the runtime choice, the proxy-only egress and the residual
  differences.

---

## Appendix A: prototype code (proven working; harden per §5.7 before shipping)

The proxy runs outside the sandbox, on the host network:
`apptainer exec --containall --no-mount bind-paths --bind $SOCKDIR:/egress --bind egress.js:/opt/egress.js:ro claude.sif node /opt/egress.js /egress/e.sock`

```js
// egress.js: HTTP CONNECT proxy on a unix socket. PROTOTYPE: its blocklist is
// a regex on one dns.lookup result; §5.7 requires checking all addresses,
// connecting to the checked one, and normalising numeric forms.
const net = require('net'), dns = require('dns'), fs = require('fs');
const sock = process.argv[2];
try { fs.unlinkSync(sock); } catch {}
const blocked = a => /^(127\.|10\.|192\.168\.|169\.254\.|0\.|172\.(1[6-9]|2\d|3[01])\.|::1$|::$|f[cd]|fe80:|::ffff:(127|10|192\.168|169\.254)\.)/i.test(a);
net.createServer(c => {
  c.once('data', buf => {
    const m = /^CONNECT ([^:\s]+):(\d+) HTTP\/1\.[01]\r\n/.exec(buf.toString('latin1'));
    if (!m) { c.end('HTTP/1.1 405 CONNECT only\r\n\r\n'); return; }
    dns.lookup(m[1], (err, addr) => {
      if (err) { c.end('HTTP/1.1 502 DNS failure\r\n\r\n'); return; }
      if (blocked(addr)) { c.end('HTTP/1.1 403 Destination refused\r\n\r\n'); console.error('refused', m[1], addr); return; }
      const u = net.connect(+m[2], addr, () => { c.write('HTTP/1.1 200 Connection established\r\n\r\n'); u.pipe(c); c.pipe(u); });
      u.on('error', () => c.destroy()); c.on('error', () => u.destroy());
    });
  });
}).listen(sock, () => { fs.chmodSync(sock, 0o600); console.error('egress proxy on', sock); });
```

(The prototype blocked private ranges too. §5.7 allows them, to match Docker.)

The relay runs inside the sandbox, under `--net --network=none`:

```js
// relay.js: the private namespace's loopback to the bind-mounted socket
const net = require('net');
net.createServer(c => { const u = net.connect(process.argv[2]); c.pipe(u); u.pipe(c);
  u.on('error', () => c.destroy()); c.on('error', () => u.destroy()); }).listen(3128, '127.0.0.1');
```

Sandbox invocation used in the test:
`apptainer exec --containall --no-mount bind-paths --net --network=none --bind $SOCKDIR:/egress --bind relay.js:/opt/relay.js:ro --bind $PROJ --pwd $PROJ --env HTTPS_PROXY=http://127.0.0.1:3128 --env HTTP_PROXY=http://127.0.0.1:3128 claude.sif sh -c 'node /opt/relay.js /egress/e.sock & ...'`
(Ship `APPTAINERENV_*` instead of `--env`, plus `--no-eval` and `--no-privs`; see §5.6.)

## Appendix B: references

- Apptainer networking (unprivileged users get only `none`): https://apptainer.org/docs/user/1.4/networking.html
- Apptainer fakeroot modes: https://apptainer.org/docs/user/1.4/fakeroot.html
- User namespaces and fakeroot (admin): https://apptainer.org/docs/admin/1.5/user_namespace.html
- `sessiondir max size` / `--workdir`: https://apptainer.org/docs/admin/1.3/configfiles.html
- Building from a Dockerfile needs 1.5 plus a daemon: https://apptainer.org/docs/user/1.5/build_a_container.html
- Same egress pattern: https://github.com/anthropic-experimental/sandbox-runtime
