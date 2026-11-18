# Enchiridion image for amd64 and arm64.

FROM clfoundation/sbcl:2.6.9-bookworm-slim@sha256:67d9dc30fc2f8e208872cfb8c5594368705fc428581e3e75728b428b3436fe24 AS base

# dist-lock.txt records the base, Debian and Quicklisp pins.
ARG DEBIAN_SNAPSHOT=20261027T000000Z

RUN set -eux; \
    printf '%s\n' \
      'Types: deb' \
      "URIs: http://snapshot.debian.org/archive/debian/${DEBIAN_SNAPSHOT}" \
      'Suites: bookworm bookworm-updates' \
      'Components: main' \
      'Check-Valid-Until: no' \
      '' \
      'Types: deb' \
      "URIs: http://snapshot.debian.org/archive/debian-security/${DEBIAN_SNAPSHOT}" \
      'Suites: bookworm-security' \
      'Components: main' \
      'Check-Valid-Until: no' \
      > /etc/apt/sources.list.d/debian.sources; \
    rm -f /etc/apt/sources.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      git \
      libssl3 \
      libsqlite3-0 \
      zlib1g \
      libffi8 \
      coreutils \
      grep \
      findutils \
      util-linux; \
    rm -rf /var/lib/apt/lists/*

# The uid-1000 broker reads the compiled cache under /opt.
ENV XDG_CACHE_HOME=/opt/enchiridion-cache \
    XDG_CONFIG_HOME=/opt/enchiridion-config \
    ASDF_OUTPUT_TRANSLATIONS="(:output-translations (t \"/opt/enchiridion-cache/common-lisp/\") :ignore-inherited-configuration)" \
    CL_SOURCE_REGISTRY=/opt/enchiridion//:/opt/quicklisp/dists/quicklisp/software//

WORKDIR /opt/enchiridion

FROM base AS build

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      curl \
      build-essential \
      pkg-config \
      libssl-dev \
      libsqlite3-dev \
      zlib1g-dev \
      libffi-dev \
 && rm -rf /var/lib/apt/lists/*

COPY docker/quicklisp.lsp /tmp/quicklisp.lsp

RUN set -eux; \
    curl -fsSLo /tmp/quicklisp-bootstrap.lisp https://beta.quicklisp.org/quicklisp.lisp; \
    echo "4a7a5c2aebe0716417047854267397e24a44d0cce096127411e9ce9ccfeb2c17  /tmp/quicklisp-bootstrap.lisp" \
      | sha256sum -c -; \
    sbcl --script /tmp/quicklisp.lsp /tmp/quicklisp-bootstrap.lisp /opt/quicklisp 2026-01-01; \
    rm -f /tmp/quicklisp-bootstrap.lisp

# Cache dependencies until enchiridion.asd changes.
COPY enchiridion.asd ./

RUN sbcl --non-interactive --no-userinit --no-sysinit \
      --eval '(load "/opt/quicklisp/setup.lisp")' \
      --eval '(ql:quickload (asdf:system-depends-on (asdf:find-system "enchiridion")))'

COPY src ./src

RUN set -eux; \
    sbcl --non-interactive --no-userinit --no-sysinit \
      --eval '(load "/opt/quicklisp/setup.lisp")' \
      --eval '(asdf:load-system "enchiridion")'; \
    { \
      echo "base-image clfoundation/sbcl:2.6.9-bookworm-slim@sha256:67d9dc30fc2f8e208872cfb8c5594368705fc428581e3e75728b428b3436fe24"; \
      echo "debian-snapshot ${DEBIAN_SNAPSHOT}"; \
      echo "quicklisp-bootstrap sha256:4a7a5c2aebe0716417047854267397e24a44d0cce096127411e9ce9ccfeb2c17"; \
      echo "quicklisp-dist $(cat /opt/quicklisp/pinned-dist.txt)"; \
      echo; \
      dpkg-query -W | sort; \
    } > /opt/enchiridion/dist-lock.txt

FROM base AS runtime

COPY --from=build /opt/quicklisp /opt/quicklisp
COPY --from=build /opt/enchiridion /opt/enchiridion
COPY --from=build /opt/enchiridion-cache /opt/enchiridion-cache
COPY --chmod=755 docker/entrypoint.sh docker/isolation-test.sh /usr/local/bin/
COPY --chmod=755 docker/enchiridion.sh /usr/local/bin/enchiridion

ENV ENCHIRIDION_HOME=/var/lib/enchiridion \
    ENCHIRIDION_SOURCE=/opt/enchiridion \
    ENCHIRIDION_SBCL=/usr/local/bin/sbcl \
    ENCHIRIDION_GIT=/usr/bin/git \
    SBCL_HOME=/usr/local/lib/sbcl \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt

WORKDIR /var/lib/enchiridion
USER 0:0
EXPOSE 8787
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
