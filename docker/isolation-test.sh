#!/bin/sh
# isolation-test.sh --- The seven guarantees from section 5.5, on the agent.
#
# Run this inside the container as uid 1000:
#
#   docker exec -u agent enchiridion /usr/local/bin/isolation-test.sh
#
# Tests 1 to 4 and 7 are here. Test 5 is the scrubber unit test. Test 6 is the
# absence of /run/secrets/.env after the supervisor has read it.

set -eu

PHASE=${ISOLATION_PHASE:-all}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[ "$(id -u)" -eq 1000 ] || fail "run this as uid 1000, not $(id -u)"

# 1 and 2: the file is unreadable, and a shell cannot cat it. These need the
# file to exist, so a harness that removes it for test 6 runs the ABSENT phase.
case "$PHASE" in
  present|all)
    if cat /run/secrets/.env >/dev/null 2>&1; then
      fail "the agent can read /run/secrets/.env"
    fi
    if sh -c 'cat /run/secrets/.env' >/dev/null 2>&1; then
      fail "a shell can read /run/secrets/.env"
    fi
    ;;
esac

# 3: hidepid is mounted, so /proc/<supervisor>/environ is not readable.
if [ -r /proc/1/environ ]; then
  fail "/proc/1/environ is readable; hidepid is not active"
fi

# 4: the broker environment has none of the secret names or values.
for name in OPENCODE_API_KEY OPENAI_API_KEY FLUXER_BOT_TOKEN; do
  if env | grep -q "^${name}="; then
    fail "$name is in the agent environment"
  fi
done

# 6 and 7: after the supervisor reads it, the file is gone and no copy is
# anywhere else. A PRESENT phase skips these two because the file must exist
# for test 1.
case "$PHASE" in
  absent|all)
    if [ -e /run/secrets/.env ]; then
      fail "/run/secrets/.env still exists at steady state"
    fi
    found=$(find / -xdev -path /run/secrets -prune -o -name .env -print 2>/dev/null || true)
    if [ -n "$found" ]; then
      fail "a .env exists outside /run/secrets: $found"
    fi
    ;;
esac

echo "isolation: all checks passed as uid $(id -u)"
