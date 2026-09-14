# --- shared launcher machinery (generated; see @@REPO_URL@@) ----------------
SANDBOX_VERSION="@@VERSION@@"
RAW_BASE="@@RAW_BASE@@"
REPO_URL="@@REPO_URL@@"

have() { command -v "$1" >/dev/null 2>&1; }
ldie() { printf 'sandbox: %s\n' "$*" >&2; exit 1; }
lwarn() { printf 'sandbox: %s\n' "$*" >&2; }

sandbox_user() {
    if [ -n "${SANDBOX_FAKE_USER:-}" ]; then printf '%s' "$SANDBOX_FAKE_USER"
    elif [ -n "${USER:-}" ]; then printf '%s' "$USER"
    else id -un
    fi
}

version_gt() {
    local a=${1#v} b=${2#v} i a_i b_i
    [ -n "$a" ] || return 1
    [ -n "$b" ] || return 0
    i=1
    while [ "$i" -le 4 ]; do
        a_i=$(printf '%s' "$a" | cut -d. -f"$i"); b_i=$(printf '%s' "$b" | cut -d. -f"$i")
        case "$a_i" in ''|*[!0-9]*) a_i=0 ;; esac
        case "$b_i" in ''|*[!0-9]*) b_i=0 ;; esac
        [ "$a_i" -gt "$b_i" ] && return 0
        [ "$a_i" -lt "$b_i" ] && return 1
        i=$((i + 1))
    done
    return 1
}

cache_dir() { printf '%s' "${XDG_CACHE_HOME:-$HOME/.cache}/agent-sandbox"; }
state_dir() { printf '%s' "${SANDBOX_STATE_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/agent-sandbox}"; }

# Absolute path to this launcher, so tmux can re-invoke it from any cwd.
launcher_self() {
    case "$0" in
        /*) printf '%s' "$0" ;;
        */*) printf '%s' "$(cd "$(dirname "$0")" && pwd)/$(basename "$0")" ;;
        *) command -v "$0" 2>/dev/null || printf '%s' "$0" ;;
    esac
}

# At most one network call per day, 2s ceiling, silent when offline, and the
# timestamp is written *before* the request so a flaky network cannot turn
# every launch into a stalled one.
update_check() {
    [ -z "${SANDBOX_NO_UPDATE_CHECK:-}" ] || return 0
    have curl || return 0
    local cache latest
    cache="$(cache_dir)/$AGENT.lastcheck"
    mkdir -p "$(cache_dir)" 2>/dev/null || return 0
    if [ -f "$cache" ] && [ -n "$(find "$cache" -mmin -1440 2>/dev/null)" ]; then
        return 0
    fi
    : > "$cache" 2>/dev/null || true
    latest=$(curl -fsSL --max-time 2 "$RAW_BASE/VERSION" 2>/dev/null | head -1 | tr -d ' \r\n')
    [ -n "$latest" ] || return 0
    if version_gt "$latest" "$SANDBOX_VERSION"; then
        lwarn "v$latest of the sandbox is available (you have v$SANDBOX_VERSION)"
        lwarn "upgrade with: $LAUNCHER_NAME --sandbox-upgrade   (or SANDBOX_NO_UPDATE_CHECK=1 to silence)"
    fi
}

ensure_docker_and_image() {
    have docker || ldie "docker is not installed or not on PATH — see $REPO_URL"
    if docker image inspect "$IMAGE" >/dev/null 2>&1; then return 0; fi
    if ! docker info >/dev/null 2>&1; then
        ldie "cannot reach the docker daemon (is it running, and are you in the docker group?)"
    fi
    printf 'sandbox: image %s does not exist.\n' "$IMAGE" >&2
    printf 'sandbox: install it with:\n  curl -fsSL %s/install/%s.sh | bash\n' "$RAW_BASE" "$AGENT" >&2
    exit 1
}

# Docker demands [a-zA-Z0-9][a-zA-Z0-9_.-]* — project directories do not.
# Note the printf: piping `basename` into tr would turn its trailing newline
# into another separator and leave every name with a stray dash.
project_slug() {
    local base=${PWD##*/}
    [ -n "$base" ] || base=root
    printf '%s' "$base" | tr -c 'a-zA-Z0-9_.-' '-'
}

container_name() {
    printf '%s-%s-%s-%s' "$AGENT" "$(sandbox_user)" "$(project_slug)" "$(date +%s)"
}

short_hash() {
    if have sha256sum; then printf '%s' "$1" | sha256sum | cut -c1-6
    elif have shasum; then printf '%s' "$1" | shasum -a 256 | cut -c1-6
    else printf '%s' "$1" | cksum | cut -d' ' -f1 | cut -c1-6
    fi
}

# --- where the project lives inside the container --------------------------
# Both agents key their per-project state on the *working directory string*:
# Claude Code stores session transcripts and memory under
# ~/.claude/projects/<cwd-slugified>/, records per-project approvals and trust
# under that path in .claude.json, and Codex writes the cwd into every rollout
# for `codex resume`. Mount every project at a fixed /workspace and all of them
# are one project to the agent — one shared memory store, one mixed resume
# list, approvals leaking between repositories. Mirroring the host path keeps
# each project distinct, and has the side benefit that paths the agent prints
# are paths that resolve on the host.

# Physical, not bash's logical $PWD. Reaching one project through a symlink
# must not look like a second project, or it acquires a second memory store.
host_workdir() {
    if [ -n "${SANDBOX_FAKE_PWD:-}" ]; then printf '%s' "$SANDBOX_FAKE_PWD"; return; fi
    pwd -P 2>/dev/null || printf '%s' "$PWD"
}

# The host path, unless mirroring it would land the mount *on* the container's
# own filesystem instead of in a fresh directory. Mounting under a system
# directory (/opt/proj, /tmp/proj, macOS's /var/folders/x/proj) is fine —
# docker just creates it — so only these exact paths fall back:
#   /, /home and the bare top-level directories, which the image needs, and
#   /home/agent, which is the agent's own home: a host user actually named
#   `agent` would otherwise expose their entire home directory to a session
#   that is supposed to see nothing but the project.
# The fallback warns. A silent one would rebuild the collision invisibly.
# True for a path that must not be mounted over inside the container: not
# absolute, one of the reserved directories above, or the agent's own home.
# Shared by the project mount and by --sandbox-ro.
reserved_container_path() {
    case "$1" in
        /home/agent|/home/agent/*) return 0 ;;
        /|/bin|/boot|/dev|/etc|/home|/lib|/lib32|/lib64|/media|/mnt|/opt) return 0 ;;
        /proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var) return 0 ;;
        /*) return 1 ;;
        *) return 0 ;;
    esac
}

container_workdir() {
    local p
    if [ -n "${SANDBOX_WORKDIR:-}" ]; then printf '%s' "$SANDBOX_WORKDIR"; return; fi
    p=$(host_workdir)
    if reserved_container_path "$p"; then p=''; fi
    if [ -z "$p" ]; then
        lwarn "cannot mirror $(host_workdir) inside the container; using /workspace"
        lwarn "(the agent's memory and session history there are shared with other such projects)"
        p=/workspace
    fi
    printf '%s' "$p"
}

# --- git -------------------------------------------------------------------
# Identity always, a credential only on request. Both travel as environment;
# no new host path is ever mounted.
#
# GIT_CONFIG_COUNT/KEY/VALUE is real git config, so `git config --get
# user.email` reads back correctly inside the container. GIT_AUTHOR_* would set
# the commit but leave the config empty, and hooks read the config.
#
# Every probe here is best-effort. No git on the host, no identity configured,
# a directory that is not a repository — each must leave the launch untouched.
GIT_ENV_ARGS=()
GIT_ENV_COUNT=0

# Single quotes are deliberate: these variables expand in the container's shell,
# from the environment passed alongside — not here, and not at build time.
# shellcheck disable=SC2016  # the $VARs belong to the container, not this shell
GIT_CRED_HELPER='!f(){ test "$1" = get && printf "username=%s\npassword=%s\n" "$SANDBOX_GIT_USER" "$SANDBOX_GIT_TOKEN"; }; f'

git_env_add() {
    GIT_ENV_ARGS+=(-e "GIT_CONFIG_KEY_$GIT_ENV_COUNT=$1" \
                   -e "GIT_CONFIG_VALUE_$GIT_ENV_COUNT=$2")
    GIT_ENV_COUNT=$((GIT_ENV_COUNT + 1))
}

# `git config --get` exits 1 for an unset key. That is the normal case, not a
# failure worth reporting.
git_config_get() { git config --get "$1" 2>/dev/null || printf ''; }

# The origin's host, and only for https — an ssh or scp-style remote never
# consults a credential helper, so there is nothing useful to forward.
git_origin_host() {
    local url
    url=$(git config --get remote.origin.url 2>/dev/null) || return 1
    case "$url" in
        https://*|http://*) ;;
        *) return 1 ;;
    esac
    url=${url#*://}
    url=${url%%/*}
    printf '%s' "${url#*@}"
}

GIT_CRED_USER=''
GIT_CRED_TOKEN=''
git_resolve_cred() {
    local host=$1 line out
    GIT_CRED_USER=''; GIT_CRED_TOKEN=''

    if [ "$host" = github.com ] && [ -n "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ]; then
        GIT_CRED_USER=x-access-token
        GIT_CRED_TOKEN=${GH_TOKEN:-${GITHUB_TOKEN:-}}
        return 0
    fi

    if have gh; then
        out=$(gh auth token --hostname "$host" 2>/dev/null | head -1 | tr -d ' \r\n')
        if [ -n "$out" ]; then
            GIT_CRED_USER=x-access-token
            GIT_CRED_TOKEN=$out
            return 0
        fi
    fi

    # The host's own credential store answers here — keychain, GCM, libsecret or
    # a plain file — so the container never learns which backend is in use.
    # GIT_TERMINAL_PROMPT=0 is load-bearing: without it git prompts on /dev/tty
    # and the launch hangs instead of quietly declining.
    out=$(printf 'protocol=https\nhost=%s\n\n' "$host" \
        | GIT_TERMINAL_PROMPT=0 git credential fill 2>/dev/null)
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            username=*) GIT_CRED_USER=${line#*=} ;;
            password=*) GIT_CRED_TOKEN=${line#*=} ;;
        esac
    done <<EOF
$out
EOF
    [ -n "$GIT_CRED_TOKEN" ]
}

git_env_args() {
    local name email host
    GIT_ENV_ARGS=()
    GIT_ENV_COUNT=0
    [ -z "${SANDBOX_NO_GIT:-}" ] || return 0
    have git || return 0

    name=$(git_config_get user.name)
    email=$(git_config_get user.email)
    [ -z "$name" ]  || git_env_add user.name "$name"
    [ -z "$email" ] || git_env_add user.email "$email"

    if [ -n "${SANDBOX_GIT:-}" ]; then
        host=$(git_origin_host) || host=''
        if [ -z "$host" ]; then
            lwarn "--sandbox-git: no https remote here; nothing to forward"
        elif git_resolve_cred "$host"; then
            GIT_ENV_ARGS+=(-e "SANDBOX_GIT_USER=$GIT_CRED_USER" \
                           -e "SANDBOX_GIT_TOKEN=$GIT_CRED_TOKEN")
            git_env_add "credential.https://$host.helper" "$GIT_CRED_HELPER"
        else
            lwarn "--sandbox-git: no credential stored for $host; pushing will fail"
        fi
    fi

    [ "$GIT_ENV_COUNT" -eq 0 ] || GIT_ENV_ARGS+=(-e "GIT_CONFIG_COUNT=$GIT_ENV_COUNT")
}

# --- docker-out-of-docker --------------------------------------------------
# --sandbox-docker bind-mounts the host's Docker socket, so the agent can build
# images and run containers. What it starts are *siblings* on the host daemon,
# not children: their -v paths are resolved by that daemon, in host terms. That
# works here only because the project is mounted at its own host path — inside
# the container `-v "$PWD:/app"` names the same directory the daemon does. A
# path that is not under the project mount is a path the daemon does not have,
# and it silently gets an empty directory rather than an error.
#
# The flag hands over no privilege the user lacked: reaching the daemon at all
# means being able to run docker without sudo, which on a rootful daemon is
# already root-equivalent. What changes is who wields it — an autonomous,
# prompt-injectable session. Hence opt-in per launch, and a warning every time.
DOCKER_ARGS=()

# The installer version that first shipped a docker CLI inside the image.
DOCKER_CLI_SINCE=1.2.0

# The endpoint the host's own CLI would use: honours DOCKER_HOST and the active
# context, and needs no jq.
docker_endpoint() {
    local ep
    ep=$(docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null \
        | head -1 | tr -d ' \r\n')
    [ -n "$ep" ] || ep=${DOCKER_HOST:-}
    [ -n "$ep" ] || ep='unix:///var/run/docker.sock'
    printf '%s' "$ep"
}

# Only a unix socket can be handed through. tcp://, ssh:// and npipe:// have no
# file to mount, and mounting a path that does not exist would give the
# container an empty directory where it expects a daemon.
docker_socket_path() {
    local ep
    ep=$(docker_endpoint)
    case "$ep" in
        unix://*) printf '%s' "${ep#unix://}" ;;
        *) return 1 ;;
    esac
}

# The group the socket carries *once mounted* — the only number that matters,
# and not the one the host sees: Docker Desktop re-owns the socket inside its
# VM, so a host-side stat there answers about a different file. Ask the daemon.
#
# Deliberately no host-side fallback. It would be consulted exactly when the
# probe failed, and it is wrong precisely on the platforms where that is most
# likely — a confidently wrong GID buys a "permission denied" with nothing to
# point at. Empty means "unknown", and the caller says so out loud.
docker_socket_gid() {
    local sock=$1 gid
    # One line on purpose: `stat -c` is GNU-only, and both the portability
    # guard's exemption and the reader need to see that it runs in a container
    # (always Linux) rather than on a possibly-BSD host.
    gid=$(docker run --rm -v "$sock:/var/run/docker.sock" "$IMAGE" stat -c %g /var/run/docker.sock 2>/dev/null | head -1 | tr -d ' \r\n')
    case "$gid" in ''|*[!0-9]*) gid='' ;; esac
    printf '%s' "$gid"
}

docker_sock_args() {
    local sock gid built
    DOCKER_ARGS=()
    [ -n "${SANDBOX_DOCKER:-}" ] || return 0

    if ! sock=$(docker_socket_path); then
        ldie "--sandbox-docker: $(docker_endpoint) is not a unix socket, so there is nothing to mount"
    fi
    # Refuse rather than mount a path that is not there: docker would helpfully
    # create it on the host as a *directory* and mount that, so the agent would
    # find a directory where it expects a socket, and the host would be left
    # with a stray one.
    if [ ! -e "$sock" ]; then
        ldie "--sandbox-docker: the daemon's endpoint names $sock, which does not exist"
    fi

    # An image built before the CLI was bundled would take the socket and have
    # nothing to use it with. The installer's version label is local and free
    # to read, so this costs nothing and replaces a baffling "docker: command
    # not found" inside an autonomous session with a sentence at launch.
    built=$(docker image inspect -f '{{index .Config.Labels "sandbox.installer_version"}}' "$IMAGE" 2>/dev/null | tr -d ' \r\n')
    if [ -n "$built" ] && version_gt "$DOCKER_CLI_SINCE" "$built"; then
        lwarn "--sandbox-docker: this image was built by installer v$built, which"
        lwarn "  predates the bundled docker CLI — re-run the installer, or the"
        lwarn "  agent will find no docker command inside"
    fi

    lwarn "--sandbox-docker: this session can reach the host Docker daemon."
    lwarn "  The agent can start containers that mount any host path — your home"
    lwarn "  directory included — so the container is no longer a boundary."

    DOCKER_ARGS=(-v "$sock:/var/run/docker.sock")
    # A numeric GID needs no matching entry in the image's /etc/group, and
    # supplementary groups are applied before capabilities drop, so this works
    # alongside --cap-drop=ALL and --security-opt=no-new-privileges.
    gid=$(docker_socket_gid "$sock")
    if [ -n "$gid" ]; then
        DOCKER_ARGS+=(--group-add "$gid")
    else
        lwarn "--sandbox-docker: could not determine the socket's group; if docker"
        lwarn "  commands inside fail with 'permission denied', that is why"
    fi
}

# --- read-only host mounts -------------------------------------------------
# --sandbox-ro PATH bind-mounts a host directory or file into the session
# read-only, at the same path it has on the host — for the same reasons the
# project is mirrored: absolute symlinks inside the data resolve, paths the
# agent prints resolve on the host, and a sibling container started through
# --sandbox-docker can name the same path. Write access stays exactly the
# project.
#
# Read-only is not confidentiality. Egress is open, so anything mounted can be
# read and shipped by a prompt-injected session. That is why the home
# directory and its ancestors are refused outright rather than warned about:
# they hold ~/.ssh and friends by construction. Mount data, not homes.
RO_PATHS=()   # as given on the command line, in order
RO_FLAGS=()   # --sandbox-ro=PATH, resolved, re-emitted into a tmux session
RO_ARGS=()    # -v src:src:ro pairs; both built by ro_mount_args

# The physical path, like host_workdir, so one directory reached two ways is
# one mount. Files are allowed: a single CSV is a fair thing to share. Fails
# for a path that is not there or cannot be entered.
resolve_ro_path() {
    local p=$1 dir
    if [ -d "$p" ]; then
        (unset CDPATH; cd -- "$p" 2>/dev/null && pwd -P)
    elif [ -e "$p" ]; then
        dir=$(unset CDPATH; cd -- "$(dirname "$p")" 2>/dev/null && pwd -P) || return 1
        printf '%s/%s' "$dir" "$(basename "$p")"
    else
        return 1
    fi
}

# The reason a resolved path cannot be mounted, or nothing when it can. Shared
# by the launch (which refuses) and by doctor (which reports).
ro_check_path() {
    local src=$1 home proj
    home=${HOME:-}
    proj=$(host_workdir)
    if reserved_container_path "$src"; then
        printf '%s is a system path inside the container' "$src"; return
    fi
    if [ -n "$home" ]; then
        case "$home" in
            "$src"|"$src"/*) printf '%s contains your home directory, and read-only is not confidentiality' "$src"; return ;;
        esac
    fi
    # host_workdir, not container_workdir: SANDBOX_WORKDIR moves the project's
    # mount point, not the directory that is mounted writable.
    case "$proj" in
        "$src") printf '%s is the project, which is already mounted writable' "$src"; return ;;
        "$src"/*) printf '%s contains the project, which is mounted writable' "$src"; return ;;
    esac
}

ro_mount_args() {
    local given src reason seen nl
    RO_ARGS=()
    RO_FLAGS=()
    seen=''
    nl='
'
    for given in ${RO_PATHS[@]+"${RO_PATHS[@]}"}; do
        if ! src=$(resolve_ro_path "$given"); then
            # Refuse rather than let docker create the path on the host as a
            # root-owned directory and mount that.
            ldie "--sandbox-ro: $given does not exist (or cannot be entered)"
        fi
        reason=$(ro_check_path "$src")
        [ -z "$reason" ] || ldie "--sandbox-ro: $reason"
        case "$seen" in *"$nl$src$nl"*) continue ;; esac
        seen="$seen$nl$src$nl"
        lwarn "read-only: $src"
        RO_ARGS+=(-v "$src:$src:ro")
        RO_FLAGS+=("--sandbox-ro=$src")
    done
}

run_container() {
    local src dst
    src=$(host_workdir)
    dst=$(container_workdir)
    git_env_args
    docker_sock_args
    # The ${a[@]+"${a[@]}"} form, not a bare "${a[@]}": expanding an *empty*
    # array under `set -u` is fatal on bash 3.2, which is still macOS /bin/bash.
    exec docker run -it --rm \
        --name "$(container_name)" \
        -v "$src:$dst" \
        -w "$dst" \
        "${MOUNT_ARGS[@]}" \
        ${RO_ARGS[@]+"${RO_ARGS[@]}"} \
        ${GIT_ENV_ARGS[@]+"${GIT_ENV_ARGS[@]}"} \
        ${DOCKER_ARGS[@]+"${DOCKER_ARGS[@]}"} \
        --cap-drop=ALL \
        --security-opt=no-new-privileges \
        "$IMAGE" "$AGENT_BIN" "$@"
}

# Overridden by codex-sandbox, which has no self-updater to lean on.
# shellcheck disable=SC2317
pre_run_hook() { :; }

# --- tmux ------------------------------------------------------------------
# A session per project directory. Two directories with the same basename get
# distinct sessions (the second is suffixed with a hash of its path) rather
# than one silently hijacking the other's session.
tmux_session_for_pwd() {
    local base session stored
    base="$AGENT-$(project_slug)"
    if ! tmux has-session -t "=$base" 2>/dev/null; then
        printf '%s' "$base"; return 0
    fi
    stored=$(tmux show-environment -t "=$base" SANDBOX_PWD 2>/dev/null | cut -d= -f2-)
    if [ "$stored" = "$PWD" ]; then printf '%s' "$base"; return 0; fi
    session="$base-$(short_hash "$PWD")"
    printf '%s' "$session"
}

tmux_launch() {
    local mode=$1; shift
    have tmux || ldie "tmux is not installed (try: sudo apt-get install tmux, or brew install tmux)"

    if [ -n "${TMUX:-}" ]; then
        lwarn "already inside tmux — running directly instead of nesting a session"
        ensure_docker_and_image
        update_check
        pre_run_hook
        run_container "$@"
        return $?
    fi

    local session self cmd
    session=$(tmux_session_for_pwd)

    if tmux has-session -t "=$session" 2>/dev/null; then
        if [ "$mode" = "detach" ]; then
            printf 'sandbox: session %s is already running; attach with: tmux attach -t %s\n' "$session" "$session" >&2
            return 0
        fi
        printf 'sandbox: attaching to the existing session %s\n' "$session" >&2
        exec tmux attach-session -t "=$session"
    fi

    ensure_docker_and_image
    self=$(launcher_self)
    # %q keeps arguments with spaces intact through tmux's shell — including
    # the --sandbox-ro=PATH flags, which were consumed before the dispatch and
    # are re-emitted here so the session's own launch sees them again.
    cmd=$(printf '%q ' "$self" ${RO_FLAGS[@]+"${RO_FLAGS[@]}"} "$@")
    # --sandbox-git and --sandbox-docker were consumed too; being booleans,
    # they travel as environment instead.
    cmd="SANDBOX_IN_TMUX=1 ${SANDBOX_GIT:+SANDBOX_GIT=1 }${SANDBOX_DOCKER:+SANDBOX_DOCKER=1 }$cmd; ec=\$?; if [ \$ec -ne 0 ]; then printf 'exited with status %s — press Enter to close\\n' \"\$ec\"; read -r _; fi"

    tmux new-session -d -s "$session" -c "$PWD" "$cmd" \
        || ldie "could not create the tmux session $session"
    tmux set-environment -t "=$session" SANDBOX_PWD "$PWD" 2>/dev/null || true

    if [ "$mode" = "detach" ]; then
        printf 'sandbox: started %s in the background; attach with: tmux attach -t %s\n' "$session" "$session" >&2
        return 0
    fi
    exec tmux attach-session -t "=$session"
}

# --- doctor ----------------------------------------------------------------
doctor() {
    local manifest vol owner latest label_uid name email host sock gid ro src reason
    printf '%s sandbox — doctor\n' "$AGENT_NAME"
    printf '  launcher version    %s (%s)\n' "$SANDBOX_VERSION" "$(launcher_self)"
    printf '  user / uid          %s / %s\n' "$(sandbox_user)" "$(id -u)"
    printf '  project mount       %s -> %s\n' "$(host_workdir)" "$(container_workdir)"
    # What --sandbox-ro would mount, or why it would refuse. Reported, never
    # fatal: doctor is for finding out.
    for ro in ${RO_PATHS[@]+"${RO_PATHS[@]}"}; do
        if ! src=$(resolve_ro_path "$ro"); then
            printf '  read-only mount     %s REFUSED — does not exist (or cannot be entered)\n' "$ro"
            continue
        fi
        reason=$(ro_check_path "$src")
        if [ -n "$reason" ]; then
            printf '  read-only mount     %s REFUSED — %s\n' "$ro" "$reason"
        else
            printf '  read-only mount     %s -> %s\n' "$src" "$src"
        fi
    done

    if ! have docker; then printf '  docker              NOT INSTALLED\n'; return 1; fi
    if ! docker info >/dev/null 2>&1; then printf '  docker              UNREACHABLE\n'; return 1; fi
    printf '  docker              ok (%s)\n' "$(docker version -f '{{.Server.Version}}' 2>/dev/null || printf 'unknown')"

    if docker image inspect "$IMAGE" >/dev/null 2>&1; then
        label_uid=$(docker image inspect -f '{{index .Config.Labels "sandbox.agent_uid"}}' "$IMAGE" 2>/dev/null)
        printf '  image               %s\n' "$IMAGE"
        printf '  image built by      installer v%s\n' \
            "$(docker image inspect -f '{{index .Config.Labels "sandbox.installer_version"}}' "$IMAGE" 2>/dev/null)"
        if [ -n "$label_uid" ] && [ "$label_uid" != "$(id -u)" ]; then
            printf '  image agent UID     %s  MISMATCH (you are %s) — re-run the installer\n' "$label_uid" "$(id -u)"
        else
            printf '  image agent UID     %s\n' "${label_uid:-unknown}"
        fi
    else
        printf '  image               MISSING (%s)\n' "$IMAGE"
    fi

    # What --sandbox-docker would mount, and whether the agent could use it.
    # Reported always: knowing the flag is unavailable is worth as much as
    # knowing it works, and neither costs anything unless the flag is passed.
    if sock=$(docker_socket_path); then
        gid=''
        if docker image inspect "$IMAGE" >/dev/null 2>&1; then
            gid=$(docker_socket_gid "$sock")
        fi
        if [ -n "$gid" ]; then
            printf '  docker socket       %s (group %s inside) — mount it with --sandbox-docker\n' "$sock" "$gid"
        else
            printf '  docker socket       %s (group undetermined)\n' "$sock"
        fi
    else
        printf '  docker socket       %s is not a unix socket — --sandbox-docker cannot work here\n' "$(docker_endpoint)"
    fi
    if docker image inspect "$IMAGE" >/dev/null 2>&1; then
        if docker run --rm "$IMAGE" docker --version >/dev/null 2>&1; then
            printf '  docker CLI in image present\n'
        else
            printf '  docker CLI in image MISSING — re-run the installer\n'
        fi
    fi

    for vol in "${VOLUMES[@]}"; do
        if docker volume inspect "$vol" >/dev/null 2>&1; then
            owner=$(docker run --rm --user 0:0 -v "$vol:/v" "$IMAGE" \
                sh -c 'stat -c %u /v 2>/dev/null || stat -f %u /v 2>/dev/null' 2>/dev/null | tr -d '\r\n ')
            if [ -n "$owner" ] && [ "$owner" != "$(id -u)" ]; then
                printf '  volume %-12s owned by UID %s, expected %s — re-run the installer\n' "$vol" "$owner" "$(id -u)"
            else
                printf '  volume %-12s ok\n' "$vol"
            fi
        else
            printf '  volume %-12s MISSING\n' "$vol"
        fi
    done

    # State recorded before the mount mirrored the host path is pooled under one
    # directory named for the old fixed mount. Nothing can attribute any of it
    # back to a project, so it is reported, never migrated.
    if [ "$AGENT" = claude ] \
        && docker image inspect "$IMAGE" >/dev/null 2>&1 \
        && docker volume inspect "$CONFIG_VOL" >/dev/null 2>&1 \
        && docker run --rm --user 0:0 -v "$CONFIG_VOL:/v" "$IMAGE" \
            sh -c 'test -d /v/projects/-workspace' >/dev/null 2>&1; then
        printf '  legacy state        projects/-workspace holds sessions and memory recorded\n'
        printf '                      before the mount mirrored the host path, pooled across\n'
        printf '                      every project. Nothing is lost; list it with:\n'
        printf '                        docker run --rm -v %s:/v %s ls /v/projects\n' "$CONFIG_VOL" "$IMAGE"
    fi

    manifest="$(state_dir)/$AGENT.manifest"
    if [ -r "$manifest" ]; then
        printf '  manifest            %s\n' "$manifest"
    else
        printf '  manifest            missing (installed by hand?)\n'
    fi

    # Availability only — the credential itself is never printed.
    if ! have git; then
        printf '  git                 NOT INSTALLED on this host\n'
    else
        name=$(git_config_get user.name)
        email=$(git_config_get user.email)
        if [ -n "$name" ] || [ -n "$email" ]; then
            printf '  git identity        %s <%s>\n' "${name:-?}" "${email:-?}"
        else
            printf '  git identity        NONE configured — commits will fail\n'
        fi
        host=$(git_origin_host) || host=''
        if [ -z "$host" ]; then
            printf '  git credential      no https remote here\n'
        elif git_resolve_cred "$host"; then
            printf '  git credential      available for %s — forward with --sandbox-git\n' "$host"
        else
            printf '  git credential      none stored for %s\n' "$host"
        fi
    fi

    if have curl; then
        latest=$(curl -fsSL --max-time 3 "$RAW_BASE/VERSION" 2>/dev/null | head -1 | tr -d ' \r\n')
        if [ -n "$latest" ] && version_gt "$latest" "$SANDBOX_VERSION"; then
            printf '  upstream            v%s available — %s --sandbox-upgrade\n' "$latest" "$LAUNCHER_NAME"
        elif [ -n "$latest" ]; then
            printf '  upstream            up to date\n'
        fi
    fi
}

do_upgrade() {
    have curl || ldie "curl is required to upgrade"
    printf 'sandbox: fetching the latest installer from %s\n' "$RAW_BASE" >&2
    curl -fsSL "$RAW_BASE/install/$AGENT.sh" | bash -s -- "$@"
}

launcher_usage() {
    cat >&2 <<USAGE
$LAUNCHER_NAME — run $AGENT_NAME sandboxed in the current directory (v$SANDBOX_VERSION)

  $LAUNCHER_NAME [agent arguments...]

Everything is passed through to $AGENT_BIN untouched, except these flags,
which are only recognised in first position:

  --sandbox-git [args...]            also forward a git credential (see below)
  --sandbox-docker [args...]         also mount the host Docker socket (see below)
  --sandbox-ro PATH [args...]        also mount PATH read-only, repeatable (see below)
  --sandbox-tmux [args...]           run inside a tmux session for this project
  --sandbox-tmux-detached [args...]  same, but do not attach
  --sandbox-doctor                   report on image, volumes, UIDs and versions
  --sandbox-upgrade [installer opts] re-run the installer to update
  --sandbox-version                  print the sandbox version
  --sandbox-help                     this message

Your git name and email are always passed through, so the agent can commit.
--sandbox-git additionally forwards a credential for the origin remote's host,
so it can push. That credential is scoped to that one host, but within it the
token's own permissions apply — prefer a fine-grained one.

--sandbox-docker lets the agent use Docker, by mounting the host's socket. Be
deliberate about it: the containers it starts are siblings on your daemon and
can mount any host path, so the sandbox stops being a boundary for that
session. It grants nothing you did not already have — talking to the daemon is
root-equivalent on a rootful one — but it hands that to an autonomous agent.
Bind mounts of the project work because the project keeps its host path; a path
that only exists inside the container silently mounts as an empty directory.

--sandbox-ro PATH (or --sandbox-ro=PATH) mounts a host directory or file into
the session read-only, at the same path it has on the host. Repeat it for more.
Relative paths resolve against the current directory. Write access stays
exactly the project, so a path that is the project or contains it is refused,
as is a path that does not exist, a system path, and your home directory or
anything above it: read-only is not confidentiality, and egress is open. A
path inside the project works, and pins that part of the project read-only.
Note that --sandbox-docker bypasses this: a sibling container can mount the
same path writable.

The project is mounted inside the container at the same path it has on the
host, so each project keeps its own agent memory, session history and
approvals. SANDBOX_WORKDIR overrides that if you need the old fixed path.

Environment:
  SANDBOX_NO_UPDATE_CHECK=1   never check upstream for a newer sandbox
  SANDBOX_NO_GIT=1            pass no git identity or credential at all
  SANDBOX_GIT=1               same as --sandbox-git
  SANDBOX_DOCKER=1            same as --sandbox-docker
  SANDBOX_WORKDIR=/workspace  mount the project at this fixed path instead
                              (its agent state is then shared with every
                              other project run the same way)
USAGE
}

launcher_main() {
    IMAGE="$IMAGE_BASENAME-$(sandbox_user)"
    # Consumed before the dispatch below, so they compose in any order:
    # `--sandbox-docker --sandbox-git --sandbox-tmux` works. The loop stops at
    # the first argument that is not one of them, so a flag still only counts
    # at the front and everything else reaches the agent untouched.
    while [ $# -gt 0 ]; do
        case "$1" in
            --sandbox-git)    SANDBOX_GIT=1; shift ;;
            --sandbox-docker) SANDBOX_DOCKER=1; shift ;;
            --sandbox-ro)     [ $# -ge 2 ] || ldie "--sandbox-ro needs a path"
                              RO_PATHS+=("$2"); shift 2 ;;
            --sandbox-ro=*)   RO_PATHS+=("${1#*=}"); shift ;;
            *) break ;;
        esac
    done
    case "${1:-}" in
        --sandbox-help)           launcher_usage; exit 0 ;;
        --sandbox-version)        printf '%s\n' "$SANDBOX_VERSION"; exit 0 ;;
        --sandbox-doctor)         doctor; exit $? ;;
    esac
    # Resolve and refuse here, before a tmux session exists: a bad path should
    # fail at the prompt, not inside a pane waiting for Enter.
    ro_mount_args
    case "${1:-}" in
        --sandbox-upgrade)        shift; do_upgrade "$@"; exit $? ;;
        --sandbox-tmux)           shift; tmux_launch attach "$@"; exit $? ;;
        --sandbox-tmux-detached)  shift; tmux_launch detach "$@"; exit $? ;;
    esac
    ensure_docker_and_image
    update_check
    pre_run_hook
    run_container "$@"
}
