/*
 * src/ru/iklimarev/BuildInfo.groovy — обычный Groovy-класс в общей
 * библиотеке (практика 13).
 *
 * Разница между vars/ и src/ проста и важна:
 *   vars/  — это шаги конвейера; имя файла становится именем шага;
 *   src/   — это классы. Их не вызывают как шаг, их создают через new.
 *
 * Классы нужны там, где есть логика, а не последовательность шагов:
 * вычисления, разбор данных, проверки. Держать такое в vars/ неудобно —
 * шаг описан одним методом call(), и он быстро превращается в свалку.
 *
 * Класс обязательно должен быть Serializable. Конвейер Jenkins может
 * приостановить выполнение (например, на стадии с ручным подтверждением)
 * и записать состояние на диск — несериализуемый объект это сломает,
 * причём ошибка будет выглядеть загадочно: «java.io.NotSerializableException».
 */
package ru.iklimarev

class BuildInfo implements Serializable {
    private static final long serialVersionUID = 1L

    String job = 'unknown'
    String buildNumber = '0'
    String commit = 'unknown'
    String agent = 'unknown'

    BuildInfo() {
    }

    BuildInfo(Map values) {
        if (values?.job)         { this.job = values.job as String }
        if (values?.buildNumber) { this.buildNumber = values.buildNumber as String }
        if (values?.commit)      { this.commit = values.commit as String }
        if (values?.agent)       { this.agent = values.agent as String }
    }

    /** Строка для журнала сборки. */
    String summary() {
        return """
Сборка ${job} #${buildNumber}
  ревизия : ${commit}
  агент   : ${agent}
""".trim()
    }

    /** Проверка, что данные непустые: используется перед выкатом. */
    boolean isComplete() {
        return job != 'unknown' && commit != 'unknown' && buildNumber != '0'
    }
}
