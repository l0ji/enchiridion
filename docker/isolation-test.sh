#!/bin/sh
# isolation-test.sh --- The seven guarantees from section 5.5, on the agent.
#
# Nothing in the image runs this for you. Three ways to run it:
#
#   The agent's view, with the secret file still in the tmpfs:
#     docker exec -u agent -e ISOLATION_PHASE=present enchiridion \
#       /usr/local/bin/isolation-test.sh
#
#   The agent's view at steady state, after the supervisor has read the file:
#     docker exec -u agent -e ISOLATION_PHASE=absent enchiridion \
#       /usr/local/bin/isolation-test.sh
#
#   The supervisor's view, as uid 0, which is the one check that looks at the
#   supervisor process rather than at what the agent can reach:
#     docker exec -u 0 enchiridion /usr/local/bin/isolation-test.sh
#
# ISOLATION_PHASE defaults to all, which is the present and absent phases in
# one run. The two phases exist because test 1 needs the file to be there and
# test 6 needs it gone.
#
# Tests 1 to 4 and 7 are here. Test 5 is the scrubber unit test. Test 6 is the
# absence of /run/secrets/.env after the supervisor has read it.

set -eu

PHASE=${ISOLATION_PHASE:-all}
STATE_DIR=${ENCHIRIDION_HOME:-/var/lib/enchiridion}

# The names the shipped configuration reads: the model keys, the Fluxer bot
# token, and the webhook token. A config.cl that renames one has to add the new
# name here too, or the hole this closes opens again. The shape check below is
# the one that catches a name nobody listed.
SECRET_NAMES="OPENCODE_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY \
FLUXER_BOT_TOKEN ENCHIRIDION_HTTP_TOKEN"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# A credential-shaped NAME, by the same vocabulary
# ENCHIRIDION.LLM.SECRETS:CREDENTIAL-VARIABLE-P uses: a token anywhere in the
# name, or AUTHORIZATION anywhere. It is a substring match and not a suffix
# match, because AWS_SECRET_ACCESS_KEY is a credential whose credential word is
# not the last segment. Shell case globs are case-sensitive, so the name is
# folded to upper case first, the way the predicate folds it.
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

# The supervisor's own environment. The loader reads every configured name and
# then unsets it from the process it read it in, so a name that survives here
# is a name a child would inherit. The entrypoint ends in `exec`, so pid 1 is
# the supervisor and not a shell wrapping it.
if [ "$(id -u)" -eq 0 ]; then
  grep -q enchiridion /proc/1/cmdline 2>/dev/null ||
    fail "pid 1 is not the supervisor; run this in the image the entrypoint starts"
  [ -r /proc/1/environ ] ||
    fail "/proc/1/environ is not readable as uid 0; nothing was checked"
  supervisor_env=$(tr '\0' '\n' < /proc/1/environ)
  for name in $SECRET_NAMES; do
    if printf '%s\n' "$supervisor_env" | grep -q "^${name}="; then
      fail "$name is still in the supervisor environment"
    fi
  done
  # The list above has to keep up with config.cl. The shape check does not: it
  # catches a credential the configuration never named, which is exactly the
  # name that would otherwise survive in every child this process starts.
  while IFS= read -r entry; do
    name=${entry%%=*}
    [ -n "$name" ] || continue
    if credential_shaped_name "$name"; then
      fail "$name is credential shaped and is still in the supervisor environment"
    fi
  done <<EOF
$supervisor_env
EOF
  echo "isolation: phase $PHASE passed as uid $(id -u); supervisor env is clean"
  exit 0
fi

[ "$(id -u)" -eq 1000 ] || fail "run this as uid 1000 or uid 0, not $(id -u)"

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

# 4: the broker environment holds no secret name or credential-shaped name.
for name in $SECRET_NAMES; do
  if env | grep -q "^${name}="; then
    fail "$name is in the agent environment"
  fi
done
while IFS= read -r entry; do
  name=${entry%%=*}
  [ -n "$name" ] || continue
  if credential_shaped_name "$name"; then
    fail "$name is credential shaped and is in the agent environment"
  fi
done <<EOF
$(env)
EOF

# 6 and 7: after the supervisor reads it, the file is gone and no copy is
# anywhere else. A PRESENT phase skips these two because the file must exist
# for test 1.
case "$PHASE" in
  absent|all)
    if [ -e /run/secrets/.env ]; then
      fail "/run/secrets/.env still exists at steady state"
    fi
    # Two roots, because -xdev stops at a filesystem boundary and the state
    # volume is where agent code writes. One find cannot see both.
    found=$(
      {
        find / -xdev -path /run/secrets -prune -o -name .env -print 2>/dev/null || true
        find "$STATE_DIR" -path /run/secrets -prune -o -name .env -print 2>/dev/null || true
      } | sort -u
    )
    if [ -n "$found" ]; then
      fail "a .env exists outside /run/secrets: $found"
    fi
    ;;
esac

echo "isolation: phase $PHASE passed as uid $(id -u)"
