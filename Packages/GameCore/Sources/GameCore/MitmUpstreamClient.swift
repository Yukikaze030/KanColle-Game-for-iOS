import Foundation
import Network
import Security

/// A cancellable, single HTTP/1.1 request to an HTTPS origin.
public protocol MitmUpstreamRequestTask: AnyObject {
    func cancel()
}

/// Executes the already-sanitized request used by one MITM TLS transaction.
///
/// Implementations must invoke `completion` at most once and must bound the
/// returned response by `responseLimit`.
public protocol MitmUpstreamRequestExecuting: AnyObject {
    @discardableResult
    func execute(
        host: String,
        request: Data,
        responseLimit: Int,
        timeout: TimeInterval,
        completion: @escaping (Result<Data, Error>) -> Void
    ) -> MitmUpstreamRequestTask
}

public enum MitmUpstreamError: Error, Equatable {
    case invalidHost
    case connectionFailed
    case sendFailed
    case responseFailed
    case responseTooLarge
    case emptyResponse
    case timedOut
    case cancelled
}

private final class NWHTTPSExecution: MitmUpstreamRequestTask {
    private let queue: DispatchQueue
    private let connection: NWConnection
    private let responseLimit: Int
    private var response = Data()
    private var completion: ((Result<Data, Error>) -> Void)?
    private var timeoutWorkItem: DispatchWorkItem?

    init(
        queue: DispatchQueue,
        connection: NWConnection,
        request: Data,
        responseLimit: Int,
        timeout: TimeInterval,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        self.queue = queue
        self.connection = connection
        self.responseLimit = responseLimit
        self.completion = completion

        connection.stateUpdateHandler = { [weak self] state in
            self?.handle(state: state, request: request)
        }
        connection.start(queue: queue)

        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            self?.finish(.failure(MitmUpstreamError.timedOut))
        }
        self.timeoutWorkItem = timeoutWorkItem
        queue.asyncAfter(
            deadline: .now() + max(0.001, timeout),
            execute: timeoutWorkItem
        )
    }

    func cancel() {
        queue.async { [weak self] in
            self?.finish(.failure(MitmUpstreamError.cancelled))
        }
    }

    private func handle(state: NWConnection.State, request: Data) {
        guard completion != nil else { return }
        switch state {
        case .ready:
            connection.stateUpdateHandler = { [weak self] newState in
                guard case .failed = newState else { return }
                self?.finish(.failure(MitmUpstreamError.connectionFailed))
            }
            connection.send(
                content: request,
                completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    self.queue.async {
                        if error == nil {
                            self.receive()
                        } else {
                            self.finish(.failure(MitmUpstreamError.sendFailed))
                        }
                    }
                }
            )
        case .failed:
            finish(.failure(MitmUpstreamError.connectionFailed))
        case .cancelled:
            if completion != nil {
                finish(.failure(MitmUpstreamError.cancelled))
            }
        default:
            break
        }
    }

    private func receive() {
        guard completion != nil else { return }
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 256 * 1024
        ) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.queue.async {
                guard self.completion != nil else { return }
                if let data, !data.isEmpty {
                    guard data.count <= self.responseLimit - self.response.count else {
                        self.finish(.failure(MitmUpstreamError.responseTooLarge))
                        return
                    }
                    self.response.append(data)
                }
                if error != nil {
                    self.finish(.failure(MitmUpstreamError.responseFailed))
                } else if isComplete {
                    if self.response.isEmpty {
                        self.finish(.failure(MitmUpstreamError.emptyResponse))
                    } else {
                        self.finish(.success(self.response))
                    }
                } else {
                    self.receive()
                }
            }
        }
    }

    private func finish(_ result: Result<Data, Error>) {
        guard let completion else { return }
        self.completion = nil
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        completion(result)
    }
}

/// Production HTTPS executor. It uses Network.framework TLS with the system
/// trust store, SNI, and HTTP/1.1 ALPN. No verification override is installed.
public final class NWHTTPSUpstreamClient: MitmUpstreamRequestExecuting {
    private let queue = DispatchQueue(
        label: "GameCore.MitmUpstream",
        qos: .userInitiated
    )

    public init() {}

    @discardableResult
    public func execute(
        host: String,
        request: Data,
        responseLimit: Int,
        timeout: TimeInterval,
        completion: @escaping (Result<Data, Error>) -> Void
    ) -> MitmUpstreamRequestTask {
        guard !host.isEmpty, responseLimit > 0 else {
            completion(.failure(MitmUpstreamError.invalidHost))
            return CompletedMitmUpstreamTask()
        }

        let tls = NWProtocolTLS.Options()
        host.withCString {
            sec_protocol_options_set_tls_server_name(
                tls.securityProtocolOptions,
                $0
            )
        }
        "http/1.1".withCString {
            sec_protocol_options_add_tls_application_protocol(
                tls.securityProtocolOptions,
                $0
            )
        }
        let parameters = NWParameters(
            tls: tls,
            tcp: NWProtocolTCP.Options()
        )
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: .https,
            using: parameters
        )
        return NWHTTPSExecution(
            queue: queue,
            connection: connection,
            request: request,
            responseLimit: responseLimit,
            timeout: timeout,
            completion: completion
        )
    }
}

private final class CompletedMitmUpstreamTask: MitmUpstreamRequestTask {
    func cancel() {}
}
