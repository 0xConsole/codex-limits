import CodexLimitsCore
import Foundation

let usage = """
Usage: codex-limits [command]

Commands:
  status [--json]   Show each saved account's 5-hour and weekly limits (default)
  add               Sign in to another ChatGPT account through Codex
  remove <email>    Forget a saved account
  use <email>       Sign Codex in to a saved account
  auto-resume       Keep running. When a conversation stops on a usage limit, wait
                    until a saved account's 5-hour limit replenishes, sign Codex in
                    to it and continue the conversation
  version           Print the version
"""

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? "status"
let options = Array(arguments.dropFirst())

do {
    switch command {
    case "status":
        try await Commands.status(json: options.contains("--json"))
    case "add":
        try await Commands.add()
    case "remove":
        try Commands.remove(email: requiredEmail(options))
    case "use":
        try Commands.use(email: requiredEmail(options))
    case "auto-resume":
        try await HeadlessAutoResume().run()
    case "version", "--version":
        print(CodexLimitsVersion.current)
    case "help", "--help", "-h":
        print(usage)
    default:
        Terminal.fail("Unknown command '\(command)'.\n\n\(usage)", status: 64)
    }
} catch {
    Terminal.fail(error.localizedDescription)
}

func requiredEmail(_ options: [String]) -> String {
    guard let email = options.first else {
        Terminal.fail("Give the account's email address.\n\n\(usage)", status: 64)
    }
    return email
}
