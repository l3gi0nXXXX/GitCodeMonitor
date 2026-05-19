package gitcodemonitor

main(args: Array<String>): Int64 {
    var commandArgs = args
    var configPath = defaultConfigPath()
    if (args.size >= 2 && args[0] == "--config") {
        configPath = args[1]
        commandArgs = args[2..]
    }
    let config = loadConfig(path: configPath)
    let state = MonitorState()
    let mcp = FakeMcpClient()
    if (commandArgs.size > 0 && commandArgs[0] == "scan-once") {
        let transport = FakeGitCodeTransport()
        transport.seedDefaultRepos()
        transport.events.add(GitCodeEvent("evt-1", "cangjie", "compiler", "issue", "1", "alice", "https://gitcode.com/alice", "https://gitcode.com/cangjie/compiler/issues/1", "Please check this issue."))
        let result = scanOnce(config, transport, state, FakeNotifier("feishu"), FakeNotifier("telegram"), mcp, FakeCommentWriter())
        println("scan-once accepted=${result.accepted} ignored=${result.ignored} notified=${result.notified} mcpCalls=${result.mcpCalls} writes=${result.writes}")
        return 0
    }
    if (commandArgs.size > 0 && commandArgs[0] == "serve") {
        let scheduler = FullScanScheduler(config, FakeClock())
        let summary = runServiceTicks(config, FakeClock(), scheduler, state, ServiceControl(maxScans: 1))
        println("${serveOnceBaseline(config)} scans=${summary.scans} stopped=${summary.stopped}")
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
        mcp.initialize()
        println(doctorReport(config, state, mcp))
        return 0
    }
    println(cliHelp())
    return 0
}
