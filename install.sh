#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="/opt/waypoint/stack"
DATA_DIR="/opt/waypoint/data"

# -----------------------------
# helpers
# -----------------------------
log() { echo -e "\n[waypoint-installer] $*\n"; }
die() { echo -e "\n[waypoint-installer] ERROR: $*\n" >&2; exit 1; }

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Please run as root (or via sudo): sudo bash install.sh"
  fi
}

ensure_debian() {
  if [[ ! -f /etc/debian_version ]]; then
    die "This installer currently supports Debian-based systems only."
  fi
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

rand_hex() { openssl rand -hex 24 | tr -d '\n'; }

confirm() {
  local prompt="${1:-Are you sure?}"
  local ans
  read -rp "${prompt} [y/N]: " ans
  [[ "${ans}" =~ ^[Yy]$ ]]
}

is_domain_like() {
  [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]] && [[ "$1" == *.* ]]
}

is_slug_like() {
  [[ "$1" =~ ^[a-z0-9]+([a-z0-9-]*[a-z0-9])?$ ]]
}

# -----------------------------
# install deps
# -----------------------------
install_prereqs() {
  log "Installing prerequisites"
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg openssl git
}

install_docker() {
  if command_exists docker; then
    log "Docker already installed"
    return
  fi

  log "Installing Docker Engine + Compose plugin"
  install -m 0755 -d /etc/apt/keyrings

  curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  source /etc/os-release
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
    ${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list

  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

ensure_compose() {
  if docker compose version >/dev/null 2>&1; then
    return
  fi
  die "'docker compose' is not available. Install docker-compose-plugin (or reinstall Docker)."
}

# -----------------------------
# filesystem prep
# -----------------------------
ensure_dirs() {
  log "Creating directories under /opt/waypoint"
  mkdir -p "${STACK_DIR}"
  mkdir -p "${DATA_DIR}/"{mariadb,redis,storage}
  mkdir -p "${DATA_DIR}/storage"/logs
  mkdir -p "${DATA_DIR}/storage"/framework/{cache,sessions,views}
}

maybe_overwrite_existing_stack() {
  if [[ -f "${STACK_DIR}/compose.yml" || -f "${STACK_DIR}/.env" || -f "${STACK_DIR}/Caddyfile" || -f "${STACK_DIR}/nginx.conf" ]]; then
    echo
    echo "Existing stack files detected in ${STACK_DIR}:"
    ls -la "${STACK_DIR}" | sed -n '1,120p' || true
    echo
    confirm "Overwrite existing stack files in ${STACK_DIR}?" || die "Cancelled by user."
  fi
}

# -----------------------------
# prompts (HTTP only)
# -----------------------------
prompt_inputs() {
  clear || true

  cat <<'BANNER'
============================================================
               Welcome to Waypoint Education Installer
============================================================
Installs to:

  /opt/waypoint/stack   (compose.yml, .env, Caddyfile, nginx.conf)
  /opt/waypoint/data    (MariaDB, Redis, Laravel storage)

Mode:
  - HTTP ONLY (no TLS) for now.
============================================================
BANNER

  echo "Tenant details"
  echo

  read -rp "Tenant ID (slug, e.g. parkville-secondary): " TENANT_ID
  [[ -n "${TENANT_ID}" ]] || die "Tenant ID is required."
  is_slug_like "${TENANT_ID}" || die "Tenant ID must be lowercase letters/numbers/hyphens."

  read -rp "Tenant name (display name, e.g. Parkville College): " TENANT_NAME
  [[ -n "${TENANT_NAME}" ]] || die "Tenant name is required."

  read -rp "Subdomain (e.g. waypoint): " TENANT_SUBDOMAIN
  [[ -n "${TENANT_SUBDOMAIN}" ]] || die "Subdomain is required."
  is_slug_like "${TENANT_SUBDOMAIN}" || die "Subdomain must be lowercase letters/numbers/hyphens."

  read -rp "Base domain (e.g. parkvillecollege.vic.edu.au): " TENANT_BASE_DOMAIN
  [[ -n "${TENANT_BASE_DOMAIN}" ]] || die "Base domain is required."
  is_domain_like "${TENANT_BASE_DOMAIN}" || die "Base domain looks invalid: ${TENANT_BASE_DOMAIN}"

  CADDY_DOMAIN="${TENANT_SUBDOMAIN}.${TENANT_BASE_DOMAIN}"
  APP_URL="http://${CADDY_DOMAIN}"

  echo
  echo "Your tenant URL will be:"
  echo "  ${APP_URL}"
  echo

  echo "Database credentials:"
  echo "  A) Auto-generate secure credentials (recommended)"
  echo "  B) I will provide DB username/password"
  echo
  read -rp "Choose [A/B] (default A): " DB_CHOICE
  DB_CHOICE="${DB_CHOICE:-A}"

  DB_DATABASE="waypoint"

  if [[ "${DB_CHOICE}" =~ ^[Bb]$ ]]; then
    read -rp "DB username: " DB_USERNAME
    [[ -n "${DB_USERNAME}" ]] || die "DB username is required."

    read -rsp "DB password (will not echo): " DB_PASSWORD
    echo
    [[ -n "${DB_PASSWORD}" ]] || die "DB password is required."
  else
    DB_USERNAME="waypoint"
    DB_PASSWORD="$(rand_hex)"
  fi

  MYSQL_ROOT_PASSWORD="$(rand_hex)"

  WAYPOINT_APP_IMAGE="ghcr.io/waypointeducation/waypoint:stable"
  APP_ENV="production"
  APP_DEBUG="false"

  DB_CONNECTION="mysql"
  DB_HOST="mariadb"
  DB_PORT="3306"

  REDIS_HOST="redis"
  REDIS_PORT="6379"
  REDIS_CLIENT="phpredis"

  CACHE_DRIVER="redis"
  QUEUE_CONNECTION="redis"
  SESSION_DRIVER="redis"

  # HTTP only
  TLS_MODE="http"
  CADDY_EMAIL=""
  APP_KEY=""
}

show_plan_and_confirm() {
  echo
  echo "------------------------------------------------------------"
  echo "Review configuration"
  echo "------------------------------------------------------------"
  echo "Tenant:"
  echo "  ID:            ${TENANT_ID}"
  echo "  Name:          ${TENANT_NAME}"
  echo "  Domain:        ${CADDY_DOMAIN}"
  echo
  echo "Mode:            HTTP only"
  echo "App URL:         ${APP_URL}"
  echo
  echo "DB database:     ${DB_DATABASE}"
  echo "DB username:     ${DB_USERNAME}"
  echo "DB password:     (hidden)"
  echo
  echo "Install paths:"
  echo "  Stack:         ${STACK_DIR}"
  echo "  Data:          ${DATA_DIR}"
  echo
  echo "Image:"
  echo "  Waypoint:      ${WAYPOINT_APP_IMAGE}"
  echo "------------------------------------------------------------"
  echo

  confirm "Proceed with installation?" || die "Cancelled by user."
}

# -----------------------------
# write stack files (INLINE, NO DOWNLOADS)
# -----------------------------
write_stack_files() {
  log "Writing stack files"

  cat > "${STACK_DIR}/compose.yml" <<'YAML'
services:
  waypoint-app:
    image: ${WAYPOINT_APP_IMAGE}
    env_file:
      - .env
    depends_on:
      mariadb:
        condition: service_healthy
      redis:
        condition: service_started
    volumes:
      - /opt/waypoint/data/storage:/var/www/html/storage
    restart: unless-stopped

  waypoint-web:
    image: ${WAYPOINT_APP_IMAGE}
    depends_on:
      - waypoint-app
    # Run nginx in the same image, but with OUR nginx.conf
    command: ["nginx", "-g", "daemon off;"]
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
      - /opt/waypoint/data/storage:/var/www/html/storage
    restart: unless-stopped

  waypoint-queue:
    image: ${WAYPOINT_APP_IMAGE}
    env_file:
      - .env
    depends_on:
      mariadb:
        condition: service_healthy
      redis:
        condition: service_started
    volumes:
      - /opt/waypoint/data/storage:/var/www/html/storage
    command: ["php", "artisan", "queue:work", "--sleep=1", "--tries=1"]
    restart: unless-stopped

  waypoint-scheduler:
    image: ${WAYPOINT_APP_IMAGE}
    env_file:
      - .env
    depends_on:
      mariadb:
        condition: service_healthy
      redis:
        condition: service_started
    volumes:
      - /opt/waypoint/data/storage:/var/www/html/storage
    command: ["sh", "-lc", "while true; do php artisan schedule:run --no-interaction; sleep 60; done"]
    restart: unless-stopped

  mariadb:
    image: mariadb:11
    environment:
      MARIADB_DATABASE: ${DB_DATABASE}
      MARIADB_USER: ${DB_USERNAME}
      MARIADB_PASSWORD: ${DB_PASSWORD}
      MARIADB_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
    volumes:
      - /opt/waypoint/data/mariadb:/var/lib/mysql
    healthcheck:
      test: ["CMD-SHELL", "mariadb-admin ping -h 127.0.0.1 -p$${MARIADB_ROOT_PASSWORD} --silent"]
      interval: 5s
      timeout: 3s
      retries: 30
    restart: unless-stopped

  redis:
    image: redis:7-alpine
    volumes:
      - /opt/waypoint/data/redis:/data
    restart: unless-stopped

  caddy:
    image: caddy:2-alpine
    ports:
      - "80:80"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    depends_on:
      - waypoint-web
    restart: unless-stopped

volumes:
  caddy_data:
  caddy_config:
YAML

  # Full nginx.conf (NOT a conf.d snippet) so "server" is always valid
  cat > "${STACK_DIR}/nginx.conf" <<'NGINX'
worker_processes auto;
pid /tmp/nginx.pid;

events {
  worker_connections 1024;
}

http {
  include       /etc/nginx/mime.types;
  default_type  application/octet-stream;

  access_log /dev/stdout;
  error_log  /dev/stderr warn;

  sendfile on;
  keepalive_timeout 65;

  client_body_temp_path /tmp/client_temp;
  proxy_temp_path       /tmp/proxy_temp;
  fastcgi_temp_path     /tmp/fastcgi_temp;
  uwsgi_temp_path       /tmp/uwsgi_temp;
  scgi_temp_path        /tmp/scgi_temp;

  server {
    listen 8080;
    server_name _;

    root /var/www/html/public;
    index index.php;

    # Serve built assets directly (correct MIME types + no Laravel HTML fallback)
    location ^~ /build/ {
      access_log off;
      expires 7d;
      add_header Cache-Control "public, max-age=604800, immutable";
      try_files $uri =404;
    }

    # Serve common static files directly
    location ~* \.(?:css|js|mjs|map|png|jpg|jpeg|gif|svg|webp|ico|ttf|otf|woff|woff2)$ {
      access_log off;
      expires 7d;
      add_header Cache-Control "public, max-age=604800";
      try_files $uri =404;
    }

    location / {
      try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
      include fastcgi_params;
      fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
      fastcgi_param DOCUMENT_ROOT $document_root;
      fastcgi_param HTTP_HOST $host;
      fastcgi_pass waypoint-app:9000;
    }

    client_max_body_size 50m;
  }
}
NGINX

  # Caddy HTTP only, no redirects
  cat > "${STACK_DIR}/Caddyfile" <<CADDY
{
  auto_https off
}

:80 {
  reverse_proxy waypoint-web:8080
}
CADDY

  # Write a COMPLETE .env so DB_PASSWORD is never blank
  cat > "${STACK_DIR}/.env" <<EOF
WAYPOINT_APP_IMAGE=${WAYPOINT_APP_IMAGE}

APP_ENV=${APP_ENV}
APP_DEBUG=${APP_DEBUG}
APP_URL=${APP_URL}
APP_KEY=

DB_CONNECTION=${DB_CONNECTION}
DB_HOST=${DB_HOST}
DB_PORT=${DB_PORT}
DB_DATABASE=${DB_DATABASE}
DB_USERNAME=${DB_USERNAME}
DB_PASSWORD=${DB_PASSWORD}
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}

REDIS_HOST=${REDIS_HOST}
REDIS_PORT=${REDIS_PORT}
REDIS_CLIENT=${REDIS_CLIENT}

CACHE_DRIVER=${CACHE_DRIVER}
QUEUE_CONNECTION=${QUEUE_CONNECTION}
SESSION_DRIVER=${SESSION_DRIVER}

CADDY_EMAIL=
CADDY_DOMAIN=${CADDY_DOMAIN}
TLS_MODE=http

TENANT_ID=${TENANT_ID}
TENANT_NAME=${TENANT_NAME}
TENANT_SUBDOMAIN=${TENANT_SUBDOMAIN}
TENANT_BASE_DOMAIN=${TENANT_BASE_DOMAIN}
EOF

  chmod 600 "${STACK_DIR}/.env"
}

# -----------------------------
# bring up stack + init
# -----------------------------
compose_up() {
  log "Starting services"
  cd "${STACK_DIR}"
  docker compose pull
  docker compose up -d
}

detect_and_set_storage_perms() {
  log "Fixing Laravel storage permissions (auto-detect container UID/GID)"
  cd "${STACK_DIR}"

  local uid gid
  uid="$(docker compose exec -T waypoint-app id -u)"
  gid="$(docker compose exec -T waypoint-app id -g)"

  [[ -n "${uid}" && -n "${gid}" ]] || die "Could not detect container uid/gid."

  chown -R "${uid}:${gid}" "${DATA_DIR}/storage" || true
  chmod -R ug+rwX "${DATA_DIR}/storage" || true
  find "${DATA_DIR}/storage" -type d -exec chmod g+s {} \; || true
}

generate_app_key_in_container() {
  log "Generating APP_KEY inside container and writing it to host .env"
  cd "${STACK_DIR}"

  local key
  key="$(docker compose exec -T waypoint-app php -r "echo 'base64:'.base64_encode(random_bytes(32)).PHP_EOL;")"
  [[ -n "${key}" ]] || die "Failed to generate APP_KEY."

  sed -i "s|^APP_KEY=.*$|APP_KEY=${key}|" "${STACK_DIR}/.env"
  docker compose up -d
}

run_migrations() {
  log "Running central migrations"
  cd "${STACK_DIR}"
  docker compose exec -T waypoint-app php artisan migrate --force
}

create_first_tenant() {
  log "Creating initial tenant (${TENANT_ID}) and running tenant migrations"
  cd "${STACK_DIR}"

  docker compose exec -T waypoint-app php artisan make:tenant "${TENANT_ID}" \
    --name="${TENANT_NAME}" \
    --subdomain="${TENANT_SUBDOMAIN}" \
    --base-domain="${TENANT_BASE_DOMAIN}" \
    --migrate
}

print_summary() {
  log "Install complete"
  echo "Tenant URL: ${APP_URL}"
  echo
  echo "Tenant:"
  echo "  ID:        ${TENANT_ID}"
  echo "  Name:      ${TENANT_NAME}"
  echo "  Domain:    ${CADDY_DOMAIN}"
  echo
  echo "Database:"
  echo "  DB_DATABASE=${DB_DATABASE}"
  echo "  DB_USERNAME=${DB_USERNAME}"
  echo "  DB_PASSWORD=${DB_PASSWORD}"
  echo
  echo "Next:"
  echo "  1) Browse to: ${APP_URL}"
  echo "  2) Admin commands:"
  echo "     cd ${STACK_DIR} && docker compose exec waypoint-app php artisan <command>"
  echo
  echo "NOTE:"
  echo "  This installer deploys HTTP only."
}

main() {
  require_root
  ensure_debian
  install_prereqs
  install_docker
  ensure_compose
  ensure_dirs

  prompt_inputs
  show_plan_and_confirm
  maybe_overwrite_existing_stack

  write_stack_files
  compose_up
  detect_and_set_storage_perms
  generate_app_key_in_container
  run_migrations
  create_first_tenant
  print_summary
}

main "$@"
