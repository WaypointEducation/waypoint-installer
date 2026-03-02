#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="/opt/waypoint/stack"
DATA_DIR="/opt/waypoint/data"

# Where we temporarily download templates (because install.sh is curl'd as a single file)
TEMPLATES_DIR="${STACK_DIR}/.templates"

# GitHub raw base (pin this to a tag/commit later if you want reproducible installs)
INSTALLER_RAW_BASE="https://raw.githubusercontent.com/WaypointEducation/waypoint-installer/main"

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

need_file() {
  local f="$1"
  [[ -f "$f" ]] || die "Missing required file: $f"
}

download_file() {
  local url="$1"
  local dest="$2"
  # -f fail on HTTP errors, -S show errors, -L follow redirects
  curl -fsSL "$url" -o "$dest" || die "Failed to download: $url"
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
  mkdir -p "${TEMPLATES_DIR}"
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
# download templates (runtime)
# -----------------------------
fetch_templates() {
  log "Downloading installer templates from GitHub"

  # NOTE: These paths MUST match your waypoint-installer repo layout:
  # templates/compose.yml
  # templates/env.example
  # templates/Caddyfile
  # templates/nginx.conf   <-- you must create/commit this file in the installer repo
  local compose_t="${TEMPLATES_DIR}/compose.yml"
  local env_t="${TEMPLATES_DIR}/env.example"
  local caddy_t="${TEMPLATES_DIR}/Caddyfile"
  local nginx_t="${TEMPLATES_DIR}/nginx.conf"

  download_file "${INSTALLER_RAW_BASE}/templates/compose.yml" "${compose_t}"
  download_file "${INSTALLER_RAW_BASE}/templates/env.example" "${env_t}"
  download_file "${INSTALLER_RAW_BASE}/templates/Caddyfile" "${caddy_t}"
  download_file "${INSTALLER_RAW_BASE}/templates/nginx.conf" "${nginx_t}"

  need_file "${compose_t}"
  need_file "${env_t}"
  need_file "${caddy_t}"
  need_file "${nginx_t}"
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
Installs to:

  /opt/waypoint/stack   (compose.yml, .env, Caddyfile, nginx.conf)
  /opt/waypoint/data    (MariaDB, Redis, Laravel storage)

Components:
  - Waypoint app (php-fpm)
  - Waypoint web (nginx, serves /public including /build)
  - MariaDB
  - Redis
  - Caddy (reverse proxy)

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

  echo
  echo "Your tenant URL will be:"
  echo "  http://${CADDY_DOMAIN}"
  echo

  # HTTP-only mode
  TLS_MODE="http"
  CADDY_EMAIL=""
  APP_URL="http://${CADDY_DOMAIN}"

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
# write stack files from downloaded templates
# -----------------------------
render_template() {
  # Usage: render_template <src> <dest>
  local src="$1"
  local dest="$2"

  sed \
    -e "s|\${WAYPOINT_APP_IMAGE}|${WAYPOINT_APP_IMAGE}|g" \
    -e "s|\${CADDY_DOMAIN}|${CADDY_DOMAIN}|g" \
    -e "s|\${CADDY_EMAIL}|${CADDY_EMAIL}|g" \
    -e "s|\${TLS_MODE}|${TLS_MODE}|g" \
    -e "s|\${DB_DATABASE}|${DB_DATABASE}|g" \
    -e "s|\${DB_USERNAME}|${DB_USERNAME}|g" \
    -e "s|\${DB_PASSWORD}|${DB_PASSWORD}|g" \
    -e "s|\${MYSQL_ROOT_PASSWORD}|${MYSQL_ROOT_PASSWORD}|g" \
    -e "s|\${APP_ENV}|${APP_ENV}|g" \
    -e "s|\${APP_DEBUG}|${APP_DEBUG}|g" \
    -e "s|\${APP_URL}|${APP_URL}|g" \
    -e "s|\${REDIS_HOST}|${REDIS_HOST}|g" \
    -e "s|\${REDIS_PORT}|${REDIS_PORT}|g" \
    -e "s|\${REDIS_CLIENT}|${REDIS_CLIENT}|g" \
    -e "s|\${CACHE_DRIVER}|${CACHE_DRIVER}|g" \
    -e "s|\${QUEUE_CONNECTION}|${QUEUE_CONNECTION}|g" \
    -e "s|\${SESSION_DRIVER}|${SESSION_DRIVER}|g" \
    -e "s|\${TENANT_ID}|${TENANT_ID}|g" \
    -e "s|\${TENANT_NAME}|${TENANT_NAME}|g" \
    -e "s|\${TENANT_SUBDOMAIN}|${TENANT_SUBDOMAIN}|g" \
    -e "s|\${TENANT_BASE_DOMAIN}|${TENANT_BASE_DOMAIN}|g" \
    "$src" > "$dest"
}

write_stack_files() {
  log "Writing stack files"

  local compose_t="${TEMPLATES_DIR}/compose.yml"
  local env_t="${TEMPLATES_DIR}/env.example"
  local caddy_t="${TEMPLATES_DIR}/Caddyfile"
  local nginx_t="${TEMPLATES_DIR}/nginx.conf"

  need_file "${compose_t}"
  need_file "${env_t}"
  need_file "${caddy_t}"
  need_file "${nginx_t}"

  render_template "${compose_t}" "${STACK_DIR}/compose.yml"
  render_template "${env_t}" "${STACK_DIR}/.env"
  render_template "${caddy_t}" "${STACK_DIR}/Caddyfile"

  # nginx template is already final, no placeholders needed
  cp -f "${nginx_t}" "${STACK_DIR}/nginx.conf"

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

  fetch_templates

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
