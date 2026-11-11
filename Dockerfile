# syntax=docker/dockerfile:1

# Adapted from frappe_docker v4.1.1 images/custom/Containerfile (MIT, see
# docker/resources/NOTICE): frappe pinned to a Pressingly/frappe commit and
# erpnext installed from this build context instead of an apps.json clone.

ARG PYTHON_VERSION=3.14
ARG DEBIAN_BASE=trixie
FROM python:${PYTHON_VERSION}-slim-${DEBIAN_BASE} AS base

COPY docker/resources/core/nginx/nginx-template.conf /templates/nginx/frappe.conf.template
COPY docker/resources/core/nginx/nginx-entrypoint.sh /usr/local/bin/nginx-entrypoint.sh
COPY docker/resources/core/nginx/security_headers.conf /etc/nginx/snippets/security_headers.conf

ARG WKHTMLTOPDF_VERSION=0.12.6.1-3
ARG WKHTMLTOPDF_DISTRO=bookworm
ARG INSTALL_CHROMIUM=true

ARG NODE_VERSION=24

# Build tool version, the same for every deployment. Pinned because the builder
# calls bench's internal apps.sync, checked against this release.
ARG FRAPPE_BENCH_VERSION=5.31.1

ENV NVM_DIR=/home/frappe/.nvm
ENV NVM_SYMLINK_CURRENT=true
ENV PATH=${NVM_DIR}/current/bin/:${PATH}

RUN useradd -u 1000 -g 0 -d /home/frappe -ms /bin/bash frappe \
    && apt-get update \
    && apt-get install --no-install-recommends -y \
    ca-certificates \
    curl \
    git \
    vim \
    nginx \
    gettext-base \
    file \
    # weasyprint dependencies
    libpango-1.0-0 \
    libharfbuzz0b \
    libpangoft2-1.0-0 \
    libpangocairo-1.0-0 \
    # For backups
    restic \
    gpg \
    # MariaDB
    mariadb-client \
    less \
    # Postgres
    libpq-dev \
    postgresql-client \
    # For healthcheck
    wait-for-it \
    jq \
    # For MIME type detection
    media-types \
    && . /etc/os-release \
    && if [ "$VERSION_CODENAME" = "trixie" ]; then \
        apt-get install --no-install-recommends -y tzdata-legacy; \
    fi \
    # NodeJS
    && mkdir -p ${NVM_DIR} \
    && curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.6/install.sh | bash \
    && . ${NVM_DIR}/nvm.sh \
    && nvm install ${NODE_VERSION} \
    && nvm use ${NODE_VERSION} \
    && npm install -g yarn \
    && corepack enable pnpm \
    && nvm alias default ${NODE_VERSION} \
    && rm -rf ${NVM_DIR}/.cache \
    && echo 'export NVM_DIR="/home/frappe/.nvm"' >>/home/frappe/.bashrc \
    && echo '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm' >>/home/frappe/.bashrc \
    && echo '[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion' >>/home/frappe/.bashrc \
    # Install wkhtmltopdf with patched qt
    && if [ "$(uname -m)" = "aarch64" ]; then export ARCH=arm64; fi \
    && if [ "$(uname -m)" = "x86_64" ]; then export ARCH=amd64; fi \
    && downloaded_file=wkhtmltox_${WKHTMLTOPDF_VERSION}.${WKHTMLTOPDF_DISTRO}_${ARCH}.deb \
    && curl -sLO https://github.com/wkhtmltopdf/packaging/releases/download/$WKHTMLTOPDF_VERSION/$downloaded_file \
    && apt-get install -y ./$downloaded_file \
    && rm $downloaded_file \
    # Chromium
    && if [ "$INSTALL_CHROMIUM" != "false" ]; then \
        DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
        chromium-headless-shell; \
    fi \
    # Clean up
    && rm -rf /var/lib/apt/lists/* \
    && rm -fr /etc/nginx/sites-enabled/default \
    && mkdir -p /etc/nginx/snippets \
    && pip3 install frappe-bench==${FRAPPE_BENCH_VERSION} \
    # Fixes for non-root nginx and logs to stdout
    && sed -i '/user www-data/d' /etc/nginx/nginx.conf \
    && ln -sf /dev/stdout /var/log/nginx/access.log && ln -sf /dev/stderr /var/log/nginx/error.log \
    && touch /run/nginx.pid \
    # OpenShift and arbitrary UID compatibility (GID 0 & group writable)
    && chgrp -R 0 /home/frappe /etc/nginx /var/log/nginx /var/lib/nginx /run \
    && chmod -R g=u /home/frappe /etc/nginx /var/log/nginx /var/lib/nginx /run \
    && chmod 755 /usr/local/bin/nginx-entrypoint.sh \
    && chmod 644 /templates/nginx/frappe.conf.template


FROM base AS builder

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
    # For frappe framework
    wget \
    #for building arm64 binaries
    libcairo2-dev \
    libpango1.0-dev \
    libjpeg-dev \
    libgif-dev \
    librsvg2-dev \
    # For psycopg2
    libpq-dev \
    # Other
    libffi-dev \
    liblcms2-dev \
    libldap2-dev \
    libmariadb-dev \
    libsasl2-dev \
    libtiff-dev \
    libwebp-dev \
    pkg-config \
    redis-tools \
    rlwrap \
    tk8.6-dev \
    cron \
    # For pandas
    gcc \
    build-essential \
    libbz2-dev \
    && rm -rf /var/lib/apt/lists/*

USER frappe

# Build-time by nature: frappe is installed into the image. FRAPPE_COMMIT pins
# the frappe source; ship a frappe change by bumping it in a commit here. It
# must carry frappe.mpass_sso.
ARG FRAPPE_REPO=https://github.com/Pressingly/frappe
ARG FRAPPE_COMMIT=375bff60d05763cc435350f8f3b3755d68d8cf4a

# bench init only clones branches and tags, so it gets the pinned commit from
# a local checkout. The directory name becomes the app name.
RUN git init --quiet /home/frappe/src/frappe \
  && git -C /home/frappe/src/frappe fetch --quiet --depth 1 "${FRAPPE_REPO}" "${FRAPPE_COMMIT}" \
  && git -C /home/frappe/src/frappe checkout --quiet -b pinned FETCH_HEAD \
  && if [ ! -f /home/frappe/src/frappe/frappe/mpass_sso.py ]; then \
    echo "ERROR: frappe ${FRAPPE_COMMIT} has no frappe/mpass_sso.py; pin a Pressingly/frappe commit that carries the mPass SSO layer." >&2; \
    exit 1; \
  fi

RUN bench init \
    --frappe-path=/home/frappe/src/frappe \
    --frappe-branch=pinned \
    --no-procfile \
    --no-backups \
    --skip-redis-config-generation \
    --skip-assets \
    --verbose \
    /home/frappe/frappe-bench && \
  rm -rf /home/frappe/src

WORKDIR /home/frappe/frappe-bench

# Build-time by nature: HRMS is installed into the image from the
# Pressingly/hrms fork at a pinned commit; ship an hrms change by bumping it
# here. Once a site has it installed, every later image must carry it, and
# HRMS_COMMIT moves with FRAPPE_COMMIT and erpnext on one release line.
ARG HRMS_REPO=https://github.com/Pressingly/hrms
ARG HRMS_COMMIT=c8796fae6d2c2d660b75911f85fcb7e57338fea7

RUN git init --quiet apps/hrms \
  && git -C apps/hrms fetch --quiet --depth 1 "${HRMS_REPO}" "${HRMS_COMMIT}" \
  && git -C apps/hrms checkout --quiet FETCH_HEAD

# Build-time by nature: Frappe CRM ships in the image from the Pressingly/crm
# fork at a pinned commit, but is optional: the bundle's erpnext-init installs
# it only on deployments that opt in. Once any site installs it, every later
# image must carry it. CRM_COMMIT moves with FRAPPE_COMMIT on the same release
# line as HRMS_COMMIT.
ARG CRM_REPO=https://github.com/Pressingly/crm
ARG CRM_COMMIT=19786bf033b62c9e686713234ca54d10f612a8af

RUN git init --quiet apps/crm \
  && git -C apps/crm fetch --quiet --depth 1 "${CRM_REPO}" "${CRM_COMMIT}" \
  && git -C apps/crm checkout --quiet FETCH_HEAD

# Build-time by nature: Raven ships in the image from the Pressingly/raven fork
# at a pinned commit and is optional the same way as CRM: erpnext-init installs
# it only where a deployment opts in, and once a site has it every later image
# must carry it. RAVEN_COMMIT moves with FRAPPE_COMMIT on the same release line.
ARG RAVEN_REPO=https://github.com/Pressingly/raven
ARG RAVEN_COMMIT=5a5e4c48e477831d82943ba241e20cc9fb6ce578

RUN git init --quiet apps/raven \
  && git -C apps/raven fetch --quiet --depth 1 "${RAVEN_REPO}" "${RAVEN_COMMIT}" \
  && git -C apps/raven checkout --quiet FETCH_HEAD

COPY --chown=frappe:0 . apps/erpnext

# What bench get-app does after its clone: editable install, node packages,
# apps.txt/apps.json registration. Then one build for every app, as bench init;
# it runs each app's own `yarn build` too, which builds the HRMS PWA and roster
# and the CRM and Raven SPAs.
# Their node_modules are build-only (about 740 MB) and stay out of the image.
RUN for app in erpnext hrms crm raven; do \
    uv pip install --quiet -e "apps/${app}" --python env/bin/python && \
    (cd "apps/${app}" && yarn install --check-files) && \
    python3 -c "from bench.bench import Bench; Bench('.').apps.sync(app_name='${app}')" \
    || exit 1; \
  done && \
  bench build && \
  rm -rf apps/hrms/frontend/node_modules apps/hrms/roster/node_modules \
    apps/crm/node_modules apps/crm/frontend/node_modules \
    apps/raven/node_modules apps/raven/apps/*/node_modules apps/raven/packages/*/node_modules && \
  echo "{}" > sites/common_site_config.json && \
  find apps -mindepth 1 -path "*/.git" | xargs rm -fr && \
  chmod -R g=u /home/frappe/frappe-bench

FROM base AS backend

USER frappe

COPY --from=builder --chown=frappe:0 /home/frappe/frappe-bench /home/frappe/frappe-bench

WORKDIR /home/frappe/frappe-bench

# Keep the COPY destination group-writable and move assets to image-layer storage
RUN chmod g=u /home/frappe/frappe-bench && \
  cp -r /home/frappe/frappe-bench/sites/assets /home/frappe/frappe-bench/assets && \
  rm -rf /home/frappe/frappe-bench/sites/assets

VOLUME [ \
  "/home/frappe/frappe-bench/sites", \
  "/home/frappe/frappe-bench/logs" \
]

USER root
# This entrypoint script link build assets of the image to the mounted sites volume at container initialization
COPY docker/resources/core/main-entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 755 /usr/local/bin/entrypoint.sh

COPY docker/resources/core/start.sh /usr/local/bin/start.sh
RUN chmod 755 /usr/local/bin/start.sh

USER frappe
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

CMD ["start.sh"]
