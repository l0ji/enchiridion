# Dockerfile --- Build the enchiridion image with Docker only.
#
# Two stages. The build stage installs SBCL and Quicklisp, downloads the Lisp
# dependencies, and compiles the core into a fasl cache. The runtime stage keeps
# the compiler out and copies the compiled result.
#
# Build it from the repository root:
#
#   docker build -t enchiridion:0.1.0 -f docker/Dockerfile .
#
# The base image is multi-arch, so the same file builds on amd64 and arm64.
# The image runs as root. The entrypoint creates the agent user and drops to
# uid 1000 for every tool.

FROM clfoundation/sbcl:2.6.9-bookworm-slim@sha256:67d9dc30fc2f8e208872cfb8c5594368705fc428581e3e75728b428b3436fe24 AS build

# Every input is pinned. The base image is a manifest-list digest, so it cannot
# move under a tag; the Debian archive is a snapshot, so a rebuild installs the
# same package versions; and the Quicklisp bootstrap and its distribution are
# checked against recorded hashes and a recorded version. Bumping any one of
# them is a deliberate edit, and docs/deployment.md has the procedure.
ARG DEBIAN_SNAPSHOT=20260101T000000Z

RUN set -eux; \
    printf '%s\n' \
      'Types: deb' \
      "URIs: http://snapshot.debian.org/archive/debian/${DEBIAN_SNAPSHOT}" \
      'Suites: bookworm' \
      'Components: main' \
      'Check-Valid-Until: no' \
      > /etc/apt/sources.list.d/debian.sources; \
    rm -f /etc/apt/sources.list

# The dependencies that build a C library for Lisp, not the ones that only run
# it:
#   libssl-dev      cl+ssl, which dexador needs for HTTPS
#   libsqlite3-dev  dbd-sqlite3, the memory store
#   zlib1g-dev      cl+ssl and dexador
#   libffi-dev      cffi
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      git \
      build-essential \
      pkg-config \
      libssl-dev \
      libsqlite3-dev \
      zlib1g-dev \
      libffi-dev \
 && rm -rf /var/lib/apt/lists/*

# Quicklisp supplies the eleven systems the core depends on. It lives at
# /opt/quicklisp so the runtime stage can copy it.
# The bootstrap is checked before it is loaded, and the distribution is pinned to
# one released version rather than whatever the current distribution happens to
# be that day. The check at the end fails the build when the server answered with
# a different version than the one pinned here.
RUN set -eux; \
    curl -fsSLo /tmp/quicklisp.lisp https://beta.quicklisp.org/quicklisp.lisp; \
    echo "4a7a5c2aebe0716417047854267397e24a44d0cce0961274119e9ce9ccfeb2c17  /tmp/quicklisp.lisp" \
      | sha256sum -c -; \
    sbcl --non-interactive --no-userinit --no-sysinit \
      --load /tmp/quicklisp.lisp \
      --eval '(quicklisp-quickstart:install :path "/opt/quicklisp/")' \
      --load /opt/quicklisp/setup.lisp \
      --eval '(progn (dolist (dist (ql-dist:all-dists)) (when (equal (ql-dist:name dist) "quicklisp") (ql-dist:uninstall dist))) (ql-dist:install-dist "http://beta.quicklisp.org/dist/quicklisp/2026-01-01/distinfo.txt" :prompt nil :replace t) (let ((version (ql-dist:version (ql-dist:find-dist "quicklisp")))) (unless (equal version "2026-01-01") (error "the quicklisp dist is ~A, not the pinned 2026-01-01" version)) (with-open-file (stream "/opt/quicklisp/pinned-dist.txt" :direction :output :if-exists :supersede) (format stream "~A~%" version))))'; \
    rm -f /tmp/quicklisp.lisp

WORKDIR /opt/enchiridion
COPY enchiridion.asd ./
COPY src ./src

# The source registry and the fasl cache. The runtime stage copies both paths,
# so ASDF finds the compiled files instead of compiling again at first run.
#
# The cache is not under /root: the broker child drops to uid 1000, and it has
# to read the compiled files. /root is not traversable by that user.
ENV XDG_CACHE_HOME=/opt/enchiridion-cache \
    XDG_CONFIG_HOME=/opt/enchiridion-config \
    ASDF_OUTPUT_TRANSLATIONS="(:output-translations (t \"/opt/enchiridion-cache/common-lisp/\") :ignore-inherited-configuration)" \
    CL_SOURCE_REGISTRY=/opt/enchiridion//:/opt/quicklisp/dists/quicklisp/software//

# Fetch every dependency first. This layer caches, so a change to the core does
# not download Quicklisp again.
RUN sbcl --non-interactive --no-userinit --no-sysinit \
      --eval '(load "/opt/quicklisp/setup.lisp")' \
      --eval '(ql:quickload (list "alexandria" "cl-ppcre" "dexador" "com.inuoe.jzon" "cl-jschema" "usocket" "bordeaux-threads" "hunchentoot" "websocket-driver-client" "dbi" "dbd-sqlite3" "ironclad" "cl-base64"))'

# Compile the core into the fasl cache. A compile error stops the build here.
RUN sbcl --non-interactive --no-userinit --no-sysinit \
      --eval '(load "/opt/quicklisp/setup.lisp")' \
      --eval '(asdf:load-system "enchiridion")'

# What this image was built from, so an operator reading a running container can
# see the exact snapshot and distribution rather than guessing from a tag.
RUN set -eux; \
    { \
      echo "base-image clfoundation/sbcl:2.6.9-bookworm-slim@sha256:67d9dc30fc2f8e208872cfb8c5594368705fc428581e3e75728b428b3436fe24"; \
      echo "debian-snapshot ${DEBIAN_SNAPSHOT}"; \
      echo "quicklisp-bootstrap sha256:4a7a5c2aebe0716417047854267397e24a44d0cce0961274119e9ce9ccfeb2c17"; \
      echo "quicklisp-dist $(cat /opt/quicklisp/pinned-dist.txt)"; \
      echo; \
      dpkg-query -W | sort; \
    } > /opt/enchiridion/dist-lock.txt

FROM clfoundation/sbcl:2.6.9-bookworm-slim@sha256:67d9dc30fc2f8e208872cfb8c5594368705fc428581e3e75728b428b3436fe24 AS runtime

# The same pinned archive as the build stage, so both halves of the image come
# from one snapshot of Debian.
ARG DEBIAN_SNAPSHOT=20260101T000000Z

RUN set -eux; \
    printf '%s\n' \
      'Types: deb' \
      "URIs: http://snapshot.debian.org/archive/debian/${DEBIAN_SNAPSHOT}" \
      'Suites: bookworm' \
      'Components: main' \
      'Check-Valid-Until: no' \
      > /etc/apt/sources.list.d/debian.sources; \
    rm -f /etc/apt/sources.list

# Runtime libraries only. git stays because the agent directory is a git
# repository and `journey` and `undo` use it.
#   libssl3         cl+ssl
#   libsqlite3-0    dbd-sqlite3
#   zlib1g, libffi8 cl+ssl and cffi
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      git \
      libssl3 \
      libsqlite3-0 \
      zlib1g \
      libffi8 \
      coreutils \
      grep \
      findutils \
      util-linux \
 && rm -rf /var/lib/apt/lists/*

# The compiled dependencies, the compiled core, and the source that the fasl
# cache is keyed on. Both stages use the same paths, so the cache stays valid.
COPY --from=build /opt/quicklisp /opt/quicklisp
COPY --from=build /opt/enchiridion /opt/enchiridion
COPY --from=build /opt/enchiridion-cache /opt/enchiridion-cache

COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY docker/isolation-test.sh /usr/local/bin/isolation-test.sh
COPY docker/enchiridion.sh /usr/local/bin/enchiridion
RUN chmod +x /usr/local/bin/entrypoint.sh \
             /usr/local/bin/isolation-test.sh \
             /usr/local/bin/enchiridion

# ENCHIRIDION_SOURCE is the installed tree, and ENCHIRIDION_SBCL is the SBCL
# the broker child starts. The certificate bundle is the file Debian ships, and
# the image sets the file and not the directory.
ENV PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/bin \
    ENCHIRIDION_HOME=/var/lib/enchiridion \
    ENCHIRIDION_SOURCE=/opt/enchiridion \
    ENCHIRIDION_SBCL=/usr/local/bin/sbcl \
    ENCHIRIDION_GIT=/usr/bin/git \
    SBCL_HOME=/usr/local/lib/sbcl \
    XDG_CACHE_HOME=/opt/enchiridion-cache \
    XDG_CONFIG_HOME=/opt/enchiridion-config \
    ASDF_OUTPUT_TRANSLATIONS="(:output-translations (t \"/opt/enchiridion-cache/common-lisp/\") :ignore-inherited-configuration)" \
    CL_SOURCE_REGISTRY=/opt/enchiridion//:/opt/quicklisp/dists/quicklisp/software// \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt

WORKDIR /var/lib/enchiridion
USER 0:0
EXPOSE 8787
VOLUME ["/var/lib/enchiridion"]
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
