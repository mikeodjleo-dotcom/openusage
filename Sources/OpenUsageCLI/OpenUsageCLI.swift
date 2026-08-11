import Darwin
import Foundation
import OpenUsage

@main
struct OpenUsageCLI {
    static func main() async {
        do {
            let arguments = try CLIArguments.parse(Array(CommandLine.arguments.dropFirst()))
            if arguments.showHelp {
                print(help)
                return
            }

            let app = AppBundleLocator.locate()
            if arguments.showVersion {
                print(app.version.map { "openusage \($0)" } ?? "openusage (development build)")
                return
            }

            guard let defaults = UserDefaults(suiteName: app.bundleIdentifier) else {
                throw CLIError.appDefaultsUnavailable
            }
            let format: UsageReadFormat = switch arguments.briefOutput {
            case .json: .briefJSON
            case .markdown: .briefMarkdown
            case nil: .limitsJSON
            }
            let result = try await UsageReader(userDefaults: defaults).read(
                providerID: arguments.providerID,
                force: arguments.force,
                format: format
            )
            FileHandle.standardOutput.write(result.data)
            FileHandle.standardOutput.write(Data("\n".utf8))
            if !result.warnings.isEmpty {
                result.warnings.forEach { writeError("warning: \($0)") }
                exit(4)
            }
        } catch CLIError.usage(let message) {
            fail("\(message)\nRun 'openusage --help' for usage.", code: 2)
        } catch CLIError.appDefaultsUnavailable {
            fail("Could not open the OpenUsage settings domain.", code: 4)
        } catch UsageReaderError.unknownProvider(let providerID) {
            fail("Unknown provider: \(providerID)", code: 2)
        } catch {
            fail(error.localizedDescription, code: 4)
        }
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data("openusage: \(message)\n".utf8))
    }

    private static func fail(_ message: String, code: Int32) -> Never {
        writeError(message)
        exit(code)
    }

    private static let help = """
    Usage:
      openusage [provider] [--force]
      openusage brief [--json | --markdown] [--force]

    Read through OpenUsage's shared five-minute cache and exit. The brief command combines limits,
    spend, and usage trends for agents; it defaults to JSON.

    Options:
      --force      Refresh even when the shared cache is still fresh
      --json       Print the agent brief as structured JSON
      --markdown   Print the agent brief as compact Markdown
      -v, --version
      -h, --help
    """
}
