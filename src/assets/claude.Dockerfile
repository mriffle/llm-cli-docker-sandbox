# Sandbox image for running Claude Code with --dangerously-skip-permissions.
# Philosophy: sandbox skeleton plus everyday toolchains (C, Python, Rust).
# Anything else a project needs gets installed into that project's own
# directory (./.jdk, ./.bin, etc.) — resist adding it here.
#
# Managed by the agent-sandbox installer (v@@VERSION@@). Re-running the
# installer rewrites this file; local edits are backed up first, but the
# supported way to customise is to keep your own copy elsewhere and build
# with --src-dir.
#
# Claude Code version is NOT managed here: the binary built into the image
# only seeds the per-user claude-local volume (mounted at /home/agent/.local);
# the auto-updater keeps it current there, where updates survive the session.

FROM node:24-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates \
    build-essential pkg-config \
    python3 python3-pip python3-venv \
    jq ripgrep procps \
    && rm -rf /var/lib/apt/lists/*

# Docker CLI, for --sandbox-docker (Docker-out-of-Docker). Inert on its own:
# without the socket, which only that flag mounts, every command fails with
# "cannot connect to the Docker daemon". Copied from the official image rather
# than installed from Docker's apt repository — no key or source-list handling,
# and the multi-arch image gives the right binary on arm64 as well as amd64.
# The CLI is a static Go binary despite being built on Alpine, so it runs here.
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

# Writable (ephemeral) prefix, so the agent can `npm install -g` a tool.
RUN npm config set prefix /home/agent/.npm-global

# Claude Code, installed natively into ~/.local — not with npm. An npm install
# records itself as "global", and its updater then rewrites the npm copy in
# place, in the image layer, so every update was lost when the session ended.
# The native install lives in ~/.local, which is the claude-local volume.
# Downloaded to a file for the same reason as rustup above.
#
# The binary is also hard-linked into ~/.claude-seed, outside both volumes
# (same RUN, so the link costs no space): Docker fills a volume from the image
# only while it is empty, so a claude-local volume from an npm-era image never
# gets this ~/.local, and the entrypoint below installs from the seed instead.
# The config the installer wrote goes, so a new claude-config volume starts empty.
RUN curl -fsSL --retry 3 --retry-connrefused https://claude.ai/install.sh -o /tmp/claude-install.sh \
    && bash /tmp/claude-install.sh latest \
    && rm -f /tmp/claude-install.sh \
    && mkdir -p /home/agent/.claude-seed \
    && ln /home/agent/.local/share/claude/versions/* /home/agent/.claude-seed/claude \
    && rm -rf /home/agent/.claude /home/agent/.claude.json /home/agent/.cache/claude

# Runs before every command, and only ever acts on `claude`. On a claude-local
# volume with no native install yet it runs `claude install` once (a download
# of ten seconds or so), which also switches the updater to the volume. If that
# fails, the seed on PATH runs this session and the next launch tries again.
RUN printf '%s\n' \
    '#!/bin/sh' \
    'if [ "${1:-}" = claude ] && [ ! -x "$HOME/.local/bin/claude" ]; then' \
    '    echo "sandbox: moving Claude Code into the claude-local volume (once)..." >&2' \
    '    if out=$("$HOME/.claude-seed/claude" install 2>&1); then' \
    '        echo "sandbox: done; Claude Code now updates itself there" >&2' \
    '    else' \
    '        printf "%s\n" "$out" >&2' \
    '        echo "sandbox: that failed; using the built-in Claude Code for now" >&2' \
    '    fi' \
    'fi' \
    'exec "$@"' \
    > /home/agent/.claude-seed/entrypoint \
    && chmod 755 /home/agent/.claude-seed/entrypoint

# Pre-create dirs that back named volumes so they're agent-owned on first mount
RUN mkdir -p /home/agent/.claude /home/agent/.local/bin /home/agent/.local/share \
    /home/agent/.cargo

# Order matters: the volume's self-updating claude (~/.local/bin) shadows the seed
ENV PATH=/home/agent/.local/bin:/home/agent/.claude-seed:/home/agent/.npm-global/bin:/home/agent/.cargo/bin:/usr/local/cargo/bin:$PATH
ENV CLAUDE_CONFIG_DIR=/home/agent/.claude
ENTRYPOINT ["/home/agent/.claude-seed/entrypoint"]
CMD ["claude"]
