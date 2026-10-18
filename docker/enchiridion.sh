#!/bin/sh
# enchiridion.sh --- Start the program inside the Docker image.
#
# The Nix build wrote this wrapper with makeWrapper. Docker builds the image
# now, so the wrapper is a file in the repository. It sets the paths the
# program cannot guess, then starts the entry script.
#
# The paths are the ones the builder used, so ASDF finds the compiled files:
#
#   ENCHIRIDION_SOURCE    the installed tree, and the ASDF source registry
#   /opt/quicklisp        the dependency sources
#   XDG_CACHE_HOME        the fasl cache the build filled
#
# The cache is world readable, because the broker child drops to uid 1000 and
# reads it. /root is not the cache: uid 1000 cannot traverse that directory.
#
# --script also turns off the init files, so the Quicklisp setup in ~/.sbclrc
# does not load at run time.

set -eu

ENCHIRIDION_SOURCE=${ENCHIRIDION_SOURCE:-/opt/enchiridion}
ENCHIRIDION_SBCL=${ENCHIRIDION_SBCL:-/usr/local/bin/sbcl}
XDG_CACHE_HOME=${XDG_CACHE_HOME:-/opt/enchiridion-cache}
SBCL_HOME=${SBCL_HOME:-/usr/local/lib/sbcl}
CL_SOURCE_REGISTRY="${ENCHIRIDION_SOURCE}//:/opt/quicklisp/dists/quicklisp/software//"

export ENCHIRIDION_SOURCE ENCHIRIDION_SBCL XDG_CACHE_HOME SBCL_HOME CL_SOURCE_REGISTRY

exec "$ENCHIRIDION_SBCL" --script "$ENCHIRIDION_SOURCE/src/main.cl" "$@"
