/*
 * vars/rollbackNodes.groovy — откат сайта к предыдущему релизу
 * (практика 13).
 *
 * Отдельный шаг, а не «то же самое, но в блоке post»: откат используют
 * и при провале конвейера, и вручную, и в ночном дежурном скрипте.
 * Логика в одном месте — правка тоже в одном.
 *
 * Обратите внимание: if (ignoreErrors) вокруг каждой ветки. Откат — это
 * аварийная операция, и её задача — вернуть рабочую версию везде, где
 * получится. Падение на первом же недоступном сервере оставило бы
 * остальные с новой версией, то есть в самом плохом состоянии:
 * часть серверов на новой версии, часть на старой.
 */
def call(Map config = [:]) {
    List hosts = (config.hosts ?: []) as List
    String buildNumber = (config.buildNumber ?: env.BUILD_NUMBER) as String
    String deployUser = (config.deployUser ?: 'jenkins') as String
    String credentialsId = (config.credentialsId ?: 'node-ssh') as String
    boolean ignoreErrors = config.containsKey('ignoreErrors') ? (config.ignoreErrors as boolean) : true

    if (hosts.isEmpty()) {
        echo 'rollbackNodes: серверы не переданы, откатывать нечего'
        return
    }

    echo "Откат на серверы: ${hosts.join(', ')}"
    List failed = []

    sshagent(credentials: [credentialsId]) {
        hosts.each { rawHost ->
            String host = rawHost as String
            def result = sh(
                script: """
                    set -u
                    target=/tmp/site-deploy-${buildNumber}
                    if [ ! -f "\${target}/deploy_site.sh" ]; then
                        echo "нет скрипта выката в \${target} — откат пропущен"
                        exit 0
                    fi
                    ssh -o StrictHostKeyChecking=accept-new ${deployUser}@${host} \\
                        "bash \${target}/deploy_site.sh rollback"
                """,
                returnStatus: true
            )
            if (result != 0) {
                failed << host
                echo "откат на ${host} не удался (код ${result})"
            } else {
                echo "откат на ${host} выполнен"
            }
        }
    }

    if (failed && !ignoreErrors) {
        error "откат не выполнен на серверах: ${failed.join(', ')}"
    }
    if (failed) {
        // Сборка помечается нестабильной, а не проваленной: причина провала
        // была другой, а информация о неудачном откате должна остаться.
        unstable("откат не выполнен на серверах: ${failed.join(', ')}")
    }
}
