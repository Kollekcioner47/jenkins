/*
 * inventory_report.groovy — инвентаризация Jenkins.
 *
 * Куда вставлять: Manage Jenkins -> Script Console.
 * Ответ на вопрос «что у нас вообще есть» — самый частый вопрос
 * администратора, и обычно на него ищут ответ глазами по порталу.
 *
 * ЗАЧЕМ ЭТО ЧЕРЕЗ GROOVY, А НЕ ЧЕРЕЗ ПОРТАЛ: портал показывает то,
 * что помещается на экран. Здесь мы получаем данные в виде, который
 * можно сравнить с прошлым запуском или отправить коллеге.
 *
 * ВНИМАНИЕ: Script Console выполняется с полными правами администратора
 * и без ограничений. Скрипт, скопированный из интернета, — это отличный
 * способ потерять Jenkins. Читайте то, что запускаете.
 */

import jenkins.model.Jenkins
import hudson.model.Job
import hudson.model.Result
import hudson.PluginWrapper

def jenkins = Jenkins.get()

println '=== Контроллер ==='
println "версия Jenkins : ${Jenkins.getVersion()}"
println "URL портала    : ${jenkins.rootUrl}"
println "JENKINS_HOME   : ${jenkins.rootDir}"
println "экзекьюторов   : ${jenkins.numExecutors} (на контроллере)"
println "режим          : ${jenkins.mode}"

println ''
println '=== Агенты ==='
def computers = jenkins.computers
computers.each { c ->
    def online = c.online ? 'online' : 'OFFLINE'
    def labels = c.node?.labelString ?: ''
    println String.format('  %-12s %-8s экзекьюторов: %-3d метки: %s',
            c.name, online, c.numExecutors, labels)
}
println "  всего агентов (с контроллером): ${computers.size()}"

println ''
println '=== Задания ==='
def jobs = jenkins.getAllItems(Job.class).toList()
jobs.sort { it.fullName }
println "  всего заданий: ${jobs.size()}"
jobs.each { job ->
    def last = job.lastBuild
    def status = last?.result?.toString() ?: 'не запускалось'
    println String.format('  %-32s сборок: %-4d последняя: %-9s %s',
            job.fullName, job.builds.size(), status, last ? new Date(last.timeInMillis) : '')
}

def failing = jobs.findAll { it.lastBuild?.result == Result.FAILURE }
if (failing) {
    println ''
    println '=== Проваленные последние сборки ==='
    failing.each { println "  ${it.fullName} -> ${it.lastBuild.displayName}" }
}

println ''
println '=== Плагины ==='
def plugins = jenkins.pluginManager.plugins.toList()
def withUpdates = jenkins.pluginManager.getPluginsWithUpdateAvailable()
println "  установлено плагинов: ${plugins.size()}"
println "  доступны обновления:  ${withUpdates.size()}"
withUpdates.each { PluginWrapper p ->
    println "    ${p.shortName}: ${p.version} -> ${p.getUpdateInfo()?.version}"
}
def disabled = plugins.findAll { !it.enabled }
if (disabled) {
    println "  ОТКЛЮЧЕННЫЕ плагины: ${disabled*.shortName}"
}

println ''
println '=== Очередь сборок ==='
def queue = jenkins.queue.items
println "  в очереди: ${queue.size()}"
queue.each { item ->
    println "  ${item.task?.fullName} — причина: ${item.why ?: 'не указана'}"
}

println ''
println '=== Пользователи ==='
jenkins.securityRealm.allUsers().each { u ->
    println "  ${u.id} (${u.fullName}), токенов: ${u.getProperty(hudson.security.ApiTokenProperty)?.tokenList?.size() ?: 0}"
}

// Итоговая строка: её удобно сравнивать между запусками.
return "инвентаризация завершена: заданий ${jobs.size()}, агентов ${computers.size()}, плагинов ${plugins.size()}"
