#
# nginx-proxy-manager Dockerfile
#
# https://github.com/jlesage/docker-nginx-proxy-manager
#

# Docker image version is provided via build arg.
ARG DOCKER_IMAGE_VERSION=

# Define software versions.
ARG OPENRESTY_VERSION=1.27.1.2
ARG NGINX_PROXY_MANAGER_VERSION=2.15.1
ARG NGINX_HTTP_GEOIP2_MODULE_VERSION=3.3
ARG LIBMAXMINDDB_VERSION=1.5.0
ARG BCRYPT_TOOL_VERSION=1.1.2
ARG CERTBOT_VERSION=5.3.1
ARG CROWDSEC_OPENRESTY_BOUNCER_VERSION=1.1.0

# Define software download URLs.
ARG OPENRESTY_URL=https://openresty.org/download/openresty-${OPENRESTY_VERSION}.tar.gz
ARG CROWDSEC_OPENRESTY_BOUNCER_URL=https://github.com/crowdsecurity/cs-openresty-bouncer/releases/download/v${CROWDSEC_OPENRESTY_BOUNCER_VERSION}/crowdsec-openresty-bouncer.tgz
ARG NGINX_PROXY_MANAGER_URL=https://github.com/jc21/nginx-proxy-manager/archive/v${NGINX_PROXY_MANAGER_VERSION}.tar.gz
ARG NGINX_HTTP_GEOIP2_MODULE_URL=https://github.com/leev/ngx_http_geoip2_module/archive/${NGINX_HTTP_GEOIP2_MODULE_VERSION}.tar.gz
ARG LIBMAXMINDDB_URL=https://github.com/maxmind/libmaxminddb/releases/download/${LIBMAXMINDDB_VERSION}/libmaxminddb-${LIBMAXMINDDB_VERSION}.tar.gz

# Get Dockerfile cross-compilation helpers.
FROM --platform=$BUILDPLATFORM tonistiigi/xx AS xx

# Get UPX (statically linked).
# NOTE: UPX 5.x is not compatible with old kernels, e.g. 3.10 used by some
#       Synology NASes. See https://github.com/upx/upx/issues/902
FROM --platform=$BUILDPLATFORM alpine:3.23 AS upx
ARG UPX_VERSION=4.2.4
RUN apk --no-cache add curl && \
    mkdir /tmp/upx && \
    curl -# -L https://github.com/upx/upx/releases/download/v${UPX_VERSION}/upx-${UPX_VERSION}-amd64_linux.tar.xz | tar xJ --strip 1 -C /tmp/upx && \
    cp -v /tmp/upx/upx /usr/bin/upx

# Build Nginx Proxy Manager.
FROM --platform=$BUILDPLATFORM alpine:3.23 AS npm
ARG TARGETPLATFORM
ARG NGINX_PROXY_MANAGER_VERSION
ARG NGINX_PROXY_MANAGER_URL
COPY --from=xx / /
COPY src/nginx-proxy-manager /build
RUN /build/build.sh "$NGINX_PROXY_MANAGER_VERSION" "$NGINX_PROXY_MANAGER_URL"

# Build OpenResty (nginx).
FROM --platform=$BUILDPLATFORM alpine:3.23 AS nginx
ARG TARGETPLATFORM
ARG OPENRESTY_URL
ARG NGINX_HTTP_GEOIP2_MODULE_URL
ARG LIBMAXMINDDB_URL
COPY --from=xx / /
COPY src/openresty /build
RUN /build/build.sh "$OPENRESTY_URL" "$NGINX_HTTP_GEOIP2_MODULE_URL" "$LIBMAXMINDDB_URL"
RUN xx-verify /tmp/openresty-install/usr/sbin/nginx

# Build bcrypt-tool.
FROM --platform=$BUILDPLATFORM alpine:3.23 AS bcrypt-tool
ARG TARGETPLATFORM
ARG BCRYPT_TOOL_VERSION
COPY --from=xx / /
COPY src/bcrypt-tool /build
RUN /build/build.sh "$BCRYPT_TOOL_VERSION"
RUN xx-verify /tmp/go/bin/bcrypt-tool
COPY --from=upx /usr/bin/upx /usr/bin/upx
RUN upx /tmp/go/bin/bcrypt-tool

# Build certbot and its plugins.
FROM alpine:3.23 AS certbot
ARG TARGETPLATFORM
ARG CERTBOT_VERSION
COPY --from=npm /tmp/nginx-proxy-manager-install/opt/nginx-proxy-manager/certbot/dns-plugins.json /build/
COPY src/certbot /build
RUN /build/build.sh "$CERTBOT_VERSION" /build/dns-plugins.json

# Build cs-openresty-boucner.
FROM alpine:3.23 AS cs-openresty-bouncer
ARG TARGETPLATFORM
ARG CROWDSEC_OPENRESTY_BOUNCER_URL
COPY --from=xx / /
COPY src/cs-openresty-bouncer /build
RUN /build/build.sh "$CROWDSEC_OPENRESTY_BOUNCER_URL"

# Pull base image.
FROM jlesage/baseimage:alpine-3.23-v3.10.5

ARG NGINX_PROXY_MANAGER_VERSION
ARG DOCKER_IMAGE_VERSION

# Define working directory.
WORKDIR /tmp

# Install dependencies.
RUN \
    add-pkg \
        curl \
        nodejs \
        python3 \
        sqlite \
        openssl \
        # For CrowdSec bouncer init script.
        bash \
        # For openresty.
        pcre \
        luajit \
        && \
    true

# Add files.
COPY rootfs/ /
COPY --from=nginx /tmp/openresty-install/ /
COPY --from=npm /tmp/nginx-proxy-manager-install/ /
COPY --from=bcrypt-tool /tmp/go/bin/bcrypt-tool /usr/bin/
COPY --from=certbot /opt/certbot /opt/certbot
COPY --from=certbot /tmp/certbot-symlinks /usr/local/bin
COPY --from=cs-openresty-bouncer /tmp/crowdsec-openresty-bouncer-install/ /

# Set internal environment variables.
RUN \
    set-cont-env APP_NAME "Nginx Proxy Manager" && \
    set-cont-env APP_VERSION "$NGINX_PROXY_MANAGER_VERSION" && \
    set-cont-env DOCKER_IMAGE_VERSION "$DOCKER_IMAGE_VERSION" && \
    # The Synology build-context filesystem (ACL-backed) makes COPY drop the
    # group/other read bit on everything under rootfs/ (files land as 0711),
    # which breaks the jlesage init two ways: executable data-files get exec'd
    # (DB_SQLITE_FILE crash-loop, nginx.dep -> "command failed (126)"), and
    # scripts run by the non-root app user (startapp.sh, bin/ helpers) can't be
    # read -> "Permission denied". Restore the exact git-tracked modes for the
    # files we ship; base-image files keep theirs. No-op on a normal CI build.
    chmod 755 /etc/cont-env.d /etc/cont-init.d /etc/services.d \
              /etc/services.d/app /etc/services.d/cert_cleanup \
              /etc/services.d/default /etc/services.d/nginx \
              /opt/nginx-proxy-manager/bin \
              /etc/cont-env.d/DEBUG \
              /etc/cont-init.d/54-db-upgrade.sh \
              /etc/cont-init.d/55-nginx-proxy-manager.sh \
              /etc/cont-init.d/99_crowdsec-openresty-bouncer.sh \
              /opt/nginx-proxy-manager/bin/handle-ipv6-setting \
              /opt/nginx-proxy-manager/bin/lecleaner \
              /opt/nginx-proxy-manager/bin/mysql2sqlite \
              /opt/nginx-proxy-manager/bin/reset-password \
              /startapp.sh && \
    chmod 644 /etc/cont-env.d/DB_SQLITE_FILE \
              /etc/cont-env.d/PYTHONPYCACHEPREFIX \
              /etc/services.d/app/nginx.dep \
              /etc/services.d/cert_cleanup/interval \
              /etc/services.d/default/cert_cleanup.dep \
              /etc/services.d/nginx/respawn && \
    true

# Set public environment variables.
ENV \
    DISABLE_IPV6=0 \
    DISABLE_RESOLVER=0 \
    IP_RANGES_FETCH_ENABLED=1

# Expose ports.
#   - 8080: HTTP traffic
#   - 4443: HTTPs traffic
#   - 8181: Management web interface
EXPOSE 8080 4443 8181

# Metadata.
LABEL \
      org.label-schema.name="nginx-proxy-manager" \
      org.label-schema.description="Docker container for Nginx Proxy Manager" \
      org.label-schema.version="${DOCKER_IMAGE_VERSION:-unknown}" \
      org.label-schema.vcs-url="https://github.com/jlesage/docker-nginx-proxy-manager" \
      org.label-schema.schema-version="1.0"
