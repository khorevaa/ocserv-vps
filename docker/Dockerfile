ARG BASE_IMAGE=alpine:3.23@sha256:fd791d74b68913cbb027c6546007b3f0d3bc45125f797758156952bc2d6daf40

FROM ${BASE_IMAGE} AS builder

RUN set -eux; \
    apk add --no-cache \
      autoconf automake build-base busybox-static gettext-dev gperf libtool \
      gnutls-dev lddtree libev-dev libseccomp-dev linux-headers meson ninja \
      pkgconf protobuf-c-compiler protobuf-c-dev readline-dev \
      talloc-dev tini-static

COPY source /usr/src/ocserv

RUN set -eux; \
    cd /usr/src/ocserv; \
    if [ -f meson.build ]; then \
      meson setup /tmp/ocserv-build . \
        --prefix=/usr/local \
        --buildtype=release \
        --strip \
        --wrap-mode=nodownload \
        -Db_lto=true \
        -Dpam=disabled \
        -Dradius=disabled \
        -Dgssapi=disabled \
        -Dliboath=disabled \
        -Dlibnl=disabled \
        -Dmaxmind=disabled \
        -Dgeoip=disabled \
        -Dlz4=disabled \
        -Dcompression=disabled \
        -Dseccomp=enabled \
        -Dsystemd=disabled \
        -Doidc-auth=disabled \
        -Dutmp=disabled \
        -Dlibwrap=disabled \
        -Dpager=; \
      meson compile -C /tmp/ocserv-build; \
      meson install -C /tmp/ocserv-build --no-rebuild; \
    else \
      if [ ! -x ./configure ]; then autoreconf -fiv; fi; \
      mkdir -p /tmp/ocserv-build; \
      cd /tmp/ocserv-build; \
      /usr/src/ocserv/configure \
        --prefix=/usr/local \
        --disable-pam \
        --disable-radius \
        --disable-gssapi \
        --disable-oath \
        --disable-lz4 \
        --disable-compression; \
      make -j"$(nproc)"; \
      make install-strip; \
    fi; \
    /usr/local/sbin/ocserv --version; \
    install -d -m 0755 /runtime/usr/local /runtime/usr/share/licenses/ocserv; \
    cp -a /usr/local/. /runtime/usr/local/; \
    if [ -f /usr/src/ocserv/COPYING ]; then \
      cp /usr/src/ocserv/COPYING /runtime/usr/share/licenses/ocserv/COPYING; \
    fi; \
    { \
      find /usr/local -type f -perm -0100 | while IFS= read -r executable; do \
        lddtree -l "${executable}"; \
      done; \
    } | sort -u | while IFS= read -r library; do \
      case "${library}" in \
        /usr/local/*|'') continue ;; \
      esac; \
      test -f "${library}" || continue; \
      install -d "/runtime$(dirname "${library}")"; \
      cp -L "${library}" "/runtime${library}"; \
    done; \
    install -d -m 0755 \
      /runtime/bin /runtime/etc /runtime/run/ocserv /runtime/sbin \
      /runtime/tmp /runtime/usr/bin; \
    chmod 1777 /runtime/tmp; \
    cp /bin/busybox.static /runtime/bin/busybox; \
    for applet in awk chmod cp date dirname grep install mkdir mv rmdir sh sleep sort tail wc; do \
      ln -s busybox "/runtime/bin/${applet}"; \
    done; \
    ln -s ../../bin/busybox /runtime/usr/bin/env; \
    cp /sbin/tini-static /runtime/sbin/tini; \
    loader="$(find /runtime/lib -maxdepth 1 -name 'ld-musl-*.so.1' -print -quit)"; \
    test -n "${loader}"; \
    ln -s "../../lib/${loader##*/}" /runtime/usr/bin/ldd; \
    printf '%s\n' \
      'root:x:0:0:root:/root:/sbin/nologin' \
      'ocserv:x:100:100:ocserv:/nonexistent:/sbin/nologin' \
      > /runtime/etc/passwd; \
    printf '%s\n' \
      'root:x:0:' \
      'ocserv:x:100:' \
      > /runtime/etc/group; \
    printf '%s\n' 'nameserver 127.0.0.11' > /runtime/etc/resolv.conf; \
    chmod 0755 /runtime/bin/busybox /runtime/sbin/tini; \
    find /runtime/usr/local -type f -exec strip --strip-unneeded '{}' + 2>/dev/null || true; \
    test -x /runtime/usr/local/sbin/ocserv; \
    test -x /runtime/usr/local/bin/occtl; \
    test -x /runtime/usr/local/bin/ocpasswd

FROM scratch AS runtime

ARG BASE_IMAGE
ARG OCSERV_VERSION
ARG SOURCE_SHA256

LABEL org.opencontainers.image.title="ocserv-vps" \
      org.opencontainers.image.description="Minimal ocserv runtime built from a verified upstream source release" \
      org.opencontainers.image.source="https://github.com/khorevaa/ocserv-vps" \
      org.opencontainers.image.licenses="GPL-2.0-or-later" \
      org.opencontainers.image.version="${OCSERV_VERSION}" \
      org.opencontainers.image.base.name="${BASE_IMAGE}" \
      org.ocserv-vps.source-sha256="${SOURCE_SHA256}"

ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

COPY --from=builder /runtime /
COPY --chmod=0755 entrypoint.sh /usr/local/sbin/ocserv-container-entrypoint

ENTRYPOINT ["/sbin/tini", "-g", "--"]
CMD ["/usr/local/sbin/ocserv-container-entrypoint"]
