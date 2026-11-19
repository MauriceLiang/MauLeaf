import Foundation
import Darwin

@main
private enum MauLeafFirmwareHelperMain {
    static func main() {
        if CommandLine.arguments.contains("--restore-original-state") {
            let service = FirmwareLimitHelperService(
                transport: AppleSMCFirmwareLimitTransport(),
                monitorEnabled: false
            )
            do {
                let response = try service.restoreOriginalStateForUninstall()
                print(response.message)
                return
            } catch {
                fputs("MauLeaf firmware restoration failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }

        if CommandLine.arguments.contains("--verify-clean-and-inactive") {
            let service = FirmwareLimitHelperService(
                transport: AppleSMCFirmwareLimitTransport(),
                monitorEnabled: false
            )
            do {
                try service.verifyReadyForDeferredRemoval()
                print("The native firmware limit is inactive and no recovery task remains.")
                return
            } catch {
                fputs("MauLeaf cannot remove its helper: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }

        let listener = FirmwareLimitHelperListener()
        listener.run()
        dispatchMain()
    }
}
