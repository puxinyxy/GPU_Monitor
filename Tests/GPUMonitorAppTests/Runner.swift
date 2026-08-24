import Testing

@main
struct GPUMonitorAppTestsRunner {
    static func main() async {
        await Testing.__swiftPMEntryPoint() as Never
    }
}
