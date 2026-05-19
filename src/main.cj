package gitcodemonitor

main(args: Array<String>): Int64 {
    let config = defaultConfig()
    let state = MonitorState()
    let mcp = FakeMcpClient()
    if (args.size > 0 && args[0] == "scan-once") {
        let transport = FakeGitCodeTransport()
        transport.seedDefaultRepos()
        transport.events.add(GitCodeEvent("evt-1", "cangjie", "compiler", "issue", "1", "alice", "https://gitcode.com/alice", "https://gitcode.com/cangjie/compiler/issues/1", "Please check this issue."))
        let result = scanOnce(config, transport, state, FakeNotifier("feishu"), FakeNotifier("telegram"), mcp, FakeCommentWriter())
        println("scan-once accepted=${result.accepted} ignored=${result.ignored} notified=${result.notified} mcpCalls=${result.mcpCalls} writes=${result.writes}")
        return 0
    }
    if (args.size > 0 && args[0] == "tests") {
        println("Run: cjpm test")
        return 0
    }
    if (args.size > 0 && args[0] == "doctor") {
        mcp.initialize()
        println(doctorReport(config, state, mcp))
        return 0
    }
    println("Usage: gitcodemonitor <doctor|scan-once|tests>")
    return 0
}
