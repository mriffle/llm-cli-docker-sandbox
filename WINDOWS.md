# Windows Setup

How to set up the Claude Code and Codex CLI Docker sandboxes on a Windows machine.

The good news up front: because both agents run **inside Linux containers**, Windows only has to play host — you never install Claude Code or Codex natively on Windows at all. What this page covers is the Windows-specific plumbing: getting WSL2 and Docker, choosing where your files live, and which of the two installers to run.

There are two routes. **Route A (WSL2) is strongly recommended**: you get a real Linux environment, the shell installers, and tmux. Route B (native PowerShell) exists if you can't or won't work inside WSL, at the cost of no tmux and slower file access.

Either way, the installer checks your prerequisites before it changes anything. If WSL2 is missing, or on WSL1, or Docker Desktop isn't installed, isn't running, isn't exposed to your distro, or is in Windows-container mode, it stops and tells you exactly which of those it is and what to type next.

---

## Route A: WSL2 (recommended)

WSL2 (Windows Subsystem for Linux) runs a genuine Linux distribution inside Windows. Docker, bash, tmux and the shell installers all work exactly as they do on a Linux server.

### 1. Install WSL2

Open **PowerShell as Administrator** and run:

```powershell
wsl --install
```

This installs WSL2 with Ubuntu by default. Reboot when prompted, then open "Ubuntu" from the Start menu; on first launch it asks you to create a Linux username and password. If you installed WSL long ago, make sure you're on WSL2, not WSL1: `wsl -l -v` should show `VERSION 2` (upgrade with `wsl --set-version <distro> 2`).

### 2. Install Docker

Two options:

- **Docker Desktop for Windows** (easiest): install from docker.com, and in *Settings → Resources → WSL integration*, enable integration for your Ubuntu distro. The `docker` command then works inside your WSL terminal. Note Docker Desktop requires a paid subscription for larger companies (250+ employees or $10M+ revenue) — check your organization's licensing.
- **Docker Engine inside WSL2** (no Docker Desktop, no licensing question): install Docker's Linux packages directly in Ubuntu following the standard [Docker Engine install docs](https://docs.docker.com/engine/install/ubuntu/) for Ubuntu. Recent WSL2 supports systemd (enable via `/etc/wsl.conf` with `[boot]\nsystemd=true` if needed), so the service management works normally. Add yourself to the `docker` group: `sudo usermod -aG docker $USER`, then close and reopen the terminal.

Verify from your Ubuntu terminal:

```bash
docker run --rm hello-world
```

If you skip this step, the installer will detect it and print these same options — including the WSL-integration toggle, which is the single most common cause of "docker: command not found" inside WSL.

### 3. Keep your projects in the Linux filesystem

This is the single most important Windows-specific tip. WSL2 can see your Windows drives at `/mnt/c/...`, and it's tempting to keep projects there — **don't**. Cross-filesystem access is dramatically slower (git operations and builds can be 5–20× slower), and bind-mounting `/mnt/c` paths into containers compounds it, along with occasional file-permission and file-watching oddities.

Instead, keep repos in your WSL home directory:

```bash
cd ~
git clone <your-project>
```

You can still open these files from Windows apps: VS Code's WSL integration does this natively, and Explorer can browse to `\\wsl$\Ubuntu\home\<you>\`.

### 4. Install the sandboxes

From your Ubuntu terminal — you're on Linux now, so these are the ordinary shell installers:

```bash
curl -fsSL https://raw.githubusercontent.com/mriffle/llm-cli-docker-sandbox/main/install/claude.sh | bash
curl -fsSL https://raw.githubusercontent.com/mriffle/llm-cli-docker-sandbox/main/install/codex.sh  | bash
```

Then follow [the main README](README.md) for first-run login and daily use. tmux works (`claude-sandbox --sandbox-tmux`), device-code auth works (open the URL in your Windows browser — same machine, no "another device" needed), and per-user namespacing behaves as on any Linux host. One nuance: WSL is typically single-user, so the `$USER` suffixes are less load-bearing than on a shared server — harmless, and kept for consistency.

### WSL-specific gotchas

- **WSL shutdown.** WSL2 (and any tmux sessions and containers inside it) stops when Windows reboots, and WSL may auto-suspend when no terminal is open. For long-running agent sessions, keep a terminal window open; a laptop that sleeps will pause sessions regardless, same as native Linux.
- **Line endings.** You no longer hand-create the launcher scripts, so the classic `/bin/bash^M: bad interpreter` problem is gone — the installer writes them with LF endings. It's still worth knowing if you edit them later from a Windows editor: fix with `sed -i 's/\r$//' ~/.local/bin/claude-sandbox`, or just re-run the installer.

---

## Route B: Native Windows (PowerShell, no WSL)

Workable, but you give up tmux. Docker Desktop is required, with its WSL2 *backend* — which it manages invisibly, so you still don't use WSL directly in this route. Containers, volumes and auth behave identically; only the launcher changes.

### 1. Install Docker Desktop

```powershell
winget install -e --id Docker.DockerDesktop
```

Or download from docker.com. Launch it once and let it finish starting, keep *Settings → General → Use the WSL 2 based engine* enabled, and stay in Linux-container mode (the default). Verify:

```powershell
docker run --rm hello-world
```

### 2. Install the sandboxes

```powershell
irm https://raw.githubusercontent.com/mriffle/llm-cli-docker-sandbox/main/install/claude.ps1 | iex
irm https://raw.githubusercontent.com/mriffle/llm-cli-docker-sandbox/main/install/codex.ps1  | iex
```

Each installer writes `%USERPROFILE%\<agent>-sandbox\Dockerfile`, a launcher pair (`claude-sandbox.ps1` and a `claude-sandbox.cmd` shim) into `%USERPROFILE%\bin`, adds that directory to your user PATH, builds the image and creates the volumes. Open a new terminal afterwards so the PATH change takes effect.

The `.cmd` shim means `claude-sandbox` works from both PowerShell and `cmd.exe`, and never trips PowerShell's execution policy — you don't need `Set-ExecutionPolicy` for this to work.

To pass options, note that a piped script can't take arguments; create a script block instead:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/mriffle/llm-cli-docker-sandbox/main/install/claude.ps1))) -Check
```

### 3. Authenticate and use

```powershell
cd C:\code\some-project
claude-sandbox                                     # log in once
claude-sandbox --dangerously-skip-permissions      # accept the bypass dialog once

codex-sandbox login --device-auth                  # device code, approve at chatgpt.com
```

Daily use: `claude-sandbox --dangerously-skip-permissions` / `codex-sandbox` from a project directory. `claude-sandbox --sandbox-doctor` reports on the image, volumes and versions; `claude-sandbox --sandbox-upgrade` re-runs the installer.

### Native-route caveats

- **Bind-mount performance.** Mounting Windows directories (`C:\...`) into Linux containers goes through a filesystem translation layer and is noticeably slower than Linux-native mounts — the same tax as `/mnt/c` in WSL, because under the hood it *is* the same mechanism. Heavy npm/cargo workloads feel it. This is the main reason Route A is recommended.
- **File ownership.** Docker Desktop papers over Linux UID/GID for Windows-mounted paths, so the UID-matching that the Linux installers do doesn't apply here — the PowerShell installers deliberately don't pass `--build-arg UID/GID`, and files the agent creates appear owned by you on the Windows side. Named volumes are still real Linux filesystems, so Codex's `config.toml` seeding still normalises ownership to the image's agent user. (In Route A, the UID matching matters and the shell installer handles it.)
- **Your project's path inside the container.** The launcher mounts the project at the path it has on the host, so that each project keeps its own agent memory, session history and approvals rather than all of them sharing one identity. A Windows path is not a Linux path, so it is translated the way WSL translates it: `C:\Users\you\dev\thing` becomes `/mnt/c/Users/you/dev/thing`, and `\\server\share\thing` becomes `/mnt/unc/server/share/thing`. That deliberately matches Route A, so a folder on a Windows drive opened from PowerShell and from WSL is one project and not two. `SANDBOX_WORKDIR=/workspace` restores the old fixed mount if you need it. Paths given to `--sandbox-ro` are translated the same way: `D:\data` is mounted read-only at `/mnt/d/data`.
- **No tmux.** There's no `--sandbox-tmux` on this route and no clean native detach/reattach equivalent. For detached long-running sessions, use Windows Terminal tabs left open, or run the sandbox under WSL after all.
- **No `--sandbox-docker`.** The launcher refuses it here rather than half-honouring it. Docker Desktop's daemon runs in its own Linux VM, which cannot resolve the `/mnt/c/...` paths this container uses, so a bind mount made by a container the agent started would silently be an *empty directory* instead of your project — a wrong answer rather than an error. Under Route A the daemon and the container agree on paths and the flag works normally, so this is one more reason to prefer WSL2. Setting `SANDBOX_DOCKER=1` in the environment is ignored here, and the launcher says so.
- **`--cap-drop`/`no-new-privileges`** work as on Linux — they apply to the Linux container, which lives in Docker Desktop's VM regardless of host OS.

---

## Which route, in one sentence

If you can use WSL2, use Route A — it's faster (native filesystem), keeps tmux, and is the same setup that runs on a Linux server; use Route B only when WSL is unavailable to you (e.g. organizational restrictions on enabling it).
