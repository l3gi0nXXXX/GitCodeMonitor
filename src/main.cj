package gitcodemonitor

import std.time.*

main(args: Array<String>): Int64 {
    var commandArgs = args
    var configPath = defaultConfigPath()
    if (args.size >= 2 && args[0] == "--config") {
        configPath = args[1]
        commandArgs = args[2..]
    }
    if (commandArgs.size > 0 && commandArgs[0] == "plugin-stdio") {
        return gcmPluginMain(["--config", configPath])
    }
    let config = loadConfig(path: configPath)
    if (commandArgs.size > 0 && commandArgs[0] == "scan-once") {
        println(servicePluginOnlyUnsupportedCommand("scan-once"))
        return 2
    }
    if (commandArgs.size > 0 && commandArgs[0] == "webhook-http") {
        println(servicePluginOnlyUnsupportedCommand("webhook-http"))
        return 2
    }
    if (commandArgs.size > 0 && commandArgs[0] == "serve") {
        println(servicePluginOnlyUnsupportedCommand("serve"))
        return 2
    }
    if (commandArgs.size > 0 && commandArgs[0] == "probe-gitcode") {
        println(probeGitCode(config))
        return 0
    }
    if (commandArgs.size > 0 && commandArgs[0] == "probe-mcp") {
        println(probeMcp(config))
        return 0
    }
    if (commandArgs.size > 1 && commandArgs[0] == "config" && commandArgs[1] == "summary") {
        println(configSummary(config))
        return 0
    }
    if (commandArgs.size > 0 && commandArgs[0] == "tests") {
        println("Run: cjpm test")
        return 0
    }
    if (commandArgs.size > 0 && commandArgs[0] == "doctor") {
        let runtime = RuntimeContainer(config)
        let state = runtime.store.load()
        println(doctorReport(config, state))
        return 0
    }
    println(cliHelp())
    return 0
}
