import Foundation

enum BriefOutput: Equatable, Sendable {
    case json
    case markdown
}

struct CLIArguments: Equatable, Sendable {
    var providerID: String?
    var isBrief = false
    var briefOutput: BriefOutput?
    var force = false
    var showHelp = false
    var showVersion = false

    static func parse(_ arguments: [String]) throws -> CLIArguments {
        var parsed = CLIArguments()
        for argument in arguments {
            switch argument {
            case "--force": parsed.force = true
            case "--json":
                guard parsed.briefOutput != .markdown else {
                    throw CLIError.usage("Choose either --json or --markdown.")
                }
                parsed.briefOutput = .json
            case "--markdown":
                guard parsed.briefOutput != .json else {
                    throw CLIError.usage("Choose either --json or --markdown.")
                }
                parsed.briefOutput = .markdown
            case "-h", "--help": parsed.showHelp = true
            case "-v", "--version": parsed.showVersion = true
            default:
                if argument.hasPrefix("-") {
                    throw CLIError.usage("Unknown option: \(argument)")
                }
                if argument.lowercased() == "brief" {
                    guard !parsed.isBrief else {
                        throw CLIError.usage("The brief command can only be specified once.")
                    }
                    parsed.isBrief = true
                    continue
                }
                guard parsed.providerID == nil else {
                    throw CLIError.usage("Only one provider can be requested at a time.")
                }
                parsed.providerID = argument.lowercased()
            }
        }
        if parsed.isBrief {
            guard parsed.providerID == nil else {
                throw CLIError.usage("The brief command does not accept a provider.")
            }
            parsed.briefOutput = parsed.briefOutput ?? .json
        } else if parsed.briefOutput != nil {
            throw CLIError.usage("--json and --markdown are only valid with the brief command.")
        }
        return parsed
    }
}

enum CLIError: Error, Equatable {
    case usage(String)
    case appDefaultsUnavailable
}
