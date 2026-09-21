/*
 * vars/deployToNodes.groovy — выкат сайта на несколько серверов
 * (практика 13).
 *
 * Один шаг вместо двух одинаковых блоков в Jenkinsfile. Пока серверов два,
 * копипаста терпима; когда их двадцать, она превращается в источник ошибок:
 * правку вносят в девятнадцать мест из двадцати.
 *
 * Что важно в реализации:
 *   * hosts приходит списком, а конвейеры вызывают шаг по-разному
 *     (строкой из параметра, списком из переменной) — поэтому приводим
 *     к списку явно;
 *   * sshagent подключает приватный ключ, взяв его из credentials.
 *     Текст ключа при этом не попадает ни в переменные, ни в лог;
 *   * String host = rawHost as String — объявленная копия переменной цикла:
 *     иначе замыкания в параллельных ветках захватят одну и ту же
 *     переменную, и все ветки уйдут на последний сервер. Это классическая
 *     ловушка Groovy в конвейерах:
 *     ошибка выглядит так, будто выкат «работает», но только на одном
 *     сервере.
 */
def call(Map config = [:]) {
    List hosts = (config.hosts ?: ['10.0.2.13', '10.0.2.14']) as List
    String siteDir = (config.siteDir ?: 'build/deploy') as String
    String deployUser = (config.deployUser ?: 'jenkins') as String
    String expectedText = (config.expectedText ?: 'Hello from DevOps Engineer') as String
    String buildNumber = (config.buildNumber ?: env.BUILD_NUMBER) as String
    String credentialsId = (config.credentialsId ?: 'node-ssh') as String

    if (hosts.isEmpty()) {
        error 'deployToNodes: не передан ни один сервер'
    }
    echo "Выкат сборки ${buildNumber} на серверы: ${hosts.join(', ')}"

    Map branches = [:]
    hosts.each { rawHost ->
        String host = rawHost as String
        branches["выкат на ${host}"] = {
            sshagent(credentials: [credentialsId]) {
                sh """
                    set -eu
                    target=/tmp/site-deploy-${buildNumber}

                    ssh -o StrictHostKeyChecking=accept-new \\
                        ${deployUser}@${host} "rm -rf \${target} && mkdir -p \${target}"

                    rsync -a --delete -e "ssh -o StrictHostKeyChecking=accept-new" \\
                        ${siteDir}/ ${deployUser}@${host}:\${target}/

                    ssh -o StrictHostKeyChecking=accept-new ${deployUser}@${host} \\
                        "cd \${target} && bash deploy_site.sh deploy www"

                    ssh -o StrictHostKeyChecking=accept-new ${deployUser}@${host} \\
                        "bash \${target}/smoke_test.sh http://127.0.0.1/ '${expectedText}' ${buildNumber}"

                    echo "сервер ${host}: выкат и проверка пройдены"
                """
            }
        }
    }

    // parallel выполняется всеми ветками сразу. Одна упавшая ветка
    // останавливает шаг целиком — это и нужно: выкат на половину серверов
    // хуже, чем неудачный выкат.
    parallel branches
}
