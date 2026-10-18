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

FROM clfoundation/sbcl:2.6.9-bookworm-slim AS build

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
RUN curl -fsSLo /tmp/quicklisp.lisp https://beta.quicklisp.org/quicklisp.lisp \
 && sbcl --non-interactive --no-userinit --no-sysinit \
      --load /tmp/quicklisp.lisp \
      --eval '(quicklisp-quickstart:install :path "/opt/quicklisp/")' \
 && rm -f /tmp/quicklisp.lisp

WORKDIR /opt/enchiridion
COPY enchiridion.asd ./
COPY src ./src

# The source registry and the fasl cache. The runtime stage copies both paths,
# so ASDF finds the compiled files instead of compiling again at first run.
#
# The cache is not under /root: the broker child drops to uid 1000, and it has
# to read the compiled files. /root is not traversable by that user.
ENV XDG_CACHE_HOME=/opt/enchiridion-cache \
    CL_SOURCE_REGISTRY=/opt/enchiridion//:/opt/quicklisp/dists/quicklisp/software//

# Fetch every dependency first. This layer caches, so a change to the core does
# not download Quicklisp again.
RUN sbcl --non-interactive --no-userinit --no-sysinit \
      --eval '(load "/opt/quicklisp/setup.lisp")' \
      --eval '(ql:quickload (list "alexandria" "cl-ppcre" "dexador" "com.inuoe.jzon" "cl-jschema" "usocket" "bordeaux-threads" "hunchentoot" "websocket-driver-client" "dbi" "dbd-sqlite3"))'

# Compile the core into the fasl cache. A compile error stops the build here.
RUN sbcl --non-interactive --no-userinit --no-sysinit \
      --eval '(load "/opt/quicklisp/setup.lisp")' \
      --eval '(asdf:load-system "enchiridion")'

FROM clfoundation/sbcl:2.6.9-bookworm-slim AS runtime

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
    SBCL_HOME=/usr/local/lib/sbcl \
    XDG_CACHE_HOME=/opt/enchiridion-cache \
    CL_SOURCE_REGISTRY=/opt/enchiridion//:/opt/quicklisp/dists/quicklisp/software// \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt

WORKDIR /var/lib/enchiridion
USER 0:0
EXPOSE 8787
VOLUME ["/var/lib/enchiridion"]
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
