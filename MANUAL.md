# Manual setup — building the sandboxes by hand

> **You probably want [the installers](README.md) instead.** One command per agent
> sets all of this up, keeps it upgradable, and repairs the ownership problems
> documented at the bottom of this page:
>
> ```bash
> curl -fsSL https://raw.githubusercontent.com/mriffle/llm-cli-docker-sandbox/main/install/claude.sh | bash
> curl -fsSL https://raw.githubusercontent.com/mriffle/llm-cli-docker-sandbox/main/install/codex.sh  | bash
> ```
>
> This page is the reference: exactly what those scripts create and why, for
> anyone who wants to read it before running it, customise the images, or build
> the whole thing without running a script at all.

The problem this solves: you want to run a coding agent with permission prompts disabled (`--dangerously-skip-permissions` / `--yolo`), but you don't trust the agent to respect instructions like "don't touch files outside this directory." Instead of trusting the agent, these setups make the boundary physical: the agent runs in a container where **the only host path it can see is the project directory you launched it from**, plus small named volumes for credentials and state.

Design principles:

- **Docker is the sandbox.** No reliance on agent self-restraint or agent-internal sandboxing.
- **Log in once.** Auth tokens persist in per-user named volumes across sessions and rebuilds.
- **Minimal images.** The image is a sandbox skeleton plus everyday toolchains (C, Python, Rust). Anything else a project needs gets installed into that project's own directory (`./.jdk`, `./.bin`, `./.venv`) — resist adding it to the image.
- **Per-user everything.** Volume and container names are namespaced by `$USER` so multiple users on a shared rootful Docker daemon don't collide.

## What you'll create

Nothing needs to be cloned — read along and create the files on your system. By the end you'll have:

```
~/claude-sandbox/Dockerfile        # Claude Code image definition
~/codex-sandbox/Dockerfile         # Codex CLI image definition
~/codex-sandbox/config.toml        # Codex autonomy config (seeded into its volume)
~/.local/bin/claude-sandbox        # Claude launcher script
~/.local/bin/codex-sandbox         # Codex launcher script
```

plus two Docker images and three named volumes that the launchers create and maintain.

The installers create the same files, with two additions: a manifest under
`~/.local/share/agent-sandbox/` recording what was installed, and launchers that
carry `--sandbox-tmux`, `--sandbox-docker`, `--sandbox-ro`, `--sandbox-doctor`
and `--sandbox-upgrade`. The hand-built launchers below are the plain versions.

These instructions target Linux and macOS hosts. **Windows users:** see
[WINDOWS.md](WINDOWS.md).

## Before you start: a bin directory on your PATH

The setups below install small launcher scripts (`claude-sandbox`, `codex-sandbox`) that you'll run by name from any project directory. For that to work, the scripts must live in a directory that's on your **PATH** — the list of directories your shell searches when you type a command. If they're not, you'll get `command not found` even though the file exists.

**Step 1 — check whether you already have one.** The conventional per-user script directory on modern Linux is `~/.local/bin` (some setups use `~/bin`). See if it's already on your PATH:

```bash
echo "$PATH" | tr ':' '\n' | grep "$HOME"
```

If the output includes `/home/<you>/.local/bin` (or `/home/<you>/bin`), you're set — use that directory in the install steps below and skip to the next section.

**Step 2 — if not, create one and add it to your PATH.** These instructions use `~/.local/bin`:

```bash
mkdir -p ~/.local/bin
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

(If your shell is zsh, use `~/.zshrc` instead of `~/.bashrc`. The `source` command applies the change to your current terminal; new terminals pick it up automatically. Note for Debian/Ubuntu users: the default `~/.profile` already adds `~/.local/bin` to PATH *if the directory exists* — but only at login, so after `mkdir` you'd still need to log out and back in. The `~/.bashrc` line above works immediately and unconditionally.)

One caveat if you keep your own dotfiles: a bash **login** shell — a new Terminal window on macOS, every ssh session — reads `~/.bash_profile`, `~/.bash_login` or `~/.profile`, and never `~/.bashrc` unless one of those sources it. If yours doesn't, add the same line to whichever of those files you have, or `~/.bashrc` will be read only by non-login shells and `command not found` will follow you into every new session. Making the line self-guarding lets you put it in both files without stacking duplicate PATH entries:

```bash
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac
```

(This is exactly what the automated installers write, and why.)

**Step 3 — verify:**

```bash
which claude-sandbox   # after installing a launcher below, this should print its path
```

Throughout this README, install commands write to `~/.local/bin`. If you prefer `~/bin` or another PATH directory, substitute it consistently.

---

## Claude Code

### How updates work

Claude Code has a built-in auto-updater. The image's npm install is only a first-run bootstrap: the updater installs new versions into `~/.local/share/claude`, which is backed by the `claude-local-$USER` volume, and `PATH` prefers the updater-managed binary. You essentially never rebuild the image except to change system packages.

### Image

Create the directory and Dockerfile — `mkdir -p ~/claude-sandbox`, then save this as `~/claude-sandbox/Dockerfile`:

```dockerfile
# Sandbox image for running Claude Code with --dangerously-skip-permissions.
# Philosophy: sandbox skeleton plus everyday toolchains (C, Python, Rust).
# Anything else a project needs gets installed into that project's own
# directory (./.jdk, ./.bin, etc.) — resist adding it here.
#
# Rebuild (rare):
#   docker build --build-arg UID=$(id -u) --build-arg GID=$(id -g) \
#     -t claude-sandbox-$USER ~/claude-sandbox
#
# Claude Code version is NOT managed here: the npm install is only a
# first-run bootstrap; the auto-updater keeps the real binary current
# in the per-user claude-local volume (mounted at /home/agent/.local).

FROM node:24-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates \
    build-essential pkg-config \
    python3 python3-pip python3-venv \
    jq ripgrep procps \
    && rm -rf /var/lib/apt/lists/*

# Docker CLI, for the optional socket mount below (--sandbox-docker in the
# installed launcher). Inert without the socket. Copied from the official
# image: no apt repository or key handling, and the multi-arch image gives the
# right binary on arm64 too. The CLI is static despite being built on Alpine.
COPY --from=docker:29-cli /usr/local/bin/docker /usr/local/bin/docker
COPY --from=docker:29-cli /usr/local/libexec/docker/cli-plugins/ /usr/local/libexec/docker/cli-plugins/

# Rust toolchain (read-only at runtime; update = rebuild image)
ENV RUSTUP_HOME=/usr/local/rustup CARGO_HOME=/usr/local/cargo
# Downloaded to a file rather than piped into sh: a failed `curl | sh` exits 0
# because sh simply reads empty input, so a transient network blip silently
# installs nothing and only surfaces two commands later as a confusing
# "chmod: cannot access /usr/local/rustup". With && the download failure is fatal.
RUN curl -fsSL --retry 3 --retry-connrefused https://sh.rustup.rs -o /tmp/rustup-init.sh \
    && sh /tmp/rustup-init.sh -y --no-modify-path --profile minimal \
    && rm -f /tmp/rustup-init.sh \
    && chmod -R a+rX ${RUSTUP_HOME} ${CARGO_HOME}

# Non-root user (required: claude rejects --dangerously-skip-permissions as
# root). UID/GID must match the host user so the bind-mounted project is
# writable — pass them at build time; the image is therefore built per user.
#
# node:24-slim already ships a `node` user at UID/GID 1000, which is the first
# non-root UID on most Linux hosts. Take that identity over instead of failing
# the build with "UID 1000 is not unique".
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

# Cargo runtime writes (registry cache, `cargo install`) go to writable
# (ephemeral) home; the toolchain itself stays read-only in the image.
ENV CARGO_HOME=/home/agent/.cargo

RUN npm config set prefix /home/agent/.npm-global \
    && npm install -g @anthropic-ai/claude-code

# Pre-create dirs that back named volumes so they're agent-owned on first mount
RUN mkdir -p /home/agent/.claude /home/agent/.local/bin /home/agent/.local/share \
    /home/agent/.cargo

# Order matters: updater-managed claude (~/.local/bin) shadows the npm bootstrap
ENV PATH=/home/agent/.local/bin:/home/agent/.npm-global/bin:/home/agent/.cargo/bin:/usr/local/cargo/bin:$PATH
ENV CLAUDE_CONFIG_DIR=/home/agent/.claude
```

### Launcher

Save this as `~/.local/bin/claude-sandbox` (see "Before you start" for the PATH setup), then make it executable with `chmod 755 ~/.local/bin/claude-sandbox`:

```bash
#!/bin/bash
# claude-sandbox — run Claude Code sandboxed in the current directory.
# Shared rootful Docker: volumes are namespaced per host user to avoid
# collisions in the daemon's global volume namespace.
#
# The project is mounted at the path it already has on the host, not at a fixed
# /workspace. Claude Code keys its session transcripts and memory on the working
# directory (~/.claude/projects/<cwd-slugified>/), as does .claude.json for
# per-project approvals, so a fixed mount would make every repository on the
# machine one project: a single shared memory store and a --resume list mixing
# all of them together. Codex records the same cwd in every session rollout.

CONFIG_VOL="claude-config-$USER"
LOCAL_VOL="claude-local-$USER"
docker volume create "$CONFIG_VOL" >/dev/null
docker volume create "$LOCAL_VOL" >/dev/null

exec docker run -it --rm \
  --name "claude-$USER-$(basename "$PWD")-$(date +%s)" \
  -v "$PWD:$PWD" -w "$PWD" \
  -v "$CONFIG_VOL:/home/agent/.claude" \
  -v "$LOCAL_VOL:/home/agent/.local" \
  -e "GIT_CONFIG_COUNT=2" \
  -e "GIT_CONFIG_KEY_0=user.name"  -e "GIT_CONFIG_VALUE_0=$(git config --get user.name)" \
  -e "GIT_CONFIG_KEY_1=user.email" -e "GIT_CONFIG_VALUE_1=$(git config --get user.email)" \
  --cap-drop=ALL \
  --security-opt=no-new-privileges \
  claude-sandbox-$USER claude "$@"
```

Notes:

- `docker volume create` is idempotent — it does real work exactly once per user, then no-ops. Named volumes are **not** deleted by `--rm`; they persist until `docker volume rm`.
- The container name includes user, project, and timestamp so concurrent sessions (and concurrent users) don't collide.
- **The `GIT_CONFIG_*` block is what lets the agent commit.** With no git identity in the container, `git commit` fails with "Author identity unknown". `GIT_CONFIG_COUNT`/`KEY`/`VALUE` sets real config, so `git config --get user.email` reads back correctly for hooks and tooling — `GIT_AUTHOR_*` would set the commit but leave the config empty. Drop the block (or set `COUNT=0`) if you have no identity configured on the host; the installed launcher probes first and omits it.
- **To let the agent push**, additionally pass a credential for the remote's host. Resolve it on the host, so you never mount a secret:

  ```bash
  host=github.com
  eval "$(printf 'protocol=https\nhost=%s\n\n' "$host" \
      | GIT_TERMINAL_PROMPT=0 git credential fill \
      | sed -n 's/^username=/u=/p; s/^password=/p=/p')"
  # ...then add to the docker run above (bumping GIT_CONFIG_COUNT to 3):
  #   -e "SANDBOX_GIT_USER=$u" -e "SANDBOX_GIT_TOKEN=$p" \
  #   -e "GIT_CONFIG_KEY_2=credential.https://$host.helper" \
  #   -e 'GIT_CONFIG_VALUE_2=!f(){ test "$1" = get && printf "username=%s\npassword=%s\n" "$SANDBOX_GIT_USER" "$SANDBOX_GIT_TOKEN"; }; f'
  ```

  `GIT_TERMINAL_PROMPT=0` matters — without it a missing credential makes git prompt on the terminal instead of declining. The helper key is scoped to one host, so the credential is never offered to another; within that host, the token's own permissions apply. The installed launcher does all of this behind `--sandbox-git`.
- **To let the agent use Docker**, mount the host's socket and join its group. Two arguments, and they are the ones to think hardest about before adding:

  ```bash
  sock=$(docker context inspect --format '{{.Endpoints.docker.Host}}')
  sock=${sock#unix://}                    # tcp:// and ssh:// cannot be mounted
  # The group as the daemon presents the socket *once mounted* — not the host's
  # view of the same file, which Docker Desktop makes wrong.
  gid=$(docker run --rm -v "$sock:/var/run/docker.sock" claude-sandbox-$USER \
          stat -c %g /var/run/docker.sock)
  # ...then add to the docker run above:
  #   -v "$sock:/var/run/docker.sock" --group-add "$gid" \
  ```

  A supplementary group is applied before capabilities are dropped, so this works alongside `--cap-drop=ALL` and `--security-opt=no-new-privileges` — which is also the point: those flags protect the sandbox, not the sibling containers the agent starts through the socket. Anything it launches can mount any host path. The containers are siblings on your daemon, so their `-v` sources are host paths; that works because the project is mounted at its own host path, and a path that exists only inside the container will silently mount as an empty directory. The installed launcher does all of this behind `--sandbox-docker`, and warns every time.
- **To share data the agent may read but not modify**, add a read-only bind mount at the same host path, one per directory or file:

  ```bash
  # ...add to the docker run above:
  #   -v /data/genome:/data/genome:ro \
  ```

  Mirroring the host path keeps absolute symlinks inside the data working and makes the paths the agent prints resolve on the host. Read-only is not confidentiality — the agent can still read and, with open egress, exfiltrate whatever you mount — so never mount your home directory this way. The installed launcher does this behind `--sandbox-ro`, and refuses the home directory, the project's ancestors, system paths and paths that do not exist.
- No resource limits are set. If runaway sessions on a shared box ever become a problem, add `--memory`, `--cpus`, and `--pids-limit` here.

### Setup (per user)

```bash
# 1. Build the image — per user, so the container UID matches yours and the
#    bind-mounted project is writable
docker build --build-arg UID=$(id -u) --build-arg GID=$(id -g) \
  -t claude-sandbox-$USER ~/claude-sandbox

# 2. Verify the launcher is in place and executable (created above)
which claude-sandbox   # should print ~/.local/bin/claude-sandbox

# 3. First run: authenticate
cd ~/some-project
claude-sandbox
# Headless login: open the printed URL in a browser on another machine,
# sign in, paste the code back at the prompt. One-time — the token
# persists in the claude-config-$USER volume.

# 4. Accept the bypass-permissions dialog once, interactively
claude-sandbox --dangerously-skip-permissions
# (The acceptance persists in the config volume; after this, detached
# and scripted starts work cleanly.)
```

### Daily use

```bash
cd ~/some-project
claude-sandbox --dangerously-skip-permissions
```

In tmux (recommended for long-running sessions — survives SSH disconnects):

```bash
tmux new-session -s "claude-$(basename "$PWD")" -c "$PWD" \
  'claude-sandbox --dangerously-skip-permissions; ec=$?; \
   if [ $ec -ne 0 ]; then echo "exited with status $ec — press Enter to close"; read; fi'
```

This drops you straight into the running session inside tmux. Detach (leave it running in the background) with `Ctrl-b d`; reattach later — including from a phone SSH client — with `tmux attach -t claude-<project>` (`tmux ls` lists sessions). When you quit the agent normally (`/exit` or `Ctrl-d`), the tmux session ends with it; the pane only lingers (waiting for Enter) if the agent exited with an error, so crash output isn't lost. To start a session in the background *without* attaching (e.g., from a script), add `-d` after `new-session` and attach whenever you like.

**Remote Control:** Claude Code's Remote Control (steer sessions from the Claude app / claude.ai) currently cannot be combined with `--dangerously-skip-permissions` — the flags are mutually exclusive and the mobile UI re-prompts for approvals regardless (see [anthropics/claude-code#31908](https://github.com/anthropics/claude-code/issues/31908)). Pick per session: autonomous (flag, monitor via tmux) or remote-steerable (type `/remote-control` in a session, approve from the app).

### What persists where

| Path in container | Backing | Lifetime |
| --- | --- | --- |
| your project's own path | bind mount of `$PWD` | your repo — permanent |
| `~/.claude` | `claude-config-$USER` volume | auth, settings, plugins, session history — permanent |
| `~/.local` | `claude-local-$USER` volume | auto-updated Claude binary — permanent |
| everything else (`~/.cargo`, `~/.npm-global`, …) | container layer | discarded at session exit |

Plugins installed via `/plugin install` live in the config volume, so they persist and are shared across all of that user's projects.

---

## Codex CLI

Same architecture, three differences:

1. **No auto-updater.** Codex must be updated via npm reinstall, so the version is baked at image build time and the launcher rebuilds the image when a new version ships (a cached no-op otherwise).
2. **Autonomy is config, not a flag.** Codex has two dials — approval policy and its own OS-level sandbox. Inside Docker, the container is the boundary and Codex's sandbox generally can't function anyway, so the standard container config is `approval_policy = "never"` + `sandbox_mode = "danger-full-access"`, persisted in `config.toml`. (Per-session equivalent: `codex --dangerously-bypass-approvals-and-sandbox`, alias `--yolo`.)
3. **Auth is device-code based.** `codex login --device-auth` prints a code you approve at chatgpt.com from any device — no localhost callback. Tokens land in `~/.codex` (volume-backed).

### Image

Create the directory and Dockerfile — `mkdir -p ~/codex-sandbox`, then save this as `~/codex-sandbox/Dockerfile`:

```dockerfile
# Codex CLI sandbox. Same philosophy as claude-sandbox.
# NOTE: Codex has no auto-updater — version is baked at build time.
# The launcher rebuilds when a new version ships.

FROM node:24-slim

ARG CODEX_VERSION=latest

RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates \
    build-essential pkg-config \
    python3 python3-pip python3-venv \
    jq ripgrep procps \
    && rm -rf /var/lib/apt/lists/*

# Docker CLI for the optional socket mount; see the Claude image above.
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
```

### Autonomy config

Save this as `~/codex-sandbox/config.toml` (seeded into the volume during setup):

```toml
approval_policy = "never"
sandbox_mode = "danger-full-access"
```

### Launcher

Save this as `~/.local/bin/codex-sandbox`, then `chmod 755 ~/.local/bin/codex-sandbox`:

```bash
#!/bin/bash
# codex-sandbox — run Codex CLI sandboxed in the current directory.
# The project is mounted at its host path for the same reason as in
# claude-sandbox above: Codex writes the cwd into every session rollout, so a
# fixed /workspace makes `codex resume` unable to tell projects apart.
# Codex has no self-updater: check the npm registry for a newer version and
# rebuild the image only when the version actually changed (tracked via an
# image label). Prints progress when rebuilding; silent when up to date.
# Uses jq if present, with a grep fallback so no host dependency is required.

# Where the Dockerfile directory created above lives — must be an absolute
# path, since this script runs from arbitrary project directories.
SANDBOX_SRC="${CODEX_SANDBOX_SRC:-$HOME/codex-sandbox}"

CONFIG_VOL="codex-config-$USER"
docker volume create "$CONFIG_VOL" >/dev/null

LATEST=$(curl -fsSL https://registry.npmjs.org/@openai/codex/latest 2>/dev/null \
  | { jq -r .version 2>/dev/null || grep -o '"version":"[^"]*"' | head -1 | cut -d'"' -f4; })

if [ -n "$LATEST" ] && [ "$LATEST" != "null" ]; then
  CURRENT=$(docker image inspect -f '{{index .Config.Labels "codex_version"}}' \
    "codex-sandbox-$USER" 2>/dev/null)
  if [ "$LATEST" != "$CURRENT" ]; then
    if [ -f "$SANDBOX_SRC/Dockerfile" ]; then
      echo "codex-sandbox: new Codex version $LATEST available (have: ${CURRENT:-none}); rebuilding image — this can take a minute..." >&2
      docker build -q --build-arg CODEX_VERSION="$LATEST" \
        --build-arg UID=$(id -u) --build-arg GID=$(id -g) \
        --label "codex_version=$LATEST" \
        -t "codex-sandbox-$USER" "$SANDBOX_SRC" >/dev/null \
        && echo "codex-sandbox: now on Codex $LATEST" >&2 \
        || echo "codex-sandbox: WARNING: rebuild failed; running existing image" >&2
    else
      echo "codex-sandbox: WARNING: Codex $LATEST available but Dockerfile not found at $SANDBOX_SRC (set CODEX_SANDBOX_SRC); running existing image" >&2
    fi
  fi
else
  echo "codex-sandbox: WARNING: npm version check failed; running existing image without update check" >&2
fi

exec docker run -it --rm \
  --name "codex-$USER-$(basename "$PWD")-$(date +%s)" \
  -v "$PWD:$PWD" -w "$PWD" \
  -v "$CONFIG_VOL:/home/agent/.codex" \
  -e "GIT_CONFIG_COUNT=2" \
  -e "GIT_CONFIG_KEY_0=user.name"  -e "GIT_CONFIG_VALUE_0=$(git config --get user.name)" \
  -e "GIT_CONFIG_KEY_1=user.email" -e "GIT_CONFIG_VALUE_1=$(git config --get user.email)" \
  --cap-drop=ALL \
  --security-opt=no-new-privileges \
  codex-sandbox-$USER codex "$@"
```

> The `GIT_CONFIG_*` block is the same one explained under the Claude launcher
> above, and for the same reason: without it `git commit` fails inside the
> container. The credential recipe there applies here unchanged.

> The default `SANDBOX_SRC` matches the `~/codex-sandbox` location used above;
> if you put the Dockerfile elsewhere, edit that line or export
> `CODEX_SANDBOX_SRC`. If launch-time version checks annoy you, move the
> check-and-rebuild block into a nightly cron and let the launcher just
> `docker run`. Note the version comparison relies on the `codex_version`
> image label: an image built without it (e.g., by the plain initial build
> below, or from an older version of these instructions) triggers one extra
> rebuild — mostly cache hits, quick — after which the label exists and
> up-to-date launches skip the build entirely.

### Setup (per user)

```bash
# 1. Initial build — per user, matching your UID (deliberate first build,
#    so the first login doesn't hide a slow image compile)
docker build --build-arg UID=$(id -u) --build-arg GID=$(id -g) \
  -t codex-sandbox-$USER ~/codex-sandbox

# 2. Verify the launcher is in place and executable (created above)
which codex-sandbox   # should print ~/.local/bin/codex-sandbox

# 3. Authenticate (one-time; device code, approve at chatgpt.com)
cd ~/some-project
codex-sandbox login --device-auth

# 4. Seed the autonomy config into the volume
#    (the chown matters: this helper runs as root, and without it the file —
#    or on a fresh volume, the whole directory — ends up root-owned and Codex
#    can't write its state DB)
docker run --rm -v "codex-config-$USER:/cfg" \
  -v "$HOME/codex-sandbox/config.toml:/src/config.toml:ro" \
  node:24-slim sh -c "cp /src/config.toml /cfg/ && chown -R $(id -u):$(id -g) /cfg"
```

### Daily use

```bash
cd ~/some-project
codex-sandbox            # full autonomy via config.toml; no flag needed
```

In tmux (note the command differs from the Claude version — no flag, since
autonomy comes from `config.toml`):

```bash
tmux new-session -s "codex-$(basename "$PWD")" -c "$PWD" \
  'codex-sandbox; ec=$?; \
   if [ $ec -ne 0 ]; then echo "exited with status $ec — press Enter to close"; read; fi'
```

Same mechanics as the Claude tmux section: you're attached immediately, `Ctrl-b d` detaches leaving it running, `tmux attach -t codex-<project>` reattaches, quitting Codex normally (`/exit`) ends the tmux session, and the pane waits for Enter only after an error exit. Add `-d` to start in the background without attaching.

There is no Remote Control equivalent for Codex — remote steering is SSH + tmux.

---

## Per-project toolchains

The images deliberately omit occasional-use toolchains (Java, Go, etc.). Projects self-provision into their own directories — no root needed, persists with the repo via the bind mount. Document the conventions in `CLAUDE.md` (Claude) / `AGENTS.md` (Codex) so autonomous sessions follow them instead of attempting `apt-get`:

```markdown
## Toolchain conventions
- Python: use a venv (`python3 -m venv .venv`); bare pip installs hit PEP 668.
- Java: no system JVM. Install Temurin into ./.jdk:
    curl -fsSL "https://api.adoptium.net/v3/binary/latest/21/ga/linux/x64/jdk/hotspot/normal/eclipse" | tar -xz -C .jdk --strip-components=1
  then export JAVA_HOME="$PWD/.jdk", PATH="$JAVA_HOME/bin:$PATH". Reuse existing ./.jdk.
- Other tools: static binaries go in ./.bin.
- Gitignore all of: .venv/ .jdk/ .bin/
- No root/sudo available; never attempt apt-get install.
```

## Multiple sessions and multiple users

- **Concurrent sessions (one user):** fully supported. Containers are independent; the shared volumes tolerate concurrency (this is the same as running the agent in several terminal tabs). The only real hazard is two sessions editing the *same checkout* — use `git worktree` for parallel work on one repo.
- **Multiple users (shared rootful Docker):** the `$USER`-namespaced volumes prevent *accidental* cross-user interference. They do **not** prevent deliberate access: anyone in the `docker` group can mount anyone's volume, because docker-group membership on a rootful daemon is root-equivalent. Treat this configuration as *collision-proof, not confidential*. If users on the box aren't mutually trusted with each other's agent credentials, use [rootless Docker](https://docs.docker.com/engine/security/rootless/) per user instead — every user gets an isolated daemon and truly private volumes, and these instructions work identically (drop the `$USER` suffixes if you like).
- **Why images are per-user too:** the container's `agent` user must have *your* UID, or the bind-mounted project (owned by you on the host) isn't writable from inside — the agent will report something like "couldn't save, /home/you/dev/thing is owned by UID 1003 but this session runs as UID 1001." That's why every build command passes `--build-arg UID=$(id -u) --build-arg GID=$(id -g)` and tags the image `*-$USER`. Docker layer caching keeps this cheap: users with identical Dockerfiles share all layers up to the `useradd`.
- **Troubleshooting UID mismatches on existing volumes:** if you built an image before setting the UID args (or your UID changed), your volumes may contain files owned by the old UID and the agent can't write its own config. Symptoms include the `... is owned by UID X but this session runs as UID Y` message, and for Codex specifically a startup failure like `unable to open database file` for `~/.codex/state_5.sqlite` plus `could not create PATH aliases: Permission denied` — that means the *image's* agent UID and the *volume's* file ownership disagree. Verify with `docker run --rm codex-sandbox-$USER id -u` (should print your `id -u`). Fix by rebuilding the image with the UID build-args, then chowning the volumes in place without losing auth:
  ```bash
  docker run --rm -v "claude-config-$USER:/v" alpine chown -R "$(id -u):$(id -g)" /v
  docker run --rm -v "claude-local-$USER:/v"  alpine chown -R "$(id -u):$(id -g)" /v
  docker run --rm -v "codex-config-$USER:/v"  alpine chown -R "$(id -u):$(id -g)" /v
  ```
  If Codex still reports a damaged database after the ownership fix, delete its state DB (auth is in `auth.json`, unaffected): `docker run --rm -v "codex-config-$USER:/v" alpine sh -c 'rm -f /v/state_5.sqlite*'`

## Security notes

- **The container is the entire boundary.** In bypass/yolo mode, a prompt-injected or misbehaving session can do anything *inside* it: modify the mounted project, read the agent credentials in its volume, and reach the open network. Only run against repositories you trust.
- **Never mount host secrets** (`~/.ssh`, cloud credential files, `~/.gitconfig` with tokens) into the container. Pass git identity and, when the agent genuinely needs to push, a git credential as *environment* instead — resolved on the host, for one session. The Launcher sections above show both.
- **A forwarded git credential is a real grant.** Scope it to the remote's host (the `credential.https://<host>.helper` form above), and remember that within that host the token's own permissions apply. An autonomous session that is prompt-injected can use it or exfiltrate it, since egress is open. Prefer a fine-grained, revocable token, and pass none at all when the agent only needs to commit locally.
- **Egress is unrestricted by default** in these launchers. For defense against exfiltration, adapt the default-deny firewall from Anthropic's [reference devcontainer](https://github.com/anthropics/claude-code/tree/main/.devcontainer) (`init-firewall.sh` + `NET_ADMIN`/`NET_RAW` caps) — and be prepared to maintain a domain allowlist for package registries your projects use.
- **No Docker socket, no privileged flags.** The images contain no Docker client; if you ever add one, mounting the host Docker socket into an autonomous agent's container is a sandbox escape (root-equivalent on rootful daemons). Keep it out, or make it a conscious opt-in.
- **Non-root inside the container** (`agent` user) is required by Claude Code's bypass flag and is good hygiene for both agents regardless.

## References

- The installers that automate all of this: [README.md](README.md)
- Claude Code dev container docs: https://code.claude.com/docs/en/devcontainer
- Anthropic reference devcontainer (firewall, hardened example): https://github.com/anthropics/claude-code/tree/main/.devcontainer
- Claude Code permission modes: https://code.claude.com/docs/en/permission-modes
- Codex CLI: https://github.com/openai/codex
- Remote Control + bypass incompatibility: https://github.com/anthropics/claude-code/issues/31908
