#!/bin/sh
# isolation-test.sh --- The isolation guarantees, checked from inside the image.
#
# Nothing in the image runs this for you. Two views, and each one proves only
# what its own uid can observe:
#
#   The supervisor's view, as uid 0. This is the only view that can see whether
#   the secret file exists, what its mode is, and whether the /proc mount
#   carries hidepid:
#     docker exec -u 0 -e ISOLATION_PHASE=present enchiridion \
#       /usr/local/bin/isolation-test.sh
#     docker exec -u 0 -e ISOLATION_PHASE=absent enchiridion \
#       /usr/local/bin/isolation-test.sh
#
#   The agent's view, as uid 1000. This is the one that proves the denial:
#     docker exec -u agent enchiridion /usr/local/bin/isolation-test.sh
#
# ISOLATION_PHASE defaults to all. The two phases exist because the present
# phase needs the secret file to be there and the absent phase needs it gone.
#
# Which check can prove which fact is the point of the split. A uid 1000 process
# cannot tell an absent file from an unreadable one under a root-only directory,
# so deletion is proved in the uid 0 phase and denial is proved in the agent
# phase. A pass that reports a fact its uid cannot see would be a false pass.

set -eu

PHASE=${ISOLATION_PHASE:-all}
STATE_DIR=${ENCHIRIDION_HOME:-/var/lib/enchiridion}
SECRETS_DIR=/run/secrets
SECRETS_FILE="$SECRETS_DIR/.env"
HIDEPID=${ENCHIRIDION_HIDEPID:-2}

SECRET_NAMES="OPENCODE_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY \
FLUXER_BOT_TOKEN ENCHIRIDION_HTTP_TOKEN"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

note() {
  echo "isolation: $*"
}

credential_shaped_name() {
  case "$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')" in
    *_API_KEY*|*_APIKEY*|*_TOKEN*|*_SECRET*|*_PASSWORD*|*_PASSWD*|*_PRIVATE_KEY*|*AUTHORIZATION*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# The mount policy is readable by every uid, which is why both views check it.
# The remount is what the entrypoint does when the run line grants SYS_ADMIN,
# and an environ that cannot be read is not by itself evidence of it: hidepid=0
# with a uid 1000 process that simply never had the file open looks identical
# from one process's point of view.
check_proc_mount() {
  [ "$HIDEPID" = "0" ] && { note "/proc hidepid was opted out"; return 0; }
  grep -q " /proc .*hidepid=$HIDEPID" /proc/mounts ||
    fail "/proc is not mounted with hidepid=$HIDEPID; $(grep ' /proc ' /proc/mounts || echo 'no /proc line')"
}

check_env_names() {
  env_text=$1
  for name in $SECRET_NAMES; do
    if printf '%s\n' "$env_text" | grep -q "^${name}="; then
      fail "$name is in this environment"
    fi
  done
  while IFS= read -r entry; do
    name=${entry%%=*}
    [ -n "$name" ] || continue
    if credential_shaped_name "$name"; then
      fail "$name is credential shaped and is in this environment"
    fi
  done <<EOF
$env_text
EOF
}

if [ "$(id -u)" -eq 0 ]; then
  grep -q enchiridion /proc/1/cmdline 2>/dev/null ||
    fail "pid 1 is not the supervisor; run this in the image the entrypoint starts"
  [ -r /proc/1/environ ] ||
    fail "/proc/1/environ is not readable as uid 0; nothing was checked"

  # The supervisor read the file once and unset every name it read, so a name
  # that survives here is a name every child inherits.
  check_env_names "$(tr '\0' '\n' < /proc/1/environ)"

  # The secrets directory is a tmpfs mount, not a folder with a lock on it.
  grep -q " $SECRETS_DIR " /proc/mounts ||
    fail "$SECRETS_DIR is not a mount"
  mode=$(stat -c '%a' "$SECRETS_DIR")
  [ "$mode" = "700" ] || fail "$SECRETS_DIR is mode $mode, not 700"
  [ "$(stat -c '%u' "$SECRETS_DIR")" = "0" ] || fail "$SECRETS_DIR is not owned by root"

  check_proc_mount

  case "$PHASE" in
    present|all)
      if [ -e "$SECRETS_FILE" ]; then
        [ "$(stat -c '%a' "$SECRETS_FILE")" = "600" ] ||
          fail "$SECRETS_FILE is mode $(stat -c '%a' "$SECRETS_FILE"), not 600"
        [ "$(stat -c '%u' "$SECRETS_FILE")" = "0" ] ||
          fail "$SECRETS_FILE is not owned by root"
        note "phase present: $SECRETS_FILE is present, 600:0, on a root-only tmpfs"
      else
        # A compose env_file route is legitimate and leaves no file. Say which
        # route is in use rather than report a denial that was never tested.
        note "phase present: no secret file; the container environment route is in use"
      fi
      ;;
  esac

  case "$PHASE" in
    absent|all)
      # Only uid 0 can tell gone from unreadable here. This is the check the
      # agent pass cannot make.
      if [ -e "$SECRETS_FILE" ]; then
        fail "$SECRETS_FILE still exists at steady state"
      fi
      note "phase absent: $SECRETS_FILE is gone"
      ;;
  esac

  note "phase $PHASE passed as uid 0: supervisor environment and mounts are clean"
  exit 0
fi

[ "$(id -u)" -eq 1000 ] || fail "run this as uid 1000 or uid 0, not $(id -u)"

check_proc_mount

case "$PHASE" in
  present|all)
    # Denial, not absence. A file that does not exist also fails to open, so the
    # present phase additionally asserts that the directory itself is closed to
    # uid 1000: without that, this check passes on an empty tmpfs.
    if [ -r "$SECRETS_DIR" ] || [ -x "$SECRETS_DIR" ]; then
      fail "uid 1000 can traverse $SECRETS_DIR, so denial was never proved"
    fi
    if cat "$SECRETS_FILE" >/dev/null 2>&1; then
      fail "the agent can read $SECRETS_FILE"
    fi
    if sh -c "cat $SECRETS_FILE" >/dev/null 2>&1; then
      fail "a shell can read $SECRETS_FILE"
    fi
    ;;
esac

[ -r /proc/1/environ ] && fail "/proc/1/environ is readable; hidepid is not active"

check_env_names "$(env)"

case "$PHASE" in
  absent|all)
    # What uid 1000 can prove about steady state: the directory is still closed.
    # Deletion itself is proved by the uid 0 pass, which can see the path.
    if [ -r "$SECRETS_DIR" ] || [ -x "$SECRETS_DIR" ]; then
      fail "uid 1000 can traverse $SECRETS_DIR at steady state"
    fi
    # And no readable copy is anywhere this uid can walk.
    found=$(
      {
        find / -xdev -path "$SECRETS_DIR" -prune -o -name .env -print 2>/dev/null || true
        find "$STATE_DIR" -path "$SECRETS_DIR" -prune -o -name .env -print 2>/dev/null || true
      } | sort -u
    )
    if [ -n "$found" ]; then
      fail "a .env exists outside $SECRETS_DIR: $found"
    fi
    ;;
esac

note "phase $PHASE passed as uid $(id -u): secrets denied, no readable copy, hidepid set"
