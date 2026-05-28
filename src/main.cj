package gitcodemonitor

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
        let runtime = RuntimeContainer(config)
        let state = runtime.store.load()
        let result = if (commandArgs.size > 1 && commandArgs[1] == "--offline-fixture") {
            scanOnceOfflineFixture(config, state)
        } else {
            scanOnceRuntime(config, runtime, state)
        }
        let saved = runtime.store.save(state)
        println("scan-once accepted=${result.accepted} ignored=${result.ignored} notified=${result.notified} mcpCalls=${result.mcpCalls} writes=${result.writes}")
        if (!saved) { println("state=save_failed") }
        return 0
    }
    if (commandArgs.size > 0 && commandArgs[0] == "serve") {
        let runtime = RuntimeContainer(config)
        let state = runtime.store.load()
        let scheduler = FullScanScheduler(config, FakeClock())
        let summary = runServiceScans(config, runtime, FakeClock(), scheduler, state, ServiceControl(maxScans: 1), tickMinutes: config.fullScanIntervalMinutes)
        println("serve scans=${summary.scans} skipped=${summary.skipped} stopped=${summary.stopped} audit=${state.audit.size}")
        return 0
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
        let mcp = FakeMcpClient()
        mcp.initialize()
        println(doctorReport(config, state, mcp))
        return 0
    }
    println(cliHelp())
    return 0
}
