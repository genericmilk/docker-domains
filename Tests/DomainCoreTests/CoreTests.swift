import XCTest
@testable import DomainCore

final class CoreTests: XCTestCase {
    func testDomainValidationAndNormalization() throws {
        XCTAssertEqual(try DomainName.normalize("  BBQ.Test\n"), "bbq.test")
        XCTAssertEqual(try DomainName.normalize("vite.bbq.test"), "vite.bbq.test")
        for invalid in ["test", "bbq.com", "http://bbq.test", "bbq.test:80", "*.test", "-bbq.test", "bbq-.test", "a..test", "bbq.test\nrespond hacked", "é.test", "bbq.test.", String(repeating: "a", count: 64) + ".test"] {
            XCTAssertThrowsError(try DomainName.normalize(invalid), invalid)
        }
    }

    func testComposeIdentitySurvivesRecreationAndRejectsAmbiguousReplicas() {
        let mapping = DomainMapping(domain: "bbq.test", containerName: "old-name", project: "bbq", service: "web", port: 80)
        let replacement = container(name: "new-name")
        XCTAssertEqual(mapping.resolve(in: [replacement])?.id, replacement.id)
        XCTAssertNil(mapping.resolve(in: [replacement, container(name: "replica")]))
        XCTAssertNil(mapping.resolve(in: [container(name: "other", project: "different")]))
    }

    func testProxyRoutesOnlyRunningEnabledTargetsAndPreservesPort() throws {
        let active = container(name: "bbq-web")
        let stopped = container(name: "nuxt-web", running: false, project: "nuxt")
        let mappings = [DomainMapping(domain: "bbq.test", container: active, port: 8080),
                        DomainMapping(domain: "nuxt.test", container: stopped, port: 3000),
                        DomainMapping(domain: "paused.test", containerName: active.name, port: 80, enabled: false)]
        let config = try ProxyConfiguration.render(mappings: mappings, containers: [active, stopped])
        XCTAssertTrue(config.contains("host bbq.test"))
        XCTAssertTrue(config.contains("http://dd-123456789abc:8080"))
        XCTAssertFalse(config.contains("host nuxt.test"))
        XCTAssertFalse(config.contains("host paused.test"))
        XCTAssertTrue(config.contains("404"))
        XCTAssertFalse(config.contains("header_up Host"))
    }

    func testDuplicateDomainsAndInvalidPortsRejectedBeforeConfiguration() {
        let target = container()
        XCTAssertThrowsError(try ProxyConfiguration.render(mappings: [DomainMapping(domain: "a.test", container: target, port: 80), DomainMapping(domain: "A.test", container: target, port: 80)], containers: [target]))
        XCTAssertThrowsError(try DomainMapping(domain: "a.test", container: target, port: 0).validated())
        XCTAssertThrowsError(try DomainMapping(domain: "a.test", container: target, port: 65536).validated())
        let host = Container(id: "a", name: "host", image: "node", running: true, project: nil, service: nil, ports: [3000], networkMode: "host")
        XCTAssertThrowsError(try ProxyConfiguration.render(mappings: [DomainMapping(domain: "host.test", container: host, port: 3000)], containers: [host]))
    }

    func testDNSAnswersOnlyTestARecordsAndRetainsQuestionAndTransaction() throws {
        let query = dnsQuery("bbq.test", type: 1)
        let answer = try XCTUnwrap(DNSMessage.response(to: query))
        XCTAssertEqual(Array(answer.prefix(2)), [0x12, 0x34])
        XCTAssertEqual(answer[7], 1)
        XCTAssertEqual(Array(answer.suffix(4)), [127, 0, 0, 1])
        XCTAssertEqual(answer[12..<query.count], query[12...])
        for type: UInt16 in [28, 65, 255] {
            let noData = try XCTUnwrap(DNSMessage.response(to: dnsQuery("vite.bbq.test", type: type)))
            XCTAssertEqual(noData[3], 0)
            XCTAssertEqual(noData[7], 0)
        }
        let refused = try XCTUnwrap(DNSMessage.response(to: dnsQuery("example.com", type: 1)))
        XCTAssertEqual(refused[3], 5)
        XCTAssertEqual(refused[7], 0)
    }

    func testDNSRejectsMalformedAndCompressedQuestions() {
        for length in 0..<12 { XCTAssertNil(DNSMessage.response(to: Data(repeating: 0, count: length))) }
        var bad = dnsQuery("bbq.test", type: 1)
        bad[12] = 0xc0
        XCTAssertNil(DNSMessage.response(to: bad))
        XCTAssertNil(DNSMessage.response(to: dnsQuery("bbq.test", type: 1).dropLast()))
        bad = dnsQuery("bbq.test", type: 1); bad[5] = 2
        XCTAssertNil(DNSMessage.response(to: bad))
        bad = dnsQuery("bbq.test", type: 1); bad[2] = 0x81
        XCTAssertNil(DNSMessage.response(to: bad))
    }

    func testMappingsRoundTrip() throws {
        let original = DomainMapping(domain: "bbq.test", container: container(), port: 80)
        XCTAssertEqual(try JSONDecoder().decode(DomainMapping.self, from: JSONEncoder().encode(original)), original)
    }

    private func container(name: String = "bbq-web", running: Bool = true, project: String = "bbq") -> Container {
        Container(id: "123456789abcdef", name: name, image: "node", running: running, project: project, service: "web", ports: [80])
    }
    private func dnsQuery(_ name: String, type: UInt16) -> Data {
        var bytes: [UInt8] = [0x12, 0x34, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0]
        for label in name.split(separator: ".") { bytes.append(UInt8(label.utf8.count)); bytes.append(contentsOf: label.utf8) }
        bytes += [0, UInt8(type >> 8), UInt8(type & 255), 0, 1]
        return Data(bytes)
    }
}
