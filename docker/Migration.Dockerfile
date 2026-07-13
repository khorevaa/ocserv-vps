ARG SOURCE_IMAGE
FROM ${SOURCE_IMAGE}

LABEL org.opencontainers.image.source="https://github.com/khorevaa/ocserv-vps" \
      org.opencontainers.image.description="Dockerized ocserv migrated to the standalone ocserv-vps product repository"
