/*
 * clean_old_builds.groovy — очистка истории сборок задания.
 *
 * Куда вставлять: Manage Jenkins -> Script Console.
 *
 * ЭТО ИСПРАВЛЕННАЯ ВЕРСИЯ скрипта из прежнего курса. В старом варианте
 * было четыре ошибки, из-за которых скрипт либо не запускался, либо делал
 * не то:
 *
 *   1. Jenkins.intance — опечатка; правильное имя Jenkins.instance или
 *      Jenkins.get(). Ошибка «No such property: intance» выглядит так,
 *      будто сломался сам Jenkins, а не опечатка в одном слове.
 *   2. if{it.result == Result.SUCCESS} — фигурные скобки вместо круглых.
 *      В Groovy это замыкание, а не условие: синтаксис неверен,
 *      и скрипт не компилируется.
 *   3. Result не был импортирован (import hudson.model.Result).
 *   4. Скрипт удалял сборки без проверок и без возможности посмотреть,
 *      что он собирается удалить. Удаление истории необратимо.
 *
 * Поэтому здесь по умолчанию работает режим репетиции: скрипт только
 * печатает, что удалил бы. Чтобы удалить по-настоящему, поменяйте
 * dryRun на false осознанно.
 */

import jenkins.model.Jenkins
import hudson.model.Job
import hudson.model.Run
import hudson.model.Result

// ------------------------------------------------------------------ настройки
String jobName = 'FirstJob'      // имя задания; '' — обработать все задания
int keepLast = 10                // сколько последних сборок оставить
boolean dryRun = true            // true — только показать, false — удалить
boolean onlyFailed = false       // true — чистить только неудачные сборки

def jenkins = Jenkins.get()

List<Job> jobs = jobName
        ? [jenkins.getItemByFullName(jobName, Job.class)]
        : jenkins.getAllItems(Job.class).toList()

jobs.each { Job job ->
    if (job == null) {
        println "задание с таким именем не найдено"
        return
    }

    List<Run> builds = job.builds.toList()   // от новых к старым
    println "=== ${job.fullName}: всего сборок ${builds.size()} ==="

    List<Run> candidates = builds
            .drop(keepLast)                                    // последние не трогаем
            .findAll { !onlyFailed || it.result == Result.FAILURE }

    if (candidates.isEmpty()) {
        println '  удалять нечего'
        return
    }

    candidates.each { Run build ->
        def result = build.result ?: 'в процессе'
        if (dryRun) {
            println "  [репетиция] удалил бы #${build.number} (${result}, ${new Date(build.timeInMillis)})"
        } else {
            build.delete()
            println "  удалена #${build.number} (${result})"
        }
    }

    println "  подходящих под удаление: ${candidates.size()}"
}

if (dryRun) {
    println ''
    println 'Это был режим репетиции: ничего не удалено.'
    println 'Чтобы удалить, установите dryRun = false и запустите скрипт заново.'
}

/*
 * ЕСЛИ ХОЧЕТСЯ СБРОСИТЬ НУМЕРАЦИЮ СБОРОК.
 *
 * В прежнем курсе предлагалось после удаления выполнить
 * job.updateNextBuildNumber(1). Работает, но это очень спорное действие:
 * номер сборки попадает в имена артефактов, в теги образов и в записи
 * о выкатах. Сбросив нумерацию, вы получите две разные сборки с номером 1 —
 * и однажды выкатите не то, что собирались.
 *
 * Если всё же нужно:
 *     job.updateNextBuildNumber(1)
 *
 * Обычно правильнее не сбрасывать нумерацию, а задать политику хранения
 * истории прямо в задании (Discard old builds) — тогда чистить вручную
 * не придётся вообще.
 */
