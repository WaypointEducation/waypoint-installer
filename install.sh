#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="/opt/waypoint/stack"
DATA_DIR="/opt/waypoint/data"

log() { echo -e "\n[waypoint-installer] $*\n"; }

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Please run as root (or via sudo): sudo bash install.sh"
    exit 1
  fi
}

ensure_debian() {
  if [[ ! -f /etc/debian_version ]]; then
    echo "This installer currently supports Debian-based systems only."
    exit 1
  fi
}

install_prereqs() {
  log "Installing prerequisites"
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg openssl
}

install_docker() {
  if command -v docker >/dev/null 2>&1; then
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

ensure_dirs() {
  log "Creating directories under /opt/waypoint"
  mkdir -p "${STACK_DIR}"
  mkdir -p "${DATA_DIR}/"{mariadb,redis,storage}
  mkdir -p "${DATA_DIR}/storage"/logs
  mkdir -p "${DATA_DIR}/storage"/framework/{cache,sessions,views}
}

rand_b64() {
  # 32 bytes => base64 string
  openssl rand -base64 32 | tr -d '\n'
}

rand_hex() {
  openssl rand -hex 24 | tr -d '\n'
}

prompt_inputs() {
  log "Configuration"
[[ -t 0 ]] || exec </dev/tty
  read -rp "Domain (e.g. waypoint.school.edu.au): " CADDY_DOMAIN 
  if [[ -z "${CADDY_DOMAIN}" ]]; then
    echo "Domain is required."
    exit 1
  fi

  read -rp "Email for Let's Encrypt (e.g. it@school.edu.au): " CADDY_EMAIL 
  if [[ -z "${CADDY_EMAIL}" ]]; then
    echo "Email is required."
    exit 1
  fi

  APP_URL="https://${CADDY_DOMAIN}"

  DB_DATABASE="waypoint"
  DB_USERNAME="waypoint"
  DB_PASSWORD="$(rand_hex)"
  MYSQL_ROOT_PASSWORD="$(rand_hex)"

  
  APP_KEY=""

  WAYPOINT_APP_IMAGE="ghcr.io/waypointeducation/waypoint:stable"
  APP_ENV="production"
  APP_DEBUG="false"

  DB_CONNECTION="mysql"
  DB_HOST="mariadb"
  DB_PORT="3306"

  REDIS_HOST="redis"
  REDIS_PORT="6379"

  CACHE_DRIVER="redis"
  QUEUE_CONNECTION="redis"
  SESSION_DRIVER="redis"
}

write_templates() {
  log "Writing stack files"

  
  BASE_URL="https://raw.githubusercontent.com/WaypointEducation/waypoint-installer/main/templates"

  curl -fsSL "${BASE_URL}/compose.yml" -o "${STACK_DIR}/compose.yml"
  curl -fsSL "${BASE_URL}/Caddyfile" -o "${STACK_DIR}/Caddyfile"

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

CACHE_DRIVER=${CACHE_DRIVER}
QUEUE_CONNECTION=${QUEUE_CONNECTION}
SESSION_DRIVER=${SESSION_DRIVER}

CADDY_EMAIL=${CADDY_EMAIL}
CADDY_DOMAIN=${CADDY_DOMAIN}
EOF

  chmod 600 "${STACK_DIR}/.env"
}

set_storage_perms() {

  log "Setting storage permissions for container writes"
  chown -R 33:33 "${DATA_DIR}/storage" || true
  chmod -R 775 "${DATA_DIR}/storage" || true
}

compose_up() {
  log "Starting services"
  cd "${STACK_DIR}"
  docker compose pull
  docker compose up -d
}

generate_app_key_in_container() {
  log "Generating APP_KEY inside container and writing it to host .env"

  cd "${STACK_DIR}"

  # Generate key using container PHP 
  KEY="$(docker compose exec -T waypoint-app php -r "echo 'base64:'.base64_encode(random_bytes(32)).PHP_EOL;")"
  if [[ -z "${KEY}" ]]; then
    echo "Failed to generate APP_KEY."
    exit 1
  fi

  # Replace APP_KEY= line in host .env
  sed -i "s|^APP_KEY=.*$|APP_KEY=${KEY}|" "${STACK_DIR}/.env"

  # Restart to load env
  docker compose up -d
}

run_migrations() {
  log "Running migrations"
  cd "${STACK_DIR}"
  docker compose exec -T waypoint-app php artisan migrate --force
}

print_summary() {
  log "Install complete"
  echo "URL: ${APP_URL}"
  echo
  echo "DB_DATABASE=${DB_DATABASE}"
  echo "DB_USERNAME=${DB_USERNAME}"
  echo "DB_PASSWORD=${DB_PASSWORD}"
  echo
  echo "Next:"
  echo "  - Browse to the URL above"
  echo "  - If you have an internal 'first admin' command, run it with:"
  echo "      cd ${STACK_DIR} && docker compose exec waypoint-app php artisan <your-command>"
}

main() {
  require_root
  ensure_debian
  install_prereqs
  install_docker
  ensure_dirs
  prompt_inputs
  write_templates
  set_storage_perms
  compose_up
  generate_app_key_in_container
  run_migrations
  print_summary
}

main "$@"
