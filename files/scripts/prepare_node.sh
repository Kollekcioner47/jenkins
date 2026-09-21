#!/usr/bin/env bash
#
# Подготовка целевого сервера (node1 или node2) для работы агентом Jenkins
# и площадкой для сайта.
#
# Запускается ОДИН РАЗ на каждой из двух машин от пользователя engineer:
#     sudo bash prepare_node.sh node1
#
# Что делает:
#   1. ставит Java, nginx, rsync и вспомогательные утилиты;
#   2. создаёт пользователя jenkins — под ним к агенту будет подключаться
#      контроллер Jenkins;
#   3. создаёт каталоги выката /var/www/site/{releases,shared}
#      и отдаёт их пользователю jenkins;
#   4. настраивает nginx на каталог current (симлинк на текущий релиз);
#   5. выдаёт пользователю jenkins право перезагружать nginx
#      БЕЗ ПАРОЛЯ И ТОЛЬКО ЭТУ ОДНУ КОМАНДУ.
#
# ПОЧЕМУ ОТДЕЛЬНЫЙ СКРИПТ, А НЕ ПЯТЬ КОМАНД В ТЕКСТЕ ПРАКТИКИ:
# подготовку проходят дважды (node1 и node2), и расхождение между машинами
# потом ищут часами: «на node1 работает, на node2 нет». Один и тот же
# скрипт на обеих машинах такое расхождение исключает.

set -euo pipefail

NODE_NAME="${1:-$(hostname)}"
DEPLOY_USER="${DEPLOY_USER:-jenkins}"
SITE_NAME="${SITE_NAME:-site}"
WEB_ROOT="/var/www/${SITE_NAME}"

log() { echo "[prepare] $*"; }

# ------------------------------------------------------------------ 1. пакеты
log "ставлю пакеты"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
    openjdk-21-jre-headless \
    nginx \
    rsync \
    curl \
    git \
    vim \
    htop \
    unzip

# ------------------------------------------- 2. пользователь для подключений
# Агент Jenkins подключается по SSH и работает под этим пользователем.
# Домашний каталог нужен обязательно: в нём живёт рабочий каталог сборки
# и authorized_keys.
if id "${DEPLOY_USER}" >/dev/null 2>&1; then
    log "пользователь ${DEPLOY_USER} уже есть"
else
    log "создаю пользователя ${DEPLOY_USER}"
    adduser --disabled-password --gecos "" "${DEPLOY_USER}"
fi

# Пароль не задаём: вход только по ключу. Это не забывчивость, а решение:
# у учётной записи для автоматизации не должно быть пароля, который можно
# подобрать или передать по открытому каналу.
install -d -m 0700 -o "${DEPLOY_USER}" -g "${DEPLOY_USER}" "/home/${DEPLOY_USER}/.ssh"
if [ ! -f "/home/${DEPLOY_USER}/.ssh/authorized_keys" ]; then
    : > "/home/${DEPLOY_USER}/.ssh/authorized_keys"
fi
chown "${DEPLOY_USER}:${DEPLOY_USER}" "/home/${DEPLOY_USER}/.ssh/authorized_keys"
chmod 0600 "/home/${DEPLOY_USER}/.ssh/authorized_keys"

# --------------------------------------------------- 3. каталоги для выката
# Схема releases + current — та же, что используют Capistrano и Deployer:
# каждый выкат кладёт файлы в свой каталог с меткой времени, а current —
# это симлинк на нужный релиз. Переключение симлинка атомарно, откат
# сводится к переключению обратно, история версий остаётся на диске.
log "готовлю каталоги выката в ${WEB_ROOT}"
install -d -o "${DEPLOY_USER}" -g "${DEPLOY_USER}" "${WEB_ROOT}"
install -d -o "${DEPLOY_USER}" -g "${DEPLOY_USER}" "${WEB_ROOT}/releases"
install -d -o "${DEPLOY_USER}" -g "${DEPLOY_USER}" "${WEB_ROOT}/shared"

# Первый релиз-заглушка: nginx не должен ругаться, если сайта ещё нет.
if [ ! -e "${WEB_ROOT}/current" ]; then
    seed="${WEB_ROOT}/releases/00000000-000000-seed"
    install -d -o "${DEPLOY_USER}" -g "${DEPLOY_USER}" "${seed}"
    cat > "${seed}/index.html" <<'HTML'
<!DOCTYPE html>
<html lang="ru"><head><meta charset="UTF-8"><title>Заглушка</title></head>
<body><h1>Сайт ещё не выкатывался</h1></body></html>
HTML
    chown "${DEPLOY_USER}:${DEPLOY_USER}" "${seed}/index.html"
    ln -sfn "${seed}" "${WEB_ROOT}/current"
fi

# ------------------------------------------------------------- 4. nginx
log "настраиваю nginx"
cat > /etc/nginx/sites-available/${SITE_NAME} <<NGINX
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    server_name ${NODE_NAME};

    # Отдаём каталог current — то есть тот релиз, на который указывает
    # симлинк. Меняется симлинк, а не конфигурация nginx: править конфиг
    # при каждом выкате не нужно, и перезапуск тоже не нужен.
    root ${WEB_ROOT}/current;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }

    # Служебная страница: по ней видно, что отдаёт сервер,
    # не заглядывая в файлы.
    location = /health {
        access_log off;
        add_header Content-Type text/plain;
        return 200 '${NODE_NAME} ok\n';
    }
}
NGINX
rm -f /etc/nginx/sites-enabled/default
ln -sfn /etc/nginx/sites-available/${SITE_NAME} /etc/nginx/sites-enabled/${SITE_NAME}
nginx -t
systemctl enable --now nginx
systemctl reload nginx

# ------------------------------------------------- 5. узкое правило sudo
# Соблазн — выдать пользователю jenkins полный sudo. Тогда утечка одного
# ключа агента означает root на сервере. Здесь разрешена ровно одна
# команда: перезагрузка конфигурации nginx. Всё остальное — отказ,
# и это видно в журнале sudo.
log "выдаю право на перезагрузку nginx без пароля"
cat > /etc/sudoers.d/jenkins-nginx <<SUDOERS
# Разрешение только на одну команду и только без аргументов.
${DEPLOY_USER} ALL=(root) NOPASSWD: /usr/bin/systemctl reload nginx, /bin/systemctl reload nginx
SUDOERS
chmod 0440 /etc/sudoers.d/jenkins-nginx
visudo -c -f /etc/sudoers.d/jenkins-nginx

log "готово на ${NODE_NAME}"
log "дальше: скопировать сюда публичную часть ключа агента в /home/${DEPLOY_USER}/.ssh/authorized_keys"
log "проверка сайта:  curl http://localhost/health"
