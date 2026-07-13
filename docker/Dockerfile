ARG BASE_IMAGE

FROM ${BASE_IMAGE} AS builder

ENV DEBIAN_FRONTEND=noninteractive

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      build-essential pkg-config meson ninja-build \
      autoconf automake libtool gettext gperf \
      libgnutls28-dev libev-dev libpam0g-dev liblz4-dev libseccomp-dev \
      libreadline-dev libnl-route-3-dev libprotobuf-c-dev protobuf-c-compiler \
      libtalloc-dev; \
    for package in \
      autopoint libllhttp-dev libhttp-parser-dev liboath-dev libkrb5-dev \
      libradcli-dev libsystemd-dev libmaxminddb-dev libpcre2-dev libwrap0-dev; do \
      if apt-cache show "${package}" >/dev/null 2>&1; then \
        apt-get install -y --no-install-recommends "${package}"; \
      fi; \
    done; \
    rm -rf /var/lib/apt/lists/*

COPY source /usr/src/ocserv

RUN set -eux; \
    cd /usr/src/ocserv; \
    if [ -f meson.build ]; then \
      meson setup /tmp/ocserv-build . --prefix=/usr/local --buildtype=release --wrap-mode=nodownload; \
      meson compile -C /tmp/ocserv-build; \
      meson install -C /tmp/ocserv-build --no-rebuild --strip; \
    else \
      if [ ! -x ./configure ]; then autoreconf -fiv; fi; \
      mkdir -p /tmp/ocserv-build; \
      cd /tmp/ocserv-build; \
      /usr/src/ocserv/configure --prefix=/usr/local; \
      make -j"$(nproc)"; \
      make install-strip; \
    fi; \
    ldconfig; \
    /usr/local/sbin/ocserv --version; \
    install -d -m 0755 /usr/share/licenses/ocserv; \
    if [ -f /usr/src/ocserv/COPYING ]; then cp /usr/src/ocserv/COPYING /usr/share/licenses/ocserv/COPYING; fi; \
    find /usr/local -type f -exec sh -c 'ldd "$1" 2>/dev/null || true' sh {} \; \
      | awk '/=> \// {print $3} /^\// {print $1}' \
      | sort -u > /tmp/ocserv-runtime-libraries.txt; \
    test -s /tmp/ocserv-runtime-libraries.txt; \
    while IFS= read -r library; do \
      resolved="$(readlink -f "${library}")"; \
      case "${resolved}" in /usr/local/*) continue ;; esac; \
      dpkg-query -S "${resolved}" 2>/dev/null || dpkg-query -S "${library}"; \
    done < /tmp/ocserv-runtime-libraries.txt \
      | cut -d: -f1 \
      | sort -u > /tmp/ocserv-runtime-packages.txt; \
    test -s /tmp/ocserv-runtime-packages.txt

FROM ${BASE_IMAGE} AS runtime

ARG BASE_IMAGE
ARG OCSERV_VERSION
ARG SOURCE_SHA256

LABEL org.opencontainers.image.title="ocserv-vps" \
      org.opencontainers.image.description="Dockerized ocserv built from a verified upstream source release" \
      org.opencontainers.image.source="https://github.com/khorevaa/ocserv-vps" \
      org.opencontainers.image.licenses="GPL-2.0-or-later" \
      org.opencontainers.image.version="${OCSERV_VERSION}" \
      org.opencontainers.image.base.name="${BASE_IMAGE}" \
      org.ocserv-vps.source-sha256="${SOURCE_SHA256}"

ENV DEBIAN_FRONTEND=noninteractive

COPY --from=builder /tmp/ocserv-runtime-packages.txt /tmp/ocserv-runtime-packages.txt

RUN set -eux; \
    apt-get update; \
    xargs -r apt-get install -y --no-install-recommends < /tmp/ocserv-runtime-packages.txt; \
    apt-get install -y --no-install-recommends \
      ca-certificates iproute2 iptables openssl tini; \
    rm -f /tmp/ocserv-runtime-packages.txt; \
    rm -rf /var/lib/apt/lists/*

COPY --from=builder /usr/local/ /usr/local/
COPY --from=builder /usr/share/licenses/ocserv/ /usr/share/licenses/ocserv/
COPY entrypoint.sh /usr/local/sbin/ocserv-container-entrypoint

RUN set -eux; \
    ldconfig; \
    getent group ocserv >/dev/null || groupadd --system ocserv; \
    id -u ocserv >/dev/null 2>&1 || useradd --system --gid ocserv --home-dir /nonexistent --shell /usr/sbin/nologin ocserv; \
    install -d -m 0750 -o root -g ocserv /etc/ocserv /run/ocserv; \
    chmod 0755 /usr/local/sbin/ocserv-container-entrypoint; \
    /usr/local/sbin/ocserv --version; \
    ! command -v cc; \
    ! command -v gcc; \
    ! command -v make; \
    ! command -v meson; \
    ! command -v ninja; \
    test ! -e /usr/src/ocserv

ENTRYPOINT ["/usr/bin/tini", "-g", "--"]
CMD ["/usr/local/sbin/ocserv-container-entrypoint"]
