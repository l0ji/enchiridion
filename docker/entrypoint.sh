#!/bin/sh
# entrypoint.sh --- Container entry point.
#
# The two isolation flags the security model depends on belong on the run
# command line rather than here, because only the runtime can supply them:
#
#   --tmpfs /run/secrets:mode=0700
#   --cap-add SYS_ADMIN          # this script then remounts /proc with hidepid
#
# A bind mount for /run/secrets defeats the isolation. So does /proc without
# hidepid: it lets the sandbox read the supervisor's cmdline, cwd, and memory
# maps. Docker has no proc mount type, so the capability comes from the run line
# and the remount happens below. The remount fails on a kernel that does not
# offer the proc hidepid option and on a /proc that cannot be remounted;
# ENCHIRIDION_REQUIRE_HIDEPID decides whether that is fatal. The hardened
# deployment sets it, because a supervisor whose process view uid 1000 can read
# is a supervisor whose secrets are one /proc read away.
#
# What else this script does is set up the two users and hand over. It never
# writes a secret anywhere a later process could find it, and it never prints
# one.

set -eu

SECRETS_DIR=/run/secrets
SECRETS_FILE="$SECRETS_DIR/.env"
STATE_DIR=${ENCHIRIDION_HOME:-/var/lib/enchiridion}

log() {
  echo "entrypoint: $*"
}

fail() {
  echo "entrypoint: $*" >&2
  exit 1
}

[ "$(id -u)" -eq 0 ] || fail "the supervisor must start as root; it holds the secrets"

# The tmpfs is the point. Without it, /run/secrets is an ordinary directory
# and mode 700 is the only thing between the agent and the key.
grep -q " $SECRETS_DIR " /proc/mounts 2>/dev/null || {
  log "$SECRETS_DIR is not a mount. Run with --tmpfs $SECRETS_DIR:mode=0700"
  log "A plain directory here is not isolation, it is a folder with a lock on it."
  exit 1
}

chmod 700 "$SECRETS_DIR"

# hidepid is the half of the proc guarantee that only the runtime can supply.
# Docker mounts /proc itself, so the remount needs SYS_ADMIN on the run line.
# The default is 2, which hides every other user's processes; 0 is the opt-out
# and skips the remount without a word. A failure here is fatal only when the
# operator asks for it: a Docker Desktop kernel and a nested container both
# refuse this remount, and refusing to start there would make the image
# unusable rather than safe.
HIDEPID=${ENCHIRIDION_HIDEPID:-2}
if [ "$HIDEPID" != "0" ]; then
  if mount -o "remount,hidepid=$HIDEPID" /proc 2>/dev/null; then
    log "/proc remounted with hidepid=$HIDEPID"
  elif [ "${ENCHIRIDION_REQUIRE_HIDEPID:-0}" = "1" ]; then
    fail "cannot remount /proc with hidepid=$HIDEPID;" \
         "add --cap-add SYS_ADMIN, or set ENCHIRIDION_HIDEPID=0 to opt out"
  else
    log "could not remount /proc with hidepid=$HIDEPID; uid 1000 can see the supervisor's process"
  fi
fi

# The secret file is optional here. The operator supplies it as a read-only
# bind mount at /run/secrets/.env, or copies it in after start, or puts the
# values in the container environment. This script only reports an unexpected
# mode; docs/deployment.md describes the routes and their trade-offs.
if [ -f "$SECRETS_FILE" ]; then
  [ "$(stat -c '%a:%u' "$SECRETS_FILE")" = "600:0" ] || \
    log "$SECRETS_FILE has unexpected ownership; continuing"
fi

if ! id agent >/dev/null 2>&1; then
  mkdir -p /etc /home/agent
  [ -f /etc/passwd ] || : > /etc/passwd
  [ -f /etc/group ] || : > /etc/group
  echo 'agent:x:1000:1000:agent:/home/agent:/bin/sh' >> /etc/passwd
  echo 'agent:x:1000:' >> /etc/group
  chown 1000:1000 /home/agent
fi

AGENT_UID=$(id -u agent)
AGENT_GID=$(id -g agent)

# The supervisor validates that its configuration file and every parent
# directory belong to a uid the agent cannot write as. A bind mount keeps the
# host owner, which is usually the operator and not root, so a check that
# insisted on root ownership would reject the documented Compose run line. The
# copy is root-owned, mode 600, in a root-owned directory, and the supervisor is
# pointed at it explicitly.
if [ -f /opt/enchiridion/config.lsp ]; then
  mkdir -p /etc/enchiridion
  if ! cmp -s /opt/enchiridion/config.lsp /etc/enchiridion/config.lsp 2>/dev/null; then
    cp /opt/enchiridion/config.lsp /etc/enchiridion/config.lsp
  fi
  chown 0:0 /etc/enchiridion /etc/enchiridion/config.lsp
  chmod 700 /etc/enchiridion
  chmod 600 /etc/enchiridion/config.lsp
  export ENCHIRIDION_CONFIG=/etc/enchiridion/config.lsp
  log "configuration copied to $ENCHIRIDION_CONFIG and closed to the agent"
fi

root_controlled_directory() {
  [ -d "$1" ] && [ ! -L "$1" ] && [ "$(stat -c %u -- "$1")" = 0 ] || return 1
  mode=$(stat -c %a -- "$1") || return 1
  [ -n "$mode" ] && [ "$((0$mode & 022))" -eq 0 ]
}

case "$STATE_DIR" in
  /*) ;;
  *) fail "ENCHIRIDION_HOME must be an absolute state directory" ;;
esac
while [ "${STATE_DIR%/}" != "$STATE_DIR" ]; do STATE_DIR=${STATE_DIR%/}; done
[ -n "$STATE_DIR" ] && [ "$(realpath -m -- "$STATE_DIR")" = "$STATE_DIR" ] ||
  fail "ENCHIRIDION_HOME must name a canonical state directory other than /"

parent=$(dirname -- "$STATE_DIR")
while :; do
  root_controlled_directory "$parent" || fail "state ancestor is not root-controlled: $parent"
  [ "$parent" != / ] || break
  parent=$(dirname -- "$parent")
done

approvals="$STATE_DIR/canary-approvals"
trusted_state=0
if root_controlled_directory "$STATE_DIR"; then trusted_state=1; fi
check_approvals() {
  if [ -e "$approvals" ] || [ -L "$approvals" ]; then
    # A legacy agent-writable volume could contain self-approved checks
    [ "$trusted_state" = 1 ] && root_controlled_directory "$approvals" ||
      fail "untrusted canary approvals at $approvals; move them aside before upgrading"
  fi
}

check_approvals
mkdir -p "$STATE_DIR"
chown 0:0 "$STATE_DIR"
chmod 755 "$STATE_DIR"
check_approvals
if [ ! -d "$approvals" ]; then
  mkdir -m 700 "$approvals"
fi
chmod 700 "$approvals"

# Only the agent's repository, runtime sockets and scratch need write access
for name in agents run tmp; do
  directory="$STATE_DIR/$name"
  [ ! -L "$directory" ] || fail "state directory must not be a symlink: $directory"
  mkdir -p "$directory"
  chown -hR -P "$AGENT_UID:$AGENT_GID" "$directory"
done
mkdir -p /run/enchiridion
chown "$AGENT_UID:$AGENT_GID" /run/enchiridion
chmod 700 /run/enchiridion

# Git reads the agent's identity from .gitconfig in the state root
AGENT_GITCONFIG="$STATE_DIR/.gitconfig"
[ ! -L "$AGENT_GITCONFIG" ] || fail "agent .gitconfig must not be a symlink"
if [ ! -e "$AGENT_GITCONFIG" ]; then
  printf '%s\n' '[user]' '	name = enchiridion agent' \
    '	email = agent@enchiridion.invalid' '[commit]' '	gpgsign = false' \
    > "$AGENT_GITCONFIG"
  chown "$AGENT_UID:$AGENT_GID" "$AGENT_GITCONFIG"
  chmod 600 "$AGENT_GITCONFIG"
fi
[ -f "$AGENT_GITCONFIG" ] || fail "agent .gitconfig must be a regular file"

# The agent writes only its own state subdirectories
export ENCHIRIDION_HOME="$STATE_DIR"
export PATH=/usr/local/bin:/usr/bin:/bin

log "supervisor uid $(id -u), agent uid $(id -u agent)"
log "state   $STATE_DIR"
log "secrets $SECRETS_DIR"

exec /usr/local/bin/enchiridion "$@"