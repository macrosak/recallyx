import Foundation

/// The parsed `recallyx` sub-command. Pure value type — the parser
/// (`CLICommand.parse`) turns raw `argv` (minus the program name) into one of
/// these or a `CLIParseError`, with no I/O, so it is fully unit-testable.
public enum CLICommand: Equatable {
    /// Fuzzy-search history, print up to `limit` rows.
    case search(query: String, limit: Int)
    /// Most-recent history, up to `limit` rows.
    case recent(limit: Int)
    /// Print the FULL text of one clip.
    case get(GetTarget)
    /// Thread stdin through the named saved action's pipeline.
    case run(actionName: String)
    /// List saved action names + kind tags.
    case listActions
    /// Read stdin, set the system clipboard.
    case copy
    /// Print usage.
    case help
}

/// Which clip `get` targets: the Nth most-recent (1-based) or an explicit id.
public enum GetTarget: Equatable {
    case index(Int)
    case id(UUID)
}

public enum CLIParseError: Error, Equatable {
    case unknownCommand(String)
    case missingQuery
    case missingActionName
    case invalidNumber(String)
    case invalidUUID(String)
    case missingValue(flag: String)
    case unexpectedArgument(String)

    public var message: String {
        switch self {
        case .unknownCommand(let c): return "Unknown command '\(c)'."
        case .missingQuery: return "search needs a query, e.g. `recallyx search foo`."
        case .missingActionName: return "run needs an action name, e.g. `recallyx run \"Fix grammar (EN)\"`."
        case .invalidNumber(let s): return "Expected a number but got '\(s)'."
        case .invalidUUID(let s): return "'\(s)' is not a valid clip id."
        case .missingValue(let flag): return "\(flag) needs a value."
        case .unexpectedArgument(let a): return "Unexpected argument '\(a)'."
        }
    }
}

extension CLICommand {
    public static let defaultLimit = 10

    /// Parse `argv` (WITHOUT the executable name). Empty / `-h` / `--help` →
    /// `.help`. Hand-rolled (no swift-argument-parser dependency).
    public static func parse(_ args: [String]) -> Result<CLICommand, CLIParseError> {
        guard let command = args.first else { return .success(.help) }
        if command == "-h" || command == "--help" || command == "help" {
            return .success(.help)
        }
        let rest = Array(args.dropFirst())

        switch command {
        case "search":  return parseSearch(rest)
        case "recent":  return parseRecent(rest)
        case "get":     return parseGet(rest)
        case "run":     return parseRun(rest)
        case "list-actions": return rest.isEmpty ? .success(.listActions)
                                                  : .failure(.unexpectedArgument(rest[0]))
        case "copy":    return rest.isEmpty ? .success(.copy)
                                            : .failure(.unexpectedArgument(rest[0]))
        default:        return .failure(.unknownCommand(command))
        }
    }

    // MARK: - Sub-parsers

    private static func parseSearch(_ args: [String]) -> Result<CLICommand, CLIParseError> {
        var limit = defaultLimit
        var queryParts: [String] = []
        var i = 0
        while i < args.count {
            let a = args[i]
            if a == "-n" || a == "--limit" {
                guard i + 1 < args.count else { return .failure(.missingValue(flag: a)) }
                guard let n = Int(args[i + 1]) else { return .failure(.invalidNumber(args[i + 1])) }
                limit = n
                i += 2
            } else {
                queryParts.append(a)
                i += 1
            }
        }
        let query = queryParts.joined(separator: " ")
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return .failure(.missingQuery) }
        return .success(.search(query: query, limit: max(0, limit)))
    }

    private static func parseRecent(_ args: [String]) -> Result<CLICommand, CLIParseError> {
        var limit = defaultLimit
        var i = 0
        while i < args.count {
            let a = args[i]
            if a == "-n" || a == "--limit" {
                guard i + 1 < args.count else { return .failure(.missingValue(flag: a)) }
                guard let n = Int(args[i + 1]) else { return .failure(.invalidNumber(args[i + 1])) }
                limit = n
                i += 2
            } else {
                return .failure(.unexpectedArgument(a))
            }
        }
        return .success(.recent(limit: max(0, limit)))
    }

    private static func parseGet(_ args: [String]) -> Result<CLICommand, CLIParseError> {
        // `get` (→ index 1), `get N`, or `get --id <uuid>`.
        var i = 0
        var target: GetTarget = .index(1)
        var sawTarget = false
        while i < args.count {
            let a = args[i]
            if a == "--id" {
                guard i + 1 < args.count else { return .failure(.missingValue(flag: a)) }
                guard let uuid = UUID(uuidString: args[i + 1]) else { return .failure(.invalidUUID(args[i + 1])) }
                target = .id(uuid)
                sawTarget = true
                i += 2
            } else if !sawTarget, let n = Int(a) {
                target = .index(n)
                sawTarget = true
                i += 1
            } else {
                return sawTarget ? .failure(.unexpectedArgument(a)) : .failure(.invalidNumber(a))
            }
        }
        return .success(.get(target))
    }

    private static func parseRun(_ args: [String]) -> Result<CLICommand, CLIParseError> {
        let name = args.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return .failure(.missingActionName) }
        return .success(.run(actionName: name))
    }

    /// The `--help` text.
    public static let usage = """
    recallyx — clipboard history + action pipelines from the terminal.

    USAGE:
      recallyx search <query> [-n N]   Fuzzy-search history (default N=10)
      recallyx recent [-n N]           Most-recent clips (default N=10)
      recallyx get [N]                 Print the full text of the Nth clip (1-based, default 1)
      recallyx get --id <uuid>         Print the full text of a clip by id
      recallyx run "<Action name>"     Thread stdin through a saved action's pipeline
      recallyx list-actions            List saved action names + kind tags
      recallyx copy                    Read stdin, set the system clipboard
      recallyx --help                  Show this help

    EXAMPLES:
      recallyx search "api key" -n 5
      recallyx get 2 | pbcopy
      echo '{"a":1}' | recallyx run "Pretty-print JSON"
      recallyx get 1 | recallyx run "Fix grammar (EN)"
      git rev-parse HEAD | recallyx copy

    Reads the same history the Recallyx app writes (read-only). Honors
    RECALLYX_DATA_DIR. AI action steps need the app's Keychain access — if that
    is unavailable, run the action from the app instead.
    """
}
