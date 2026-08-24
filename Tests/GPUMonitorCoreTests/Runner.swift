import Testing

@main
struct GPUMonitorCoreTestsRunner {
    static func main() async {
        await Testing.__swiftPMEntryPoint() as Never
    }
}
