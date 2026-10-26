# syntax=docker/dockerfile:1

# frappe_docker v4.1.1 images/custom/Containerfile, with frappe pinned to a
# Pressingly/frappe commit and erpnext installed from this build context
# instead of an apps.json clone. Runtime scripts: docker/resources (see NOTICE).

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
    && pip3 install frappe-bench \
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

# Build-time by nature: frappe is compiled into the image. The commit is the
# pin, so this erpnext commit alone identifies the image; ship a frappe change
# by bumping FRAPPE_COMMIT in a commit here. It must carry frappe.mpass_sso.
ARG FRAPPE_REPO=https://github.com/Pressingly/frappe
ARG FRAPPE_COMMIT=9e568dbde508beb773dcc8dd02365cd82ea16654

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

COPY --chown=frappe:0 . apps/erpnext

# What bench get-app does after its clone: editable install, node packages,
# apps.txt/apps.json registration. Then one build for every app, as bench init.
RUN uv pip install --quiet -e apps/erpnext --python env/bin/python && \
  (cd apps/erpnext && yarn install --check-files) && \
  python3 -c 'from bench.bench import Bench; Bench(".").apps.sync(app_name="erpnext")' && \
  bench build && \
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
