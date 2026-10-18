#!/bin/sh
# entrypoint.sh --- Container entry point.
#
# The two isolation flags the security model depends on belong on the run
# command line rather than here, because only the runtime can honour them:
#
#   --tmpfs /run/secrets:mode=0700
#   --cap-add SYS_ADMIN          # then: mount -o remount,hidepid=2 /proc
#
# A bind mount for /run/secrets defeats the isolation. So does /proc without
# hidepid: it lets the sandbox read the supervisor's cmdline, file descriptors
# and memory maps. Docker has no proc mount type, so the run line adds the
# capability and the remount is the operator's next step, which is why this
# script does not pretend to do it.
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
grep -q " $SECRETS_DIR " /proc/mounts 2>/dev/null || {
  log "$SECRETS_DIR is not a mount. Run with --tmpfs $SECRETS_DIR:mode=0700"
  log "A plain directory here is not isolation, it is a folder with a lock on it."
  exit 1
}

chmod 700 "$SECRETS_DIR"

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

# run holds the broker socket and the control and status files. The broker
# child drops to the agent uid and binds the socket there, so run must exist
# before the chown and must belong to the agent. tmp is the agent's scratch
# directory, because /tmp is not writable by uid 1000 in every image.
mkdir -p "$STATE_DIR" "$STATE_DIR/agents/default" "$STATE_DIR/run" "$STATE_DIR/tmp" /run/enchiridion
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