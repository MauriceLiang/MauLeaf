import Foundation

protocol NativeFirmwareBackend {
    func readState() async throws -> FirmwareLimitHelperStateResponse
    func applyLimit(upper: Int, lower: Int, confirmed: Bool) async throws -> FirmwareLimitHelperOperationResponse
    func beginOneTimeCharge(upper: Int, lower: Int, confirmed: Bool) async throws -> FirmwareLimitHelperOperationResponse
    func cancelOneTimeCharge() async throws -> FirmwareLimitHelperOperationResponse
    func oneTimeChargeStatus() async throws -> FirmwareLimitHelperOneTimeStatusResponse
}

enum FirmwareLimitHelperClientError: Error, LocalizedError {
    case connectionInvalidated
    case serviceUnavailable
    case missingResponse
    case timedOut
    case remote(String)

    var errorDescription: String? {
        switch self {
        case .connectionInvalidated: return "The native firmware helper connection was invalidated."
        case .serviceUnavailable: return "The native firmware helper is unavailable."
        case .missingResponse: return "The native firmware helper returned no response."
        case .timedOut: return "The native firmware helper did not respond before the timeout."
        case .remote(let message): return message
        }
    }
}

final class FirmwareLimitHelperClient: NativeFirmwareBackend {
    private let serviceName = "com.local.chargecap.firmware-helper"

    func readState() async throws -> FirmwareLimitHelperStateResponse {
        try await request { proxy, reply in proxy.readState(withReply: reply) }
    }

    func applyLimit(upper: Int, lower: Int, confirmed: Bool) async throws -> FirmwareLimitHelperOperationResponse {
        try await request { proxy, reply in
            proxy.applyLimit(upper: upper, lower: lower, confirmed: confirmed, withReply: reply)
        }
    }

    func beginOneTimeCharge(upper: Int, lower: Int, confirmed: Bool) async throws -> FirmwareLimitHelperOperationResponse {
        try await request { proxy, reply in
            proxy.beginOneTimeCharge(upper: upper, lower: lower, confirmed: confirmed, withReply: reply)
        }
    }

    func cancelOneTimeCharge() async throws -> FirmwareLimitHelperOperationResponse {
        try await request { proxy, reply in proxy.cancelOneTimeCharge(withReply: reply) }
    }

    func oneTimeChargeStatus() async throws -> FirmwareLimitHelperOneTimeStatusResponse {
        try await request { proxy, reply in proxy.oneTimeChargeStatus(withReply: reply) }
    }

    private func request<Response: Decodable>(
        _ start: @escaping (
            FirmwareLimitHelperProtocol,
            @escaping (NSData?, NSString?) -> Void
        ) -> Void
    ) async throws -> Response {
        try await withCheckedThrowingContinuation { continuation in
            let delivery = FirmwareLimitXPCDelivery<Response>(continuation)
            let connection = NSXPCConnection(machServiceName: serviceName, options: [.privileged])
            let connectionBox = FirmwareLimitXPCConnectionBox(connection)
            connection.remoteObjectInterface = NSXPCInterface(with: FirmwareLimitHelperProtocol.self)
            connection.invalidationHandler = {
                delivery.deliver(.failure(FirmwareLimitHelperClientError.connectionInvalidated))
            }
            connection.interruptionHandler = {
                delivery.deliver(.failure(FirmwareLimitHelperClientError.serviceUnavailable))
            }
            connection.resume()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20) {
                delivery.deliver(.failure(FirmwareLimitHelperClientError.timedOut))
                connectionBox.connection.invalidate()
            }

            let proxyObject = connection.remoteObjectProxyWithErrorHandler { error in
                delivery.deliver(.failure(error))
                connection.invalidate()
            }
            guard let proxy = proxyObject as? FirmwareLimitHelperProtocol else {
                delivery.deliver(.failure(FirmwareLimitHelperClientError.serviceUnavailable))
                connection.invalidate()
                return
            }

            start(proxy) { data, error in
                if let error {
                    delivery.deliver(.failure(FirmwareLimitHelperClientError.remote(String(error))))
                    connection.invalidate()
                    return
                }
                guard let data else {
                    delivery.deliver(.failure(FirmwareLimitHelperClientError.missingResponse))
                    connection.invalidate()
                    return
                }
                do {
                    let response = try JSONDecoder().decode(Response.self, from: data as Data)
                    delivery.deliver(.success(response))
                } catch {
                    delivery.deliver(.failure(error))
                }
                connection.invalidate()
            }
        }
    }
}

private final class FirmwareLimitXPCDelivery<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var delivered = false
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func deliver(_ result: Result<Value, Error>) {
        lock.lock()
        guard !delivered else {
            lock.unlock()
            return
        }
        delivered = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

private final class FirmwareLimitXPCConnectionBox: @unchecked Sendable {
    let connection: NSXPCConnection
    init(_ connection: NSXPCConnection) { self.connection = connection }
}
