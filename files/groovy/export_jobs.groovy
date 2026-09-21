/*
 * export_jobs.groovy — выгрузка описаний всех заданий в файлы.
 *
 * Куда вставлять: Manage Jenkins -> Script Console.
 *
 * ЗАЧЕМ: описания заданий — это самая ценная и самая незаменимая часть
 * Jenkins. Плагины можно поставить заново, пользователей создать,
 * а вот восстановить двадцать заданий, настроенных за год, — нет.
 *
 * Скрипт выгружает те же config.xml, которые Jenkins хранит у себя.
 * Из них задания восстанавливаются командой create-job (практика 5).
 *
 * РЕЗУЛЬТАТ: каталог /var/lib/jenkins/backups/jobs-<дата>/, где каждому
 * заданию соответствует свой XML-файл. Имена с вложенными папками
 * (папка/задание) превращаются в «папка__задание.xml», потому что
 * слэш в имени файла невозможен.
 */

import jenkins.model.Jenkins
import hudson.model.Job
import hudson.model.TopLevelItem

String backupRoot = '/var/lib/jenkins/backups'
String stamp = new Date().format('yyyyMMdd-HHmmss')
File targetDir = new File(backupRoot, "jobs-${stamp}")

def jenkins = Jenkins.get()
List<Job> jobs = jenkins.getAllItems(Job.class).toList()

if (jobs.isEmpty()) {
    return 'заданий нет, выгружать нечего'
}

if (!targetDir.exists() && !targetDir.mkdirs()) {
    return "не удалось создать каталог ${targetDir} — проверьте права"
}

println "выгружаю ${jobs.size()} заданий в ${targetDir}"

int exported = 0
jobs.sort { it.fullName }.each { Job job ->
    try {
        // getConfigFile() возвращает тот самый XML, по которому портал
        // строит форму задания.
        String xml = job.getConfigFile().asString()
        String fileName = job.fullName.replace('/', '__') + '.xml'
        File out = new File(targetDir, fileName)
        out.setText(xml, 'UTF-8')
        println "  ${job.fullName} -> ${out.name} (${xml.length()} байт)"
        exported++
    } catch (Exception e) {
        println "  ${job.fullName}: ОШИБКА выгрузки — ${e.message}"
    }
}

println ''
println "выгружено: ${exported} из ${jobs.size()}"
return "каталог выгрузки: ${targetDir}"
