import Darwin
import Foundation

/// How to talk to one SNMP agent. Built from a source row and its Keychain
/// secrets just before polling; never stored as a whole.
public struct SNMPCredentials: Sendable, Equatable {
    public enum Version: String, Sendable, Codable, CaseIterable {
        case v2c, v3
    }

    public var version: Version
    public var community: String
    public var user: String
    /// `nil` means noAuthNoPriv.
    public var authProtocol: SNMPAuthProtocol?
    public var authPassword: String
    /// `nil` means no encryption; ignored without authentication.
    public var privProtocol: SNMPPrivProtocol?
    public var privPassword: String

    public static func v2c(community: String) -> SNMPCredentials {
        SNMPCredentials(version: .v2c, community: community, user: "", authProtocol: nil, authPassword: "", privProtocol: nil, privPassword: "")
    }

    public static func v3(
        user: String, auth: SNMPAuthProtocol?, authPassword: String, priv: SNMPPrivProtocol?, privPassword: String
    ) -> SNMPCredentials {
        SNMPCredentials(version: .v3, community: "", user: user, authProtocol: auth, authPassword: authPassword,
                        privProtocol: priv, privPassword: privPassword)
    }
}

public enum SNMPError: Error, Equatable, Sendable {
    case unresolvedHost(String)
    case noResponse
    case unknownUser
    case wrongAuthPassword
    case wrongPrivPassword
    case unsupportedSecurityLevel
    case agentError(Int)
    case malformedResponse
}

extension SNMPError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unresolvedHost(let host): "Couldn't find \(host)."
        case .noResponse: "No answer. Check the address, the port, and the community or user; an agent ignores requests it can't authenticate."
        case .unknownUser: "The device doesn't know this SNMPv3 user."
        case .wrongAuthPassword: "The authentication password or protocol is wrong."
        case .wrongPrivPassword: "The privacy (encryption) password or protocol is wrong."
        case .unsupportedSecurityLevel: "The device doesn't allow this security level for the user."
        case .agentError(let status): "The device answered with SNMP error \(status)."
        case .malformedResponse: "The device's answer couldn't be read."
        }
    }
}

/// A read-only SNMP v2c/v3 client: GET and walks (GETBULK). It never sends
/// SET; nothing in this app writes to a network device.
public actor SNMPClient {
    private let host: String
    private let port: UInt16
    private let credentials: SNMPCredentials
    private let timeout: TimeInterval
    private let retries: Int

    private var address: IPv4Address?
    private var engine: (id: [UInt8], boots: Int64, time: Int64, learnedAt: Date)?
    private var keys: USMKeys?
    private var counter = Int32.random(in: 1...0x3FFF_FFFF)

    public init(host: String, port: UInt16 = 161, credentials: SNMPCredentials, timeout: TimeInterval = 2, retries: Int = 1) {
        self.host = host
        self.port = port
        self.credentials = credentials
        self.timeout = timeout
        self.retries = retries
    }

    public func get(_ oids: [OID]) async throws -> [SNMPVarBind] {
        let pdu = SNMPPDU(kind: .get, requestID: nextID(), errorStatus: 0, errorIndex: 0,
                          bindings: oids.map { SNMPVarBind(oid: $0, value: .null) })
        return try await exchange(pdu).bindings
    }

    /// Every variable under `root`, in order. Stops at the end of the
    /// subtree, at `limit` rows, or if the agent stops moving forward —
    /// some agents loop on a broken table, and that must not loop the app.
    public func walk(_ root: OID, maxRepetitions: Int = 25, limit: Int = 50_000) async throws -> [SNMPVarBind] {
        var results: [SNMPVarBind] = []
        var cursor = root
        var repetitions = maxRepetitions
        while results.count < limit {
            let pdu = SNMPPDU(kind: .getBulk, requestID: nextID(), errorStatus: 0, errorIndex: repetitions,
                              bindings: [SNMPVarBind(oid: cursor, value: .null)])
            let response: SNMPPDU
            do {
                response = try await exchange(pdu)
            } catch SNMPError.agentError(1) where repetitions > 1 {
                // tooBig: the answer didn't fit one datagram; ask for less.
                repetitions = max(1, repetitions / 2)
                continue
            }
            var advanced = false
            for binding in response.bindings {
                guard root.isPrefix(of: binding.oid), binding.value != .endOfMibView, cursor < binding.oid else { return results }
                results.append(binding)
                cursor = binding.oid
                advanced = true
            }
            if !advanced { return results }
        }
        return results
    }

    // MARK: - Exchange

    private func nextID() -> Int32 {
        counter = counter == Int32.max ? 1 : counter + 1
        return counter
    }

    private func exchange(_ pdu: SNMPPDU) async throws -> SNMPPDU {
        let target = try await resolve()
        let response: SNMPPDU
        switch credentials.version {
        case .v2c:
            let bytes = SNMPv2cMessage.encode(community: credentials.community, pdu: pdu)
            let requestID = pdu.requestID
            response = try await transmit(bytes, to: target) { reply in
                guard let decoded = try? SNMPv2cMessage.decode(reply), decoded.requestID == requestID else { return nil }
                return .success(decoded)
            }
        case .v3:
            response = try await exchangeV3(pdu, to: target, isRetry: false)
        }
        guard response.errorStatus == 0 else { throw SNMPError.agentError(response.errorStatus) }
        return response
    }

    private func exchangeV3(_ pdu: SNMPPDU, to target: IPv4Address, isRetry: Bool) async throws -> SNMPPDU {
        if engine == nil { try await discoverEngine(at: target) }
        guard let engine, let keys else { throw SNMPError.malformedResponse }

        var flags: SNMPv3Message.Flags = [.reportable]
        if keys.auth != nil { flags.insert(.auth) }
        if keys.auth != nil, keys.priv != nil { flags.insert(.priv) }
        let messageID = nextID()
        let security = USMParameters(
            engineID: engine.id, engineBoots: engine.boots,
            engineTime: engine.time + Int64(Date().timeIntervalSince(engine.learnedAt)),
            userName: credentials.user, authParameters: [], privParameters: []
        )
        let message = SNMPv3Message(messageID: messageID, flags: flags, security: security, contextEngineID: engine.id, pdu: pdu)
        let salt = (0..<8).map { _ in UInt8.random(in: 0...255) }
        guard let bytes = message.encode(keys: keys, salt: salt) else { throw SNMPError.malformedResponse }

        let reply = try await transmit(bytes, to: target) { data -> Result<SNMPv3Message, SNMPError>? in
            do {
                let decoded = try SNMPv3Message.decode(data, keys: keys)
                return decoded.messageID == messageID ? .success(decoded) : nil
            } catch SNMPv3Message.DecodeFailure.wrongDigest {
                return .failure(.wrongAuthPassword)
            } catch SNMPv3Message.DecodeFailure.decryption {
                return .failure(.wrongPrivPassword)
            } catch {
                return nil
            }
        }

        guard reply.pdu.kind == .report else { return reply.pdu }
        // usmStats counters (RFC 3414 §5) name what went wrong.
        switch reply.pdu.bindings.first?.oid.description {
        case "1.3.6.1.6.3.15.1.1.2.0", "1.3.6.1.6.3.15.1.1.4.0":
            // Not in time window / unknown engine: the agent rebooted or its
            // clock moved. Take its current values and try once more.
            guard !isRetry else { throw SNMPError.malformedResponse }
            if reply.security.engineID == engine.id {
                self.engine = (engine.id, reply.security.engineBoots, reply.security.engineTime, Date())
            } else {
                self.engine = nil
            }
            return try await exchangeV3(pdu, to: target, isRetry: true)
        case "1.3.6.1.6.3.15.1.1.3.0": throw SNMPError.unknownUser
        case "1.3.6.1.6.3.15.1.1.5.0": throw SNMPError.wrongAuthPassword
        case "1.3.6.1.6.3.15.1.1.6.0": throw SNMPError.wrongPrivPassword
        case "1.3.6.1.6.3.15.1.1.1.0": throw SNMPError.unsupportedSecurityLevel
        default: throw SNMPError.malformedResponse
        }
    }

    /// RFC 3414 §4: an empty, unauthenticated request the agent answers
    /// with a report carrying its engine ID, boot count and time.
    private func discoverEngine(at target: IPv4Address) async throws {
        let messageID = nextID()
        let probe = SNMPv3Message(
            messageID: messageID, flags: [.reportable],
            security: USMParameters(engineID: [], engineBoots: 0, engineTime: 0, userName: "", authParameters: [], privParameters: []),
            contextEngineID: [],
            pdu: SNMPPDU(kind: .get, requestID: nextID(), errorStatus: 0, errorIndex: 0, bindings: [])
        )
        guard let bytes = probe.encode(keys: nil, salt: []) else { throw SNMPError.malformedResponse }
        let reply = try await transmit(bytes, to: target) { data -> Result<SNMPv3Message, SNMPError>? in
            guard let decoded = try? SNMPv3Message.decode(data, keys: nil), decoded.messageID == messageID else { return nil }
            return .success(decoded)
        }
        guard !reply.security.engineID.isEmpty else { throw SNMPError.malformedResponse }
        if keys == nil || engine?.id != reply.security.engineID {
            keys = USMKeys(credentials: credentials, engineID: reply.security.engineID)
        }
        engine = (reply.security.engineID, reply.security.engineBoots, reply.security.engineTime, Date())
    }

    private func resolve() async throws -> IPv4Address {
        if let address { return address }
        let name = host
        let resolved = if let literal = IPv4Address(name) {
            literal
        } else {
            await runBlocking { _ in Self.resolveIPv4(name) }
        }
        guard let resolved else { throw SNMPError.unresolvedHost(name) }
        address = resolved
        return resolved
    }

    private static func resolveIPv4(_ host: String) -> IPv4Address? {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_DGRAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result, let address = first.pointee.ai_addr else { return nil }
        defer { freeaddrinfo(result) }
        let raw = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
        return IPv4Address(UInt32(bigEndian: raw))
    }

    /// Sends `bytes` and waits for the first datagram `match` accepts,
    /// resending on timeout. `match` returns `nil` for a datagram that isn't
    /// the answer (a late reply to an earlier request).
    private func transmit<T: Sendable>(
        _ bytes: [UInt8], to target: IPv4Address, match: @escaping @Sendable ([UInt8]) -> Result<T, SNMPError>?
    ) async throws -> T {
        let port = port
        let timeout = timeout
        let attempts = retries + 1
        let result: Result<T, SNMPError> = await runBlocking { cancel in
            let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard fd >= 0 else { return .failure(.noResponse) }
            defer { close(fd) }
            let connected = withSocketAddress(socketAddress(target, port: port)) { connect(fd, $0, $1) }
            guard connected == 0 else { return .failure(.noResponse) }

            var buffer = [UInt8](repeating: 0, count: 65_535)
            for _ in 0..<attempts {
                guard !cancel.isCancelled, send(fd, bytes, bytes.count, 0) == bytes.count else { break }
                let deadline = Date().addingTimeInterval(timeout)
                while !cancel.isCancelled {
                    let remaining = deadline.timeIntervalSinceNow
                    if remaining <= 0 { break }
                    var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                    guard poll(&descriptor, 1, Int32(min(remaining, 0.2) * 1000)) > 0 else { continue }
                    let count = recv(fd, &buffer, buffer.count, 0)
                    // ICMP port unreachable surfaces as a failed read on a
                    // connected socket: nothing is listening there.
                    guard count > 0 else { return .failure(.noResponse) }
                    if let matched = match(Array(buffer[0..<count])) { return matched }
                }
            }
            return .failure(.noResponse)
        }
        return try result.get()
    }
}
