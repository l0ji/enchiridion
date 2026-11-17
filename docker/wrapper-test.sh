#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
cat > "$TMP/sbcl" <<'EOF'
#!/bin/sh
set -eu
[ "$XDG_CONFIG_HOME" = /opt/enchiridion-config ]
[ "$XDG_CACHE_HOME" = /opt/enchiridion-cache ]
[ "$ASDF_OUTPUT_TRANSLATIONS" = '(:output-translations (t "/opt/enchiridion-cache/common-lisp/") :ignore-inherited-configuration)' ]
[ "$CL_SOURCE_REGISTRY" = "$ENCHIRIDION_SOURCE//:/opt/quicklisp/dists/quicklisp/software//" ]
[ "$#" -eq 4 ]
[ "$1" = --script ]
[ "$2" = "$ENCHIRIDION_SOURCE/src/main.lsp" ]
[ "$3" = help ]
[ "$4" = 'argument with spaces' ]
EOF
chmod +x "$TMP/sbcl"
ENCHIRIDION_SOURCE="$TMP/source with spaces" \
ENCHIRIDION_SBCL="$TMP/sbcl" \
XDG_CONFIG_HOME="$TMP/hostile" \
XDG_CACHE_HOME="$TMP/hostile-cache" \
ASDF_OUTPUT_TRANSLATIONS='(:include "/agent/config.lisp")' \
CL_SOURCE_REGISTRY=/agent/sources// \
sh "$ROOT/docker/enchiridion.sh" help 'argument with spaces'
printf '%s\n' 'Docker wrapper regression passed.'
