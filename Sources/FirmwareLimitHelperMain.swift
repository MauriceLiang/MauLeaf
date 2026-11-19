import Foundation

@main
private enum MauLeafFirmwareHelperMain {
    static func main() {
        let listener = FirmwareLimitHelperListener()
        listener.run()
        dispatchMain()
    }
}
