#!/usr/bin/env bash
#
# Резервная копия Jenkins: каталог JENKINS_HOME целиком.
#
# Запускается на контроллере (admin):
#     sudo bash backup_jenkins.sh              полная копия, история сборок сохраняется
#     sudo bash backup_jenkins.sh --slim       без истории сборок: копия меньше в разы
#
# ЧТО ИМЕННО КОПИРУЕТСЯ И ПОЧЕМУ ЭТО ВАЖНО
#
# JENKINS_HOME — это и есть весь Jenkins. Там лежат задания, пользователи,
# плагины, настройки и credentials. Отдельно стоит запомнить каталог
# secrets/: в нём ключ, которым зашифрован файл credentials.xml.
# Если скопировать credentials.xml без secrets/, пароли не расшифруются,
# и восстановление окажется бесполезным — это самая частая ошибка
# при переезде Jenkins.
#
# Рабочие каталоги сборок (workspace) не копируются никогда: это мусор,
# который занимает гигабайты и при восстановлении создаётся заново.

set -euo pipefail

JENKINS_HOME="${JENKINS_HOME:-/var/lib/jenkins}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/jenkins}"
KEEP="${KEEP:-7}"
JENKINS_USER="${JENKINS_USER:-jenkins}"

SLIM=0
for arg in "$@"; do
    case "${arg}" in
        --slim) SLIM=1 ;;
        *) echo "неизвестный параметр: ${arg}" >&2; exit 2 ;;
    esac
done

[ -d "${JENKINS_HOME}" ] || { echo "нет каталога ${JENKINS_HOME}" >&2; exit 1; }

STAMP="$(date +%Y%m%d-%H%M%S)"
SUFFIX="full"
[ "${SLIM}" = "1" ] && SUFFIX="slim"
TARGET="${BACKUP_DIR}/jenkins-${STAMP}-${SUFFIX}.tar.gz"

install -d -m 0750 "${BACKUP_DIR}"

EXCLUDES=(
    --exclude='./workspace'
    --exclude='./jobs/*/workspace'
    --exclude='./nodes/*/workspace'
    --exclude='./.cache'
    --exclude='./war'
    --exclude='./logs/*.gz'
)
if [ "${SLIM}" = "1" ]; then
    EXCLUDES+=(--exclude='./jobs/*/builds')
    EXCLUDES+=(--exclude='./jobs/*/nextBuildNumber')
fi

echo "копирую ${JENKINS_HOME} -> ${TARGET}"

# Архив собирается во ВРЕМЕННОМ каталоге, доступном пользователю jenkins,
# и только потом переносится на место от root.
#
# ЗАЧЕМ ТАК. Каталог копий принадлежит root и закрыт правами 0750 — иначе
# копию, в которой лежат все ключи Jenkins, прочитает любой пользователь
# машины. Но tar мы запускаем от имени jenkins, а jenkins в этот каталог
# писать не может: попытка создать файл прямо в ${BACKUP_DIR} завершается
# «Permission denied» и tar выходит с кодом 2. Поэтому архив сначала
# пишется в закрытый временный каталог, владельцем которого является
# jenkins, и лишь затем устанавливается в каталог копий с нужными правами.
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT
chown "${JENKINS_USER}:${JENKINS_USER}" "${WORK_DIR}"
chmod 0700 "${WORK_DIR}"
STAGING="${WORK_DIR}/$(basename "${TARGET}")"

# tar запускаем от имени jenkins: часть файлов контроллер создаёт с правами
# только для владельца, и под root они попадут в архив с другими метаданными.
# --warning=no-file-changed: файлы в JENKINS_HOME меняются прямо во время
# копирования, и без этого флага tar завершится с предупреждением.
sudo -u "${JENKINS_USER}" tar \
    --create --gzip --file "${STAGING}" \
    --directory="${JENKINS_HOME}" \
    --warning=no-file-changed \
    "${EXCLUDES[@]}" \
    . || {
        rc=$?
        # Код 1 у tar означает «предупреждение», а не «ошибка»:
        # чаще всего файл изменился во время чтения.
        [ "${rc}" = "1" ] || exit "${rc}"
    }

# Проверка ДО того, как архив займёт место среди копий: копия, которую
# нельзя распаковать, хуже отсутствия копии — она создаёт ложную
# уверенность, что защита есть.
echo "проверяю архив"
tar --list --file "${STAGING}" >/dev/null

# Ставим на место от root: владелец root, права 0640 — читают только
# root и члены его группы.
install -m 0640 -o root -g root "${STAGING}" "${TARGET}"
rm -rf "${WORK_DIR}"
trap - EXIT

echo "готово: ${TARGET} ($(du -h "${TARGET}" | cut -f1))"

# Ротация: держим последние KEEP копий каждого вида.
mapfile -t OLD < <(ls -1t "${BACKUP_DIR}"/jenkins-*-${SUFFIX}.tar.gz 2>/dev/null | tail -n +$((KEEP + 1)))
if [ "${#OLD[@]}" -gt 0 ]; then
    printf 'удаляю старые копии:\n'
    printf '  %s\n' "${OLD[@]}"
    rm -f "${OLD[@]}"
fi

echo "архив читается, содержимое:"
tar --list --file "${TARGET}" | head -n 10

cat <<'NOTE'

Напоминание: копия на том же диске копией не является.
В курсе мы отправляем архив на другую машину (node1) — это уже
другая точка отказа, а не второй файл в том же месте.
NOTE
