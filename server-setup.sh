#!/usr/bin/env bash
#
# Server setup for the cargo projects (Laravel 12) on a fresh Ubuntu 24.04 droplet.
#
# Installs the shared stack only. Nothing here is tied to one project:
#   Apache 2 + PHP-FPM (latest patch of PHP_VERSION, from ppa:ondrej/php)
#   MySQL 8 (optional), ProxySQL, Redis, Supervisor, Composer, firewall
#   a deploy user that owns the code and can act as www-data
#
# Each project is added afterwards (clone, .env, Apache vhost, Supervisor workers, cron):
# see the "Next" list printed at the end.
#
# Run as root. Re-running is safe: every step checks before it creates.
#
#   bash server-setup.sh
#   PHP_VERSION=8.3 INSTALL_MYSQL=no bash server-setup.sh
#
# Settings (environment variables, defaults below):
#   PHP_VERSION        PHP minor version                         8.3
#   DEPLOY_USER        owns the code, runs git / composer        deploy
#   TIMEZONE           server timezone                           Asia/Yangon
#   INSTALL_MYSQL      yes = MySQL server on this droplet        yes
#                      no  = the database is on another host (ProxySQL points there)
#   INSTALL_PROXYSQL   yes = ProxySQL on :6033 (admin :6032)     yes
#   PROXYSQL_SERIES    ProxySQL apt series                       2.7.x
#
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------
PHP_VERSION="${PHP_VERSION:-8.3}"
DEPLOY_USER="${DEPLOY_USER:-deploy}"
TIMEZONE="${TIMEZONE:-Asia/Yangon}"
INSTALL_MYSQL="${INSTALL_MYSQL:-yes}"
INSTALL_PROXYSQL="${INSTALL_PROXYSQL:-yes}"
PROXYSQL_SERIES="${PROXYSQL_SERIES:-2.7.x}"

readonly WEB_USER="www-data"
readonly PHP_BIN="/usr/bin/php${PHP_VERSION}"
readonly PROXYSQL_REPO="https://repo.proxysql.com/ProxySQL/proxysql-${PROXYSQL_SERIES}"
readonly PROXYSQL_KEYRING="/usr/share/keyrings/proxysql.gpg"
readonly PROXYSQL_MONITOR_USER="proxysql_monitor"
readonly CREDENTIALS_FILE="/root/server-credentials.txt"

export DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m    ! %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

trap 'fail "line ${LINENO}: ${BASH_COMMAND}"' ERR

random_password() { openssl rand -base64 33 | tr -dc 'A-Za-z0-9' | head -c 32; }

# remember KEY VALUE  — keep a generated secret in the credentials file (root only)
remember() {
    local key="$1" value="$2"
    touch "$CREDENTIALS_FILE"
    chmod 600 "$CREDENTIALS_FILE"
    sed -i "/^${key}=/d" "$CREDENTIALS_FILE"
    printf '%s=%s\n' "$key" "$value" >> "$CREDENTIALS_FILE"
}

# recall KEY  — a secret saved by an earlier run, so re-running keeps the same passwords
recall() {
    [[ -f "$CREDENTIALS_FILE" ]] || return 0
    sed -n "s/^$1=//p" "$CREDENTIALS_FILE" | tail -1
}

proxysql_admin() {
    mysql -u admin -p"$1" -h 127.0.0.1 -P 6032 --batch --skip-column-names
}

# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------
check_system() {
    step "Checking the system"
    [[ $EUID -eq 0 ]] || fail "run as root"
    . /etc/os-release
    [[ "${VERSION_ID}" == "24.04" ]] || warn "written for Ubuntu 24.04, this is ${PRETTY_NAME}"
    info "PHP ${PHP_VERSION}, MySQL ${INSTALL_MYSQL}, ProxySQL ${INSTALL_PROXYSQL}, deploy user ${DEPLOY_USER}"
}

install_base() {
    step "Updating the OS and installing base packages"
    apt-get update -q
    apt-get upgrade -yq
    apt-get install -yq software-properties-common ca-certificates curl gnupg git unzip zip \
        acl cron ufw openssl
    timedatectl set-timezone "$TIMEZONE"
}

create_deploy_user() {
    step "Creating the deploy user '${DEPLOY_USER}'"
    if ! id "$DEPLOY_USER" &> /dev/null; then
        adduser --disabled-password --gecos "" "$DEPLOY_USER"
        info "created"
    fi
    usermod -aG "$WEB_USER" "$DEPLOY_USER"

    # Same SSH login as root, so you can log in as the deploy user right away.
    local ssh_dir="/home/${DEPLOY_USER}/.ssh"
    install -d -m 700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$ssh_dir"
    if [[ -f /root/.ssh/authorized_keys && ! -f "${ssh_dir}/authorized_keys" ]]; then
        install -m 600 -o "$DEPLOY_USER" -g "$DEPLOY_USER" /root/.ssh/authorized_keys "${ssh_dir}/authorized_keys"
    fi

    # Key for pulling the projects: add the .pub as a read-only deploy key on each repo.
    if [[ ! -f "${ssh_dir}/id_ed25519" ]]; then
        sudo -u "$DEPLOY_USER" ssh-keygen -t ed25519 -N "" -C "${DEPLOY_USER}@$(hostname)" -f "${ssh_dir}/id_ed25519" -q
    fi

    # Passwordless sudo only for what a deploy needs.
    cat > "/etc/sudoers.d/${DEPLOY_USER}" <<EOF
${DEPLOY_USER} ALL=(${WEB_USER}) NOPASSWD: ALL
${DEPLOY_USER} ALL=(root) NOPASSWD: /usr/bin/supervisorctl, /usr/bin/systemctl reload apache2, /usr/bin/systemctl restart php${PHP_VERSION}-fpm
EOF
    chmod 440 "/etc/sudoers.d/${DEPLOY_USER}"
    visudo -cf "/etc/sudoers.d/${DEPLOY_USER}" > /dev/null
}

install_php() {
    step "Installing PHP ${PHP_VERSION} (latest patch)"
    add-apt-repository -y ppa:ondrej/php
    apt-get update -q
    apt-get install -yq "php${PHP_VERSION}-fpm" "php${PHP_VERSION}-cli" "php${PHP_VERSION}-common" \
        "php${PHP_VERSION}-mysql" "php${PHP_VERSION}-mbstring" "php${PHP_VERSION}-xml" \
        "php${PHP_VERSION}-curl" "php${PHP_VERSION}-zip" "php${PHP_VERSION}-gd" \
        "php${PHP_VERSION}-bcmath" "php${PHP_VERSION}-intl" "php${PHP_VERSION}-redis" \
        "php${PHP_VERSION}-readline" "php${PHP_VERSION}-opcache"
    update-alternatives --set php "$PHP_BIN"

    local sapi
    for sapi in fpm cli; do
        cat > "/etc/php/${PHP_VERSION}/${sapi}/conf.d/99-server.ini" <<EOF
date.timezone = ${TIMEZONE}
memory_limit = 512M
upload_max_filesize = 20M
post_max_size = 25M
max_execution_time = 120
expose_php = Off
opcache.enable = 1
opcache.memory_consumption = 192
opcache.max_accelerated_files = 20000
opcache.validate_timestamps = 1
EOF
    done
    systemctl enable --now "php${PHP_VERSION}-fpm"
    systemctl restart "php${PHP_VERSION}-fpm"
    info "PHP $("$PHP_BIN" -r 'echo PHP_VERSION;')"
}

install_apache() {
    step "Installing Apache (PHP through PHP-FPM)"
    apt-get install -yq apache2 certbot python3-certbot-apache
    a2enmod -q rewrite headers proxy_fcgi setenvif expires
    a2enconf -q "php${PHP_VERSION}-fpm"
    a2dissite -q 000-default > /dev/null || true
    apache2ctl configtest
    systemctl enable --now apache2
    systemctl reload apache2
}

install_mysql() {
    [[ "$INSTALL_MYSQL" == "yes" ]] || { step "Skipping MySQL server (INSTALL_MYSQL=${INSTALL_MYSQL})"; apt-get install -yq mysql-client; return; }
    step "Installing MySQL 8"
    apt-get install -yq mysql-server
    systemctl enable --now mysql
    info "root logs in through the socket: sudo mysql"
}

install_redis_supervisor() {
    step "Installing Redis and Supervisor"
    apt-get install -yq redis-server supervisor
    systemctl enable --now redis-server supervisor
    redis-cli ping > /dev/null || fail "redis is not answering"
    info "redis $(redis-server --version | awk '{print $3}')"
}

install_composer() {
    step "Installing Composer"
    if ! command -v composer > /dev/null; then
        local expected actual
        expected="$(curl -fsSL https://composer.github.io/installer.sig)"
        curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
        actual="$("$PHP_BIN" -r "echo hash_file('sha384', '/tmp/composer-setup.php');")"
        [[ "$expected" == "$actual" ]] || fail "composer installer checksum mismatch"
        "$PHP_BIN" /tmp/composer-setup.php --quiet --install-dir=/usr/local/bin --filename=composer
        rm -f /tmp/composer-setup.php
    fi
    info "$(composer --version 2> /dev/null)"
}

install_proxysql() {
    [[ "$INSTALL_PROXYSQL" == "yes" ]] || { step "Skipping ProxySQL (INSTALL_PROXYSQL=${INSTALL_PROXYSQL})"; return; }
    step "Installing ProxySQL ${PROXYSQL_SERIES}"
    . /etc/os-release
    curl -fsSL "${PROXYSQL_REPO}/repo_pub_key" | gpg --dearmor --yes -o "$PROXYSQL_KEYRING"
    echo "deb [signed-by=${PROXYSQL_KEYRING}] ${PROXYSQL_REPO}/${VERSION_CODENAME}/ ./" > /etc/apt/sources.list.d/proxysql.list
    apt-get update -q
    apt-get install -yq proxysql
    systemctl enable --now proxysql

    # Wait for the admin port.
    local i
    for i in {1..30}; do
        (exec 3<> /dev/tcp/127.0.0.1/6032) 2> /dev/null && break
        sleep 1
    done

    # Replace the default admin/admin login, keep the monitor credentials and charset.
    # Backend servers and app users are per project: added later, see docs/proxysql.md.
    local admin_password monitor_password current
    admin_password="$(recall PROXYSQL_ADMIN_PASSWORD)"
    [[ -n "$admin_password" ]] || admin_password="$(random_password)"
    monitor_password="$(recall PROXYSQL_MONITOR_PASSWORD)"
    [[ -n "$monitor_password" ]] || monitor_password="$(random_password)"

    if echo 'SELECT 1;' | proxysql_admin admin &> /dev/null; then
        current="admin"
    elif echo 'SELECT 1;' | proxysql_admin "$admin_password" &> /dev/null; then
        current="$admin_password"
    else
        fail "cannot log in to the ProxySQL admin console (port 6032)"
    fi

    proxysql_admin "$current" <<EOF
UPDATE global_variables SET variable_value = '${PROXYSQL_MONITOR_USER}' WHERE variable_name = 'mysql-monitor_username';
UPDATE global_variables SET variable_value = '${monitor_password}' WHERE variable_name = 'mysql-monitor_password';
UPDATE global_variables SET variable_value = 'utf8mb4' WHERE variable_name = 'mysql-default_charset';
LOAD MYSQL VARIABLES TO RUNTIME; SAVE MYSQL VARIABLES TO DISK;
UPDATE global_variables SET variable_value = 'admin:${admin_password}' WHERE variable_name = 'admin-admin_credentials';
LOAD ADMIN VARIABLES TO RUNTIME; SAVE ADMIN VARIABLES TO DISK;
EOF
    remember PROXYSQL_ADMIN_PASSWORD "$admin_password"
    remember PROXYSQL_MONITOR_PASSWORD "$monitor_password"

    # Local MySQL: create the monitor login and register it as the backend.
    if [[ "$INSTALL_MYSQL" == "yes" ]]; then
        mysql <<EOF
CREATE USER IF NOT EXISTS '${PROXYSQL_MONITOR_USER}'@'127.0.0.1' IDENTIFIED BY '${monitor_password}';
ALTER USER '${PROXYSQL_MONITOR_USER}'@'127.0.0.1' IDENTIFIED BY '${monitor_password}';
EOF
        proxysql_admin "$admin_password" <<EOF
INSERT INTO mysql_servers (hostgroup_id, hostname, port)
SELECT 0, '127.0.0.1', 3306 WHERE NOT EXISTS (SELECT 1 FROM mysql_servers WHERE hostname = '127.0.0.1' AND port = 3306);
LOAD MYSQL SERVERS TO RUNTIME; SAVE MYSQL SERVERS TO DISK;
EOF
        info "backend: local MySQL 127.0.0.1:3306"
    else
        info "no backend yet: add the database host to mysql_servers (docs/proxysql.md, demo 2)"
    fi
}

setup_firewall() {
    step "Firewall: allow SSH, HTTP, HTTPS"
    ufw allow OpenSSH > /dev/null
    ufw allow "Apache Full" > /dev/null
    ufw --force enable > /dev/null
    ufw status | sed 's/^/    /'
}

summary() {
    step "Done"
    cat <<EOF
    PHP:        $("$PHP_BIN" -r 'echo PHP_VERSION;') (php-fpm, Apache)
    MySQL:      ${INSTALL_MYSQL}
    ProxySQL:   ${INSTALL_PROXYSQL}  (app port 6033, admin 127.0.0.1:6032)
    Redis:      $(redis-cli ping)
    Supervisor: $(supervisorctl version)
    Secrets:    ${CREDENTIALS_FILE}

    Deploy key for the git server (add as read-only deploy key on each project):
      $(cat "/home/${DEPLOY_USER}/.ssh/id_ed25519.pub")

    Next, for each project:
      1. As ${DEPLOY_USER}: git clone into /var/www/<PROJECT>, composer install --no-dev
      2. .env (copy the old server's: APP_KEY and JWT_SECRET must stay the same),
         DB_HOST=127.0.0.1 DB_PORT=6033 APP_LOG_LEVEL=info
      3. Database + app user on MySQL, then the user in ProxySQL mysql_users (docs/proxysql.md)
      4. Permissions: chown -R ${DEPLOY_USER}:${WEB_USER}, and on storage/ and bootstrap/cache/
         setfacl -R -m u:${WEB_USER}:rwX,u:${DEPLOY_USER}:rwX + the same with -d
      5. Apache vhost in /etc/apache2/sites-available/ (DocumentRoot <PROJECT>/public,
         AllowOverride All), a2ensite, then certbot --apache -d <domain>
      6. Supervisor workers (docs/queue-supervisor.md) and the www-data cron for schedule:run
      7. sudo -u ${WEB_USER} php artisan config:cache && php artisan route:cache
EOF
}

main() {
    check_system
    install_base
    create_deploy_user
    install_php
    install_apache
    install_mysql
    install_redis_supervisor
    install_composer
    install_proxysql
    setup_firewall
    summary
}

main "$@"
