#!/usr/bin/env bash
#
# Атомарный выкат статического сайта и откат к предыдущему релизу.
#
# Запускается НА ЦЕЛЕВОМ сервере (node1 или node2), а не на контроллере
# Jenkins: конвейер копирует этот скрипт и каталог со сайтом на машину
# и вызывает его там. Так на сервере не нужен ни агент, ни Java,
# ни право что-либо делать кроме выката.
#
# Использование:
#     deploy_site.sh deploy   <каталог-с-файлами>   выкатить новый релиз
#     deploy_site.sh rollback                       вернуться к предыдущему
#     deploy_site.sh list                           список релизов
#     deploy_site.sh current                        какой релиз отдаётся
#
# ПОЧЕМУ ИМЕННО ТАК, А НЕ «rsync ПОВЕРХ ПРЕЖНИХ ФАЙЛОВ»
#
# При копировании поверх остаются файлы, которых в новой версии уже нет:
# страница «удалили», а она продолжает открываться с сервера. Ещё хуже,
# что в момент копирования сайт отдаётся в полуразобранном состоянии:
# index.html уже новый, стили ещё старые.
#
# Здесь файлы сначала копируются целиком в отдельный каталог релиза,
# и только потом одним действием переключается симлинк current.
# Переключение симлинка — атомарная операция: посетитель либо видит
# старую версию целиком, либо новую целиком, третьего не бывает.
# Откат — это переключение симлинка на предыдущий релиз.

set -euo pipefail

SITE_NAME="${SITE_NAME:-site}"
WEB_ROOT="${WEB_ROOT:-/var/www/${SITE_NAME}}"
RELEASES_DIR="${WEB_ROOT}/releases"
CURRENT_LINK="${WEB_ROOT}/current"
KEEP_RELEASES="${KEEP_RELEASES:-5}"

die() { echo "ошибка: $*" >&2; exit 1; }

cmd_deploy() {
    local source_dir="${1:-}"
    [ -n "${source_dir}" ] || die "укажите каталог с файлами сайта"
    [ -d "${source_dir}" ] || die "нет каталога ${source_dir}"
    [ -f "${source_dir}/index.html" ] || die "в ${source_dir} нет index.html"

    # Маркер подстановки не должен уехать на сервер: значит, конвейер
    # не выполнил шаг подстановки, и на сайте будет видно __BUILD_NUMBER__.
    if grep -q '__BUILD_NUMBER__' "${source_dir}/index.html"; then
        die "в index.html остался маркер __BUILD_NUMBER__: шаг подстановки не выполнен"
    fi

    local stamp release
    stamp="$(date +%Y%m%d-%H%M%S)"
    # $$ в имени — чтобы два одновременных выката не попали в один каталог.
    release="${RELEASES_DIR}/${stamp}-$$"

    mkdir -p "${release}"
    # cp -a сохраняет права и время; ./ в конце копирует содержимое,
    # а не сам каталог.
    cp -a "${source_dir}/." "${release}/"

    # Переключение симлинка: сначала создаём ссылку рядом, потом одним
    # mv переименовываем её поверх current. Переименование в пределах
    # одной файловой системы атомарно — окна, когда сайта нет, не возникает.
    ln -sfn "${release}" "${CURRENT_LINK}.new"
    mv -Tf "${CURRENT_LINK}.new" "${CURRENT_LINK}"

    echo "выкат выполнен: ${release}"

    cmd_rotate
    cmd_current
}

cmd_rollback() {
    # Второй по свежести релиз и есть предыдущий.
    local previous
    previous="$(ls -1dt "${RELEASES_DIR}"/*/ 2>/dev/null | sed -n 2p)"
    [ -n "${previous}" ] || die "предыдущего релиза нет, откатываться некуда"

    local target
    target="${previous%/}"
    ln -sfn "${target}" "${CURRENT_LINK}.new"
    mv -Tf "${CURRENT_LINK}.new" "${CURRENT_LINK}"
    echo "откат выполнен: ${target}"
    cmd_current
}

cmd_rotate() {
    # Старые релизы удаляем, иначе диск однажды кончится, и выкат
    # упадёт на самой неприятной стадии. Сколько хранить — вопрос
    # привычки: пять релизов обычно покрывают несколько дней работы.
    local old
    old="$(ls -1dt "${RELEASES_DIR}"/*/ 2>/dev/null | tail -n +$((KEEP_RELEASES + 1)) || true)"
    if [ -n "${old}" ]; then
        echo "${old}" | xargs -r rm -rf
        echo "удалены старые релизы:"
        echo "${old}" | sed 's/^/  /'
    fi
}

cmd_current() {
    echo "сейчас отдаётся: $(readlink -f "${CURRENT_LINK}")"
}

cmd_list() {
    ls -1dt "${RELEASES_DIR}"/*/ 2>/dev/null | sed 's#/$##' || echo "релизов нет"
}

case "${1:-}" in
    deploy)   shift; cmd_deploy "${1:-}" ;;
    rollback) cmd_rollback ;;
    rotate)   cmd_rotate ;;
    current)  cmd_current ;;
    list)     cmd_list ;;
    *)
        cat <<USAGE
Использование:
  $0 deploy <каталог-с-файлами>   выкатить новый релиз
  $0 rollback                     вернуться к предыдущему релизу
  $0 rotate                       удалить старые релизы
  $0 list                         список релизов
  $0 current                      какой релиз отдаётся сейчас
USAGE
        exit 2
        ;;
esac
