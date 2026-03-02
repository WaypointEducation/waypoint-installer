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

dns_resolves() {
  local host="$1"
  getent ahosts "$host" >/dev/null 2>&1
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
# config / prompts
# -----------------------------
prompt_inputs() {
  clear || true

  cat <<'BANNER'
============================================================
               Welcome to Waypoint Education Installer
============================================================
This will install the Waypoint Education stack to:

  /opt/waypoint/stack   (compose.yml, .env, Caddyfile, nginx.conf)
  /opt/waypoint/data    (MariaDB, Redis, app storage)

Components:
  - Waypoint Education app (php-fpm)
  - Nginx (serves HTTP + PHP -> php-fpm)
  - MariaDB
  - Redis
  - Caddy (reverse proxy)

You will be asked for:
  - Tenant details (tenant id, name, subdomain, base domain)
  - TLS mode (Let's Encrypt / Internal TLS / HTTP)
  - Database credentials (auto-generate or custom)

Notes:
  - Waypoint is tenant-first. This installer will create your first tenant
    and map it to: <subdomain>.<base-domain>
============================================================

BANNER

  echo "Tenant details"
  echo

  read -rp "Tenant ID (slug, e.g. parkville-secondary): " TENANT_ID
  [[ -n "${TENANT_ID}" ]] || die "Tenant ID is required."
  is_slug_like "${TENANT_ID}" || die "Tenant ID must be lowercase letters/numbers/hyphens."

  read -rp "Tenant name (display name, e.g. Parkville Secondary): " TENANT_NAME
  [[ -n "${TENANT_NAME}" ]] || die "Tenant name is required."

  read -rp "Subdomain (e.g. parkville): " TENANT_SUBDOMAIN
  [[ -n "${TENANT_SUBDOMAIN}" ]] || die "Subdomain is required."
  is_slug_like "${TENANT_SUBDOMAIN}" || die "Subdomain must be lowercase letters/numbers/hyphens."

  read -rp "Base domain (e.g. parkvillecollege.vic.edu.au): " TENANT_BASE_DOMAIN
  [[ -n "${TENANT_BASE_DOMAIN}" ]] || die "Base domain is required."
  is_domain_like "${TENANT_BASE_DOMAIN}" || die "Base domain looks invalid: ${TENANT_BASE_DOMAIN}"

  CADDY_DOMAIN="${TENANT_SUBDOMAIN}.${TENANT_BASE_DOMAIN}"

  echo
  echo "Your tenant URL will be:"
  echo "  ${CADDY_DOMAIN}"
  echo

  echo "TLS mode:"
  echo "  1) Let's Encrypt (production)  - requires public DNS + ports 80/443 reachable"
  echo "  2) Internal TLS (local)        - self-signed by Caddy (browser will warn)"
  echo "  3) HTTP only (local)           - no TLS"
  echo
  read -rp "Choose TLS mode [1/2/3] (default 2): " TLS_CHOICE
  TLS_CHOICE="${TLS_CHOICE:-2}"

  case "${TLS_CHOICE}" in
    1)
      TLS_MODE="letsencrypt"
      read -rp "Email for Let's Encrypt (e.g. it@school.edu.au): " CADDY_EMAIL
      [[ -n "${CADDY_EMAIL}" ]] || die "Email is required for Let's Encrypt."
      ;;
    2)
      TLS_MODE="internal"
      CADDY_EMAIL=""
      ;;
    3)
      TLS_MODE="http"
      CADDY_EMAIL=""
      ;;
    *)
      die "Invalid TLS mode choice: ${TLS_CHOICE}"
      ;;
  esac

  if [[ "${TLS_MODE}" == "letsencrypt" ]]; then
    echo
    echo "Checking public DNS for ${CADDY_DOMAIN}..."
    if ! dns_resolves "${CADDY_DOMAIN}"; then
      die "Public DNS does not resolve for ${CADDY_DOMAIN}. For local testing, choose Internal TLS or HTTP."
    fi
  fi

  if [[ "${TLS_MODE}" == "http" ]]; then
    APP_URL="http://${CADDY_DOMAIN}"
  else
    APP_URL="https://${CADDY_DOMAIN}"
  fi

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

  # Use Redis for Laravel caches/sessions/queues
  CACHE_DRIVER="redis"
  QUEUE_CONNECTION="redis"
  SESSION_DRIVER="redis"

  # Ensure we use phpredis (requires ext-redis in the image)
  REDIS_CLIENT="phpredis"

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
  echo "  Subdomain:     ${TENANT_SUBDOMAIN}"
  echo "  Base domain:   ${TENANT_BASE_DOMAIN}"
  echo "  FQDN:          ${CADDY_DOMAIN}"
  echo
  echo "TLS mode:        ${TLS_MODE}"
  [[ "${TLS_MODE}" == "letsencrypt" ]] && echo "ACME email:       ${CADDY_EMAIL}"
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
# write stack files (inline)
# -----------------------------
write_compose_yml() {
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

  # Nginx serves HTTP and forwards PHP to php-fpm (waypoint-app:9000)
  waypoint-web:
    image: nginx:1.27-alpine
    depends_on:
      - waypoint-app
    ports: []   # not published; Caddy talks to it on the Docker network
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
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
      - "443:443"
    environment:
      CADDY_EMAIL: ${CADDY_EMAIL}
      CADDY_DOMAIN: ${CADDY_DOMAIN}
      TLS_MODE: ${TLS_MODE}
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
}

write_nginx_conf() {
  # Nginx runs in its own container; it needs the app code to serve /public.
  # Because the app code is inside waypoint-app image, we proxy only PHP to waypoint-app,
  # and let Laravel handle routes. For static assets, we rely on Laravel public/ being available.
  #
  # NOTE: In a production-grade setup, we'd share /var/www/html/public into this container via a volume
  # or serve static assets via a dedicated mechanism. For now, Laravel will serve assets via routing
  # when needed behind Caddy; keep it minimal.
  cat > "${STACK_DIR}/nginx.conf" <<'NGINX'
server {
  listen 8080;
  server_name _;

  # We don't have /public files in this container by default.
  # Pass everything to Laravel via PHP front controller.
  location / {
    include fastcgi_params;
    fastcgi_param SCRIPT_FILENAME /var/www/html/public/index.php;
    fastcgi_param DOCUMENT_ROOT /var/www/html/public;
    fastcgi_param HTTP_HOST $host;
    fastcgi_pass waypoint-app:9000;
  }
}
NGINX
}

write_caddyfile() {
  if [[ "${TLS_MODE}" == "letsencrypt" ]]; then
    cat > "${STACK_DIR}/Caddyfile" <<CADDY
{
  email {$CADDY_EMAIL}
}

{$CADDY_DOMAIN} {
  reverse_proxy waypoint-web:8080
}
CADDY
    return
  fi

  if [[ "${TLS_MODE}" == "internal" ]]; then
    cat > "${STACK_DIR}/Caddyfile" <<'CADDY'
{$CADDY_DOMAIN} {
  tls internal
  reverse_proxy waypoint-web:8080
}
CADDY
    return
  fi

  # http mode
  cat > "${STACK_DIR}/Caddyfile" <<'CADDY'
{
  auto_https off
}

http://{$CADDY_DOMAIN} {
  reverse_proxy waypoint-web:8080
}
CADDY
}

write_env() {
  cat > "${STACK_DIR}/.env" <<EOF
WAYPOINT_APP_IMAGE=${WAYPOINT_APP_IMAGE}

APP_ENV=${APP_ENV}
APP_DEBUG=${APP_DEBUG}
APP_URL=${APP_URL}
APP_KEY=${APP_KEY}

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

CADDY_EMAIL=${CADDY_EMAIL}
CADDY_DOMAIN=${CADDY_DOMAIN}
TLS_MODE=${TLS_MODE}

TENANT_ID=${TENANT_ID}
TENANT_NAME=${TENANT_NAME}
TENANT_SUBDOMAIN=${TENANT_SUBDOMAIN}
TENANT_BASE_DOMAIN=${TENANT_BASE_DOMAIN}
EOF

  chmod 600 "${STACK_DIR}/.env"
}

write_stack_files() {
  log "Writing stack files"
  write_compose_yml
  write_nginx_conf
  write_caddyfile
  write_env
}

# -----------------------------
# bring up stack + app init
# -----------------------------
compose_up() {
  log "Starting services"
  cd "${STACK_DIR}"
  docker compose pull
  docker compose up -d
}

detect_and_set_storage_perms() {
  log "Detecting container UID/GID and setting storage permissions"
  cd "${STACK_DIR}"

  # Get uid/gid of the user inside waypoint-app (works on alpine/debian)
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

  KEY="$(docker compose exec -T waypoint-app php -r "echo 'base64:'.base64_encode(random_bytes(32)).PHP_EOL;")"
  [[ -n "${KEY}" ]] || die "Failed to generate APP_KEY."

  sed -i "s|^APP_KEY=.*$|APP_KEY=${KEY}|" "${STACK_DIR}/.env"
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
  echo "  2) Admin/maintenance commands:"
  echo "     cd ${STACK_DIR} && docker compose exec waypoint-app php artisan <command>"
  echo
  if [[ "${TLS_MODE}" == "internal" ]]; then
    echo "Note (Internal TLS):"
    echo "  Your browser will warn until you trust Caddy's local CA."
    echo
  elif [[ "${TLS_MODE}" == "http" ]]; then
    echo "Note (HTTP):"
    echo "  This is plaintext HTTP. Use Let's Encrypt mode for production."
    echo
  fi
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

  # Now that containers exist, set perms using detected uid/gid
  detect_and_set_storage_perms

  generate_app_key_in_container
  run_migrations
  create_first_tenant
  print_summary
}

main "$@"
