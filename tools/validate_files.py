#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Статическая проверка материалов курса «Реализация CI/CD на базе Jenkins».

Запуск из корня курса:
    python tools/validate_files.py
    python tools/validate_files.py --verbose

Что проверяется.

  ФОРМАТ И КОДИРОВКА
    * файлы в UTF-8 без BOM (Jenkins и Linux не любят BOM в первой строке:
      она ломает shebang скрипта и первый ключ YAML);
    * переводы строк LF, а не CRLF: скрипт с CRLF не запустится на Linux
      с сообщением «bad interpreter: No such file or directory»;
    * табуляция в YAML запрещена — это самая частая причина
      «файл выглядит правильно, но не разбирается».

  XML-ОПИСАНИЯ ЗАДАНИЙ (files/jobs/)
    * разбираются как XML;
    * объявлена версия 1.0, а не 1.1: Jenkins выгружает свои файлы как 1.1,
      и многие инструменты такую версию не принимают.

  YAML (JCasC, docker compose)
    * разбирается, без табов и без дублирующихся ключей;
    * нет паролей и ключей открытым текстом — только ${ПЕРЕМЕННЫЕ}.

  JSON (daemon.json)
    * разбирается;
    * нет ключей, начинающихся с подчёркивания: Docker разбирает этот файл
      строго и отказывается стартовать из-за неизвестного поля.

  GROOVY И JENKINSFILE (files/pipelines/, files/groovy/, files/shared-library/)
    * скобки, круглые скобки и кавычки сбалансированы;
    * декларативный конвейер содержит обязательные блоки pipeline и stages;
    * нет опечаток, которые были в прежней версии курса
      (agent nay, Jenkins.intance, Menage Jenkins, discord old builds).

  SHELL-СКРИПТЫ (files/scripts/)
    * есть shebang и режим set -euo pipefail;
    * синтаксис проверяется через bash -n, если bash доступен.

  INI (files/gitea/app.ini)
    * разбирается, разделы не дублируются;
    * значения-заполнители отмечены как напоминания, а не как ошибки.

  HTML (files/www/)
    * маркеры подстановки __BUILD_NUMBER__ и __GIT_COMMIT__ на месте:
      на них завязаны и конвейер, и сквозной тест;
    * нет устаревших тегов <font> и атрибута bgcolor.

  ПЕРЕКРЁСТНЫЕ ССЫЛКИ
    * каждый путь вида files/... из текстов практик существует;
    * идентификаторы credentials, упомянутые в разных файлах, совпадают.

Скрипт ничего не меняет, только сообщает о проблемах.
Код возврата 0 — ошибок нет, 1 — есть.
"""

import configparser
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET

try:
    import yaml
except ImportError:
    sys.exit("Нужен PyYAML:  pip install pyyaml")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VERBOSE = "--verbose" in sys.argv

errors = []
warnings = []
checked = []


def err(path, msg):
    errors.append("%s: %s" % (rel(path), msg))


def warn(path, msg):
    warnings.append("%s: %s" % (rel(path), msg))


def ok(path, msg=None):
    checked.append("%s%s" % (rel(path), (": " + msg) if msg else ""))


def rel(path):
    return os.path.relpath(path, ROOT).replace(os.sep, "/")


def safe_read(path):
    """Читает файл как UTF-8; возвращает None, если файл не в UTF-8.

    Такие файлы уже отмечены ошибкой при проверке кодировки, но проверка
    не должна падать из-за них сама: иначе одна старая заметка
    в неправильной кодировке ломает разбор всего курса.
    """
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read()
    except (UnicodeDecodeError, OSError):
        return None


def say(msg):
    if VERBOSE:
        print(msg)


# ------------------------------------------------------------------ файлы

def course_files():
    """Все файлы курса, которые имеет смысл проверять."""
    patterns = [
        "files/**/*.xml",
        "files/**/*.yaml",
        "files/**/*.yml",
        "files/**/*.json",
        "files/**/*.ini",
        "files/**/*.sh",
        "files/**/*.html",
        "files/**/*.groovy",
        "files/**/*.txt",
        "files/**/*.md",
        "files/**/Jenkinsfile*",
        "*.txt",
        "*.md",
    ]
    found = set()
    for pattern in patterns:
        for path in glob.glob(os.path.join(ROOT, pattern), recursive=True):
            if os.path.isfile(path):
                found.add(path)
    return sorted(found)


# --------------------------------------------------------------- кодировка

BOM = b"\xef\xbb\xbf"


def check_encoding(path):
    with open(path, "rb") as fh:
        raw = fh.read()

    if raw.startswith(BOM):
        err(path, "файл начинается с BOM; сохраните его как UTF-8 без BOM")
    if b"\r\n" in raw:
        err(path, "переводы строк CRLF; для Linux нужны LF")

    try:
        raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        err(path, "не UTF-8: %s" % exc)
        return None
    return raw.decode("utf-8")


def check_tabs(path, text):
    """Табуляция допустима в shell и Makefile, в YAML и INI — нет."""
    if not path.endswith((".yaml", ".yml", ".ini")):
        return
    for number, line in enumerate(text.splitlines(), 1):
        if line.startswith("\t") or "\t" in line.split("#")[0]:
            err(path, "строка %d: табуляция; в YAML и INI отступы только пробелами"
                % number)
            return


def check_cyrillic_lookalikes(path, text):
    """Ловушка вида svс-deploy: кириллическая «с» внутри латинского слова.

    Такая подмена не видна ни в редакторе, ни в diff, а Jenkins сообщает
    о ней как о «задании, которого нет». Проверяем только код и структуры
    данных: в тексте практик кириллица — это норма.
    """
    if not path.endswith((".xml", ".yaml", ".yml", ".json", ".ini",
                          ".sh", ".groovy")):
        if "Jenkinsfile" not in os.path.basename(path):
            return

    separators = re.compile(r"[:./<>@,;_\-–—'\"\[\](){}|\\=+*?!\s]+")
    for number, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("#") or line.lstrip().startswith("<!--"):
            continue
        for chunk in separators.split(line):
            has_latin = re.search(r"[A-Za-z]", chunk)
            has_cyrillic = re.search(r"[А-Яа-яЁё]", chunk)
            if has_latin and has_cyrillic:
                err(path, "строка %d: в «%s» смешаны латиница и кириллица — "
                          "проверьте подменённые буквы" % (number, chunk))
                break


# --------------------------------------------------------------- тип файла

def is_xml(path):
    return path.endswith(".xml")


def is_yaml(path):
    return path.endswith((".yaml", ".yml"))


def is_json(path):
    return path.endswith(".json")


def is_ini(path):
    return path.endswith(".ini")


def is_shell(path):
    return path.endswith(".sh")


def is_groovy(path):
    return path.endswith(".groovy") or "Jenkinsfile" in os.path.basename(path)


def is_html(path):
    return path.endswith(".html")


# -------------------------------------------------------------------- XML

def strip_xml_comments(text):
    """Убирает комментарии XML.

    Нужно, чтобы пояснение «Jenkins выгружает файлы с версией 1.1»
    не принималось за саму версию 1.1.
    """
    return re.sub(r"<!--.*?-->", "", text, flags=re.S)


def validate_xml(path, text):
    code = strip_xml_comments(text)
    if re.search(r"version\s*=\s*['\"]1\.1['\"]", code):
        err(path, "объявлена версия XML 1.1; используйте 1.0 — "
                  "разбор такой версии поддерживают не все инструменты")
    try:
        root = ET.fromstring(text)
    except ET.ParseError as exc:
        err(path, "не разбирается как XML: %s\n      внутри команды сборки "
                  "символ & и угловые скобки нужно экранировать: "
                  "&amp;amp; вместо &" % exc)
        return
    if root.tag != "project":
        warn(path, "корневой элемент <%s>, ожидался <project>" % root.tag)
    for required in ("description", "builders"):
        if root.find(required) is None:
            warn(path, "нет раздела <%s>" % required)
    ok(path, "XML разбирается")


# ------------------------------------------------------------------- YAML

class StrictLoader(yaml.SafeLoader):
    """SafeLoader, который ругается на дублирующиеся ключи.

    В YAML дубликат ключа не ошибка синтаксиса: побеждает последнее
    значение, а первое молча теряется. В конфигурации это выглядит так,
    будто правка «не применилась».
    """


def _no_duplicates(loader, node, deep=False):
    mapping = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in mapping:
            raise yaml.constructor.ConstructorError(
                None, None, "дублирующийся ключ %r" % (key,), key_node.start_mark)
        mapping[key] = loader.construct_object(value_node, deep=deep)
    return mapping


StrictLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _no_duplicates)

SECRET_PATTERNS = [
    (re.compile(r"password\s*:\s*(?![\"']?\$\{)(?![\"']?\$)[^\s\"'{][^\s]*", re.I),
     "похоже на пароль открытым текстом"),
    (re.compile(r"secret\s*:\s*(?![\"']?\$\{)[^{\s\"'][^\s]*", re.I),
     "похоже на секрет открытым текстом"),
    (re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
     "приватный ключ в файле курса"),
]


def validate_yaml(path, text):
    try:
        data = yaml.load(text, Loader=StrictLoader)
    except yaml.YAMLError as exc:
        err(path, "не разбирается как YAML: %s" % exc)
        return
    if data is None:
        warn(path, "файл пуст")
        return
    ok(path, "YAML разбирается")
    for pattern, message in SECRET_PATTERNS:
        for number, line in enumerate(text.splitlines(), 1):
            if line.lstrip().startswith("#"):
                continue
            if pattern.search(line):
                err(path, "строка %d: %s — значение должно приходить "
                          "из переменной окружения" % (number, message))


# ------------------------------------------------------------------- JSON

def validate_json(path, text):
    try:
        data = json.loads(text)
    except json.JSONDecodeError as exc:
        err(path, "не разбирается как JSON: %s" % exc)
        return
    ok(path, "JSON разбирается")

    def walk(node, prefix=""):
        if isinstance(node, dict):
            for key, value in node.items():
                if key.startswith("_"):
                    err(path, "ключ %r%s: Docker разбирает этот файл строго "
                              "и не стартует из-за неизвестного поля; "
                              "пояснения вынесите в отдельный текст"
                        % (key, prefix))
                walk(value, prefix + "/" + key)
        elif isinstance(node, list):
            for item in node:
                walk(item, prefix)

    walk(data)


# -------------------------------------------------------------------- INI

def validate_ini(path, text):
    parser = configparser.ConfigParser(strict=True)
    # В Gitea (как и в git config) ключи могут стоять до первого раздела —
    # они образуют глобальную область. configparser такой файл не примет,
    # поэтому такие ключи собираем в отдельный раздел.
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith((";", "#")):
            continue
        if not stripped.startswith("["):
            text = "[global]\n" + text
        break
    try:
        parser.read_string(text)
    except configparser.Error as exc:
        err(path, "не разбирается как INI: %s" % exc)
        return
    ok(path, "INI разбирается, разделов: %d" % len(parser.sections()))

    for section in parser.sections():
        for key, value in parser.items(section):
            if "заполните" in value.lower():
                warn(path, "[%s] %s: значение-заполнитель, подставьте своё"
                     % (section, key))


# ------------------------------------------------------ Groovy и Jenkinsfile

def strip_code(text):
    """Убирает комментарии и строковые литералы, оставляя структуру кода.

    Нужно это для честной проверки баланса скобок: в строках и комментариях
    скобки встречаются постоянно (например, в shell-скриптах внутри sh),
    и на них проверка сбивалась бы.
    """
    result = []
    i = 0
    n = len(text)
    while i < n:
        ch = text[i]
        # комментарий до конца строки
        if text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j == -1 else j
            continue
        # блочный комментарий
        if text.startswith("/*", i):
            j = text.find("*/", i + 2)
            i = n if j == -1 else j + 2
            continue
        # тройные кавычки
        if text.startswith("'''", i) or text.startswith('"""', i):
            quote = text[i:i + 3]
            j = text.find(quote, i + 3)
            i = n if j == -1 else j + 3
            continue
        # одинарные и двойные кавычки
        if ch in "'\"":
            quote = ch
            i += 1
            while i < n:
                if text[i] == "\\":
                    i += 2
                    continue
                if text[i] == quote:
                    i += 1
                    break
                if text[i] == "\n" and quote == "'":
                    break
                i += 1
            continue
        result.append(ch)
        i += 1
    return "".join(result)


BRACKETS = {"{": "}", "(": ")", "[": "]"}


def validate_groovy(path, text):
    code = strip_code(text)

    stack = []
    closers = {v: k for k, v in BRACKETS.items()}
    for position, ch in enumerate(code):
        if ch in BRACKETS:
            stack.append((ch, position))
        elif ch in closers:
            if not stack:
                err(path, "лишняя закрывающая скобка %r" % ch)
                return
            opener, _ = stack.pop()
            if opener != closers[ch]:
                err(path, "несовпадение скобок: %r закрыта как %r" % (opener, ch))
                return
    if stack:
        opener, position = stack[-1]
        line = text[:position].count("\n") + 1
        err(path, "не закрыта скобка %r (строка %d)" % (opener, line))
        return

    # Незакрытая кавычка: после снятия строк в коде не должно оставаться
    # символов кавычек.
    if "'" in code or '"' in code:
        remaining = code.count("'") + code.count('"')
        warn(path, "похоже на незакрытую кавычку (%d шт. осталось в коде)"
             % remaining)

    if "pipeline" in text and "stages" in text:
        for block in ("pipeline", "stages"):
            if not re.search(r"\b%s\s*\{" % block, text):
                err(path, "в декларативном конвейере нет блока %s { }" % block)

    if re.search(r"\b%s\s*\{" % "pipeline", text) is None and "pipeline" in text:
        warn(path, "в файле упомянут pipeline, но блока pipeline { } нет")

    # Опечатку «agent nay» ищет общий список TYPO_RULES ниже: там учтено,
    # что в пояснениях она приводится в кавычках как пример.

    ok(path, "скобки сбалансированы")


# ------------------------------------------------------------------- shell

def validate_shell(path, text):
    if not text.startswith("#!"):
        err(path, "нет shebang в первой строке")
    elif "bash" not in text.splitlines()[0]:
        warn(path, "shebang не указывает на bash: %r" % text.splitlines()[0])

    if "set -euo pipefail" not in text and "set -eu" not in text:
        warn(path, "нет «set -euo pipefail»: скрипт продолжит работу "
                   "после ошибки, и это заметят позже")

    # Проверяем, что bash вообще работоспособен: на Windows в PATH часто
    # оказывается заглушка WSL без установленного дистрибутива. Она
    # завершается с ошибкой на любом входе, и принимать это за ошибку
    # в скрипте нельзя.
    bash = shutil.which("bash")
    bash_works = False
    if bash:
        probe = subprocess.run([bash, "-c", "echo ok"],
                               capture_output=True, text=True)
        bash_works = probe.returncode == 0 and "ok" in probe.stdout

    if not bash_works:
        warn(path, "bash недоступен для проверки синтаксиса "
                   "(на Windows это может быть заглушка WSL)")
    else:
        result = subprocess.run([bash, "-n", path], capture_output=True, text=True)
        if result.returncode != 0:
            err(path, "синтаксическая ошибка: %s" % result.stderr.strip())
        else:
            ok(path, "синтаксис проверен bash -n")

    if "rm -rf /" in text or "rm -rf /*" in text:
        err(path, "опасное удаление корня файловой системы")


# -------------------------------------------------------------------- HTML

def validate_html(path, text):
    if "__BUILD_NUMBER__" not in text:
        err(path, "нет маркера __BUILD_NUMBER__: на него завязан конвейер")
    if "__GIT_COMMIT__" not in text:
        err(path, "нет маркера __GIT_COMMIT__: на него завязан конвейер")
    # Комментарии не проверяем: в них эти слова встречаются как пояснение.
    code = re.sub(r"<!--.*?-->", "", text, flags=re.S).lower()
    for old in ("<font", "bgcolor="):
        if old in code:
            err(path, "устаревшая разметка %r; используйте CSS" % old)
    ok(path, "маркеры подстановки на месте")


# ---------------------------------------------------------------- опечатки

TYPO_RULES = [
    (r"\bJenkins\.intance\b",
     "опечатка Jenkins.intance — правильно Jenkins.instance или Jenkins.get()"),
    (r"\bMenage Jenkins\b",
     "опечатка Menage — правильно Manage Jenkins"),
    (r"discord old builds",
     "опечатка — правильно Discard old builds"),
    (r"openjdk-17",
     "Java 17 устарела для текущего Jenkins LTS: нужна 21"),
    (r"jenkins\.io\.key",
     "устаревший адрес ключа репозитория: с 2023 года jenkins.io-2023.key"),
    (r"python:3\.[67]\b",
     "образ снят с поддержки — возьмите актуальный"),
    (r"\bPublish over SSH\b",
     "Publish over SSH не поддерживается; в курсе используется ssh-agent и rsync"),
    (r"\bagent\s+nay\b",
     "опечатка «agent nay»: правильно «agent any»"),
    (r"\bWolrd\b|\bWrold\b",
     "опечатка в тексте журнала сборки"),
    (r"manager\s+jenkins\b",
     "меню называется Manage Jenkins"),
    (r"localhost:8080",
     "в курсе используется адрес сервера 10.0.2.5:8080: localhost "
     "работает только на самой машине"),
    (r"\bgithub\.com\b",
     "в курсе используется свой Git-сервер Gitea: из облака вебхук "
     "в лабораторию не дойдёт"),
]

# Практики, в которых старые опечатки разбираются намеренно.
HISTORICAL_OK = set()

# Слова, которые означают «здесь об этом говорится осознанно».
# «устаре» — намеренно неполное слово: так проверка ловит и «устарел»,
# и «устаревший», и «устаревшие» одновременно.
CONTEXT_OK = ("исправлено", "опечатк", "устаре", "не поддерж", "заброш",
              "не выпускался", "прежн", "раньше", "было",
              "самой машине", "самой машины", "локальн",
              "без -s", "идёт на http://localhost")


def in_quotes(line, match):
    """Стоит ли найденный текст внутри кавычек или «ёлочек».

    Нужно ради фраз вида «agent nay»: там ошибка приводится как пример,
    и ругаться на неё нельзя.
    """
    for opener, closer in (("«", "»"), ("\"", "\""), ("'", "'"), ("`", "`")):
        left = line.rfind(opener, 0, match.start())
        right = line.find(closer, match.end())
        if left != -1 and right != -1 and left < match.start() and right >= match.end():
            return True
    return False


def check_typos(path, text):
    """Ищет опечатки прежней версии курса.

    В практиках, которые их разбирают, они встречаются намеренно —
    в разделе «ИСПРАВЛЕНО» или в кавычках как пример. Такие случаи
    пропускаются: иначе проверка ругалась бы на собственные пояснения.
    """
    basename = os.path.basename(path)
    lines = text.splitlines()
    for pattern, message in TYPO_RULES:
        for number, line in enumerate(lines, 1):
            match = re.search(pattern, line, re.I)
            if not match:
                continue
            if in_quotes(line, match):
                continue
            context = "\n".join(lines[max(0, number - 5):number + 3]).lower()
            if any(word in context for word in CONTEXT_OK):
                continue
            if basename in HISTORICAL_OK:
                continue
            err(path, "строка %d: %s" % (number, message))


# --------------------------------------------------- перекрёстные ссылки

FILE_REFERENCE = re.compile(r"\bfiles/[A-Za-z0-9_./@-]+")
CREDENTIAL_REF = re.compile(r"credentials:\s*\[\s*'([a-z0-9-]+)'|credentialsId:\s*'([a-z0-9-]+)'")


def check_file_references(paths):
    missing = set()
    for path in paths:
        if not path.endswith(".txt"):
            continue
        text = safe_read(path)
        if text is None:
            continue
        for match in FILE_REFERENCE.finditer(text):
            ref = match.group(0).rstrip(".,;:`)")
            # Проверяем ссылки только на те каталоги, которые поставляются
            # вместе с курсом: пути вроде build/deploy создаёт конвейер.
            if ref.startswith(("files/scripts/", "files/www/", "files/jobs/",
                               "files/pipelines/", "files/groovy/", "files/jcasc/",
                               "files/shared-library/", "files/gitea/", "files/docker/")):
                full = os.path.join(ROOT, ref.replace("/", os.sep))
                if not os.path.exists(full) and "${" not in ref:
                    missing.add((rel(path), ref))
    for path, ref in sorted(missing):
        err(path, "ссылка на несуществующий файл: %s" % ref)


def check_credentials_ids(paths):
    """Идентификаторы credentials должны совпадать во всех файлах курса.

    Расхождение здесь — самая обидная поломка конвейера: задание находит
    credentials по строковому идентификатору, и опечатка проявляется
    как «credentials not found» уже во время сборки.
    """
    used = {}
    for path in paths:
        if not path.endswith((".txt", ".groovy", ".yaml")) and \
                "Jenkinsfile" not in os.path.basename(path):
            continue
        text = safe_read(path)
        if text is None:
            continue
        for match in CREDENTIAL_REF.finditer(text):
            identifier = match.group(1) or match.group(2)
            used.setdefault(identifier, set()).add(rel(path))

    declared = set()
    jcasc = os.path.join(ROOT, "files", "jcasc", "jenkins.yaml")
    if os.path.exists(jcasc):
        for line in open(jcasc, encoding="utf-8"):
            m = re.search(r"^\s+id:\s*\"?([a-z0-9-]+)\"?\s*$", line)
            if m:
                declared.add(m.group(1))

    for identifier, where in sorted(used.items()):
        if identifier not in declared:
            warn("files/jcasc/jenkins.yaml",
                 "credentials %r используется в %s, но не объявлен в конфигурации"
                 % (identifier, ", ".join(sorted(where))))


# ------------------------------------------------------------------- отчёт

def main():
    paths = course_files()
    if not paths:
        sys.exit("Не найдено ни одного файла курса: запустите скрипт из корня курса")

    print("Проверяю файлов: %d\n" % len(paths))

    for path in paths:
        text = check_encoding(path)
        if text is None:
            continue
        check_tabs(path, text)
        check_cyrillic_lookalikes(path, text)
        check_typos(path, text)

        if is_xml(path):
            validate_xml(path, text)
        elif is_yaml(path):
            validate_yaml(path, text)
        elif is_json(path):
            validate_json(path, text)
        elif is_ini(path):
            validate_ini(path, text)
        elif is_shell(path):
            validate_shell(path, text)
        elif is_groovy(path):
            validate_groovy(path, text)
        elif is_html(path):
            validate_html(path, text)
        else:
            ok(path)

    check_file_references(paths)
    check_credentials_ids(paths)

    if VERBOSE:
        print("Проверено:")
        for line in checked:
            print("  " + line)
        print("")

    if warnings:
        print("ПРЕДУПРЕЖДЕНИЯ (%d):" % len(warnings))
        for line in warnings:
            print("  ! " + line)
        print("")

    if errors:
        print("ОШИБКИ (%d):" % len(errors))
        for line in errors:
            print("  x " + line)
        print("")
        print("Итог: ошибок %d, предупреждений %d" % (len(errors), len(warnings)))
        return 1

    print("Ошибок нет. Предупреждений: %d" % len(warnings))
    return 0


if __name__ == "__main__":
    sys.exit(main())
