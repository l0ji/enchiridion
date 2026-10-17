#!/bin/sh
# entrypoint.sh --- Container entry point.
#
# The two mount flags the security model depends on are set on the command
# line rather than here, because only the runtime can honour them:
#
#   --tmpfs /run/secrets:mode=0700
#   --mount type=proc,source=proc,destination=/proc,options=hidepid=2
#
# A bind mount for /run/secrets defeats the isolation, and /proc without
# hidepid lets the sandbox read the supervisor's environment. Both belong in
# the run command, and docker/ is not the place to keep them.
#
# What this script does is set up the two users and hand over. It never writes
# a secret anywhere a later process could find it, and it never prints one.

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
mountpoint -q "$SECRETS_DIR" || [ -n "$(grep " $SECRETS_DIR " /proc/mounts 2>/dev/null)" ] || {
  log "$SECRETS_DIR is not a mount. Run with --tmpfs $SECRETS_DIR:mode=0700"
  log "A plain directory here is not isolation, it is a folder with a lock on it."
  exit 1
}

chmod 700 "$SECRETS_DIR"

# The host .env is copied in at start, never bind mounted. A bind mount would
# put the operator's file at its host path inside the container, where the
# source tree's shape makes it trivially findable.
if [ -f "$SECRETS_FILE" ]; then
  [ "$(stat -c '%a:%u' "$SECRETS_FILE")" = "600:0" ] || \
    log "$SECRETS_FILE has unexpected ownership; continuing"
fi

id agent >/dev/null 2>&1 || fail "uid 1000 is missing from the image"

AGENT_UID=$(id -u agent)
AGENT_GID=$(id -g agent)

mkdir -p "$STATE_DIR" "$STATE_DIR/agents/default" /run/enchiridion
# The broker runs as the agent and must read and write the files it acts on.
# The supervisor is root and reaches them anyway; the secrets tmpfs is the one
# directory that stays 700 root.
chown -R "$AGENT_UID:$AGENT_GID" "$STATE_DIR"
chown "$AGENT_UID:$AGENT_GID" /run/enchiridion
chmod 700 /run/enchiridion

# The agent gets a home it can write and nothing else. PATH is built here, not
# inherited: nothing reaches this process's environment and is passed on by
# default.
export ENCHIRIDION_HOME="$STATE_DIR"
export PATH=/usr/local/bin:/usr/bin:/bin

log "supervisor uid $(id -u), agent uid $(id -u agent)"
log "state   $STATE_DIR"
log "secrets $SECRETS_DIR"

exec /usr/local/bin/enchiridion "$@"