import Foundation

enum PermissionDecision: Equatable {
    case allow, deny, allowAlways
}

enum BotCommand: Equatable {
    /// `/project` with no argument. Lists what is available instead of failing:
    /// from a phone there is otherwise no way to discover the project names, and
    /// falling through to `.prompt` sent the literal text "/project" to Claude.
    case listProjects
    case project(String)
    case stop
    case status
    case help
}

enum Route: Equatable {
    case shell(String)
    case permission(PermissionDecision)
    case command(BotCommand)
    case prompt(String)
}

struct MessageRouter {
    /// 优先级自上而下，第一条命中即返回。
    func route(_ raw: String, hasPendingPermission: Bool) -> Route {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()

        // 1. 显式 shell 前缀，优先级最高，永不产生歧义
        if text.hasPrefix("!") {
            return .shell(String(text.dropFirst()).trimmingCharacters(in: .whitespaces))
        }

        // 2. 仅在真有待决请求时，yes/no 才是权限应答
        if hasPendingPermission, let d = Self.decision(for: lower) {
            return .permission(d)
        }

        // 3. 斜杠命令；无法识别的落到 4
        if text.hasPrefix("/"), let c = Self.command(for: lower, from: text) {
            return .command(c)
        }

        // 4. 其余全部交给 Claude
        return .prompt(text)
    }

    private static func decision(for lower: String) -> PermissionDecision? {
        switch lower {
        case "yes", "y", "1":            return .allow
        case "no", "n", "0", "3":        return .deny
        case "2", "always":              return .allowAlways
        default:                         return nil
        }
    }

    private static func command(for lower: String, from original: String) -> BotCommand? {
        let lowerParts = lower.split(separator: " ", maxSplits: 1).map(String.init)
        let originalParts = original.split(separator: " ", maxSplits: 1).map(String.init)

        switch lowerParts.first {
        case "/stop":    return .stop
        case "/status":  return .status
        case "/help":    return .help
        case "/project":
            guard originalParts.count == 2,
                  !originalParts[1].trimmingCharacters(in: .whitespaces).isEmpty
            else { return .listProjects }
            return .project(originalParts[1].trimmingCharacters(in: .whitespaces))
        default:         return nil
        }
    }
}
