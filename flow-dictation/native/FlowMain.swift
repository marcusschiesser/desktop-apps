import Foundation

#if !os(macOS)
func serve(paths: FlowPaths) throws {
    _ = paths
    throw FlowError.failed("Flow Dictation's background helper requires macOS")
}

func openConfig(paths: FlowPaths) throws {
    try paths.ensure()
    print(paths.config.path)
}
#endif

@main
struct FlowHelperMain {
    @MainActor static func main() {
        do {
            let command = CommandLine.arguments.dropFirst().first ?? "serve"
            let paths = FlowPaths.current()
            switch command {
            case "serve": try serve(paths: paths)
            case "open-config": try openConfig(paths: paths)
            case "self-test": try runSelfTest()
            default: throw FlowError.usage("Usage: flow-helper [serve|open-config|self-test]")
            }
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
