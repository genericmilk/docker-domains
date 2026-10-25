import XCTest
@testable import DomainCore

@MainActor
final class DockerIntegrationTests: XCTestCase {
    func testRealDockerRoutingLifecycle() async throws {
        guard ProcessInfo.processInfo.environment["DOCKER_DOMAINS_INTEGRATION"] == "1" else {
            throw XCTSkip("Set DOCKER_DOMAINS_INTEGRATION=1 to test against your local Docker engine. Requires port 80 and no existing Docker Domains proxy.")
        }
        let docker = "/usr/local/bin/docker"
        let existing = try await Command.run(docker, ["ps", "-aq", "--filter", "name=^/docker-domains-proxy$"])
        guard existing.output.isEmpty else { throw XCTSkip("An existing Docker Domains proxy must be left untouched.") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dd-integration-\(UUID().uuidString)")
        let service = DockerService(directory: directory)
        let fixture = "dd-fixture-" + String(UUID().uuidString.prefix(8)).lowercased()
        let second = fixture + "-b"
        let source = #"const http=require('http'), crypto=require('crypto'); const server=http.createServer((q,r)=>{if(q.url==='/events'){r.writeHead(200,{'Content-Type':'text/event-stream'});r.write('data: ready\n\n');setTimeout(()=>r.end('data: done\n\n'),100)}else{r.end(process.env.SITE+':'+q.headers.host+':'+q.url)}});server.on('upgrade',(q,s)=>{const key=crypto.createHash('sha1').update(q.headers['sec-websocket-key']+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');s.write('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: '+key+'\r\n\r\n');s.end(Buffer.from([0x81,2,111,107]));});server.listen(3000,'0.0.0.0');"#
        do {
            for (name, site) in [(fixture, "A"), (second, "B")] {
                let result = try await Command.run(docker, ["run", "-d", "--name", name, "--expose", "3000", "-e", "SITE=\(site)", "node:22-alpine", "node", "-e", source])
                XCTAssertEqual(result.status, 0, result.output)
            }
            var containers = try await service.containers()
            var target = try XCTUnwrap(containers.first { $0.name == fixture })
            let targetB = try XCTUnwrap(containers.first { $0.name == second })
            let mappings = [DomainMapping(domain: "smoke-a.test", container: target, port: 3000),
                            DomainMapping(domain: "smoke-b.test", container: targetB, port: 3000)]
            try await service.synchronize(mappings, containers: containers)
            let a = try await curl("smoke-a.test", "/hello?q=1")
            XCTAssertEqual(a, "A:smoke-a.test:/hello?q=1")
            let b = try await curl("smoke-b.test", "/")
            XCTAssertEqual(b, "B:smoke-b.test:/")
            let events = try await curl("smoke-a.test", "/events")
            XCTAssertTrue(events.contains("data: ready\n\ndata: done"), events)
            let ws = try await Command.run("/usr/bin/curl", ["--noproxy", "*", "-si", "--max-time", "3", "--resolve", "smoke-a.test:80:127.0.0.1", "-H", "Connection: Upgrade", "-H", "Upgrade: websocket", "-H", "Sec-WebSocket-Version: 13", "-H", "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==", "http://smoke-a.test/socket"])
            XCTAssertTrue(ws.output.contains("101 Switching Protocols"), ws.output)
            XCTAssertTrue(ws.output.contains("ok"), ws.output)
            let unknown = try await curl("unknown.test", "/", statusOnly: true)
            XCTAssertEqual(unknown, "404")

            // Container restarts must not leave a route pointing at a stale IP.
            _ = try await Command.run(docker, ["restart", fixture])
            containers = try await service.containers()
            try await service.synchronize(mappings, containers: containers)
            let afterRestart = try await curl("smoke-a.test", "/restart")
            XCTAssertEqual(afterRestart, "A:smoke-a.test:/restart")

            // Recreate the container under its existing name: discovery attaches the new endpoint.
            let previousID = target.id
            _ = try await Command.run(docker, ["rm", "-f", fixture])
            _ = try await Command.run(docker, ["run", "-d", "--name", fixture, "--expose", "3000", "-e", "SITE=C", "node:22-alpine", "node", "-e", source])
            containers = try await service.containers()
            target = try XCTUnwrap(containers.first { $0.name == fixture })
            XCTAssertNotEqual(target.id, previousID)
            try await service.synchronize(mappings, containers: containers)
            let afterRecreation = try await curl("smoke-a.test", "/recreated")
            XCTAssertEqual(afterRecreation, "C:smoke-a.test:/recreated")

            var paused = mappings; paused[0].enabled = false
            try await service.synchronize(paused, containers: containers)
            let removed = try await curl("smoke-a.test", "/", statusOnly: true)
            XCTAssertEqual(removed, "404")
            try await service.synchronize([], containers: containers)
            let running = await service.proxyRunning()
            XCTAssertFalse(running)
            try await service.removeInfrastructure()
        } catch {
            try? await service.removeInfrastructure()
            _ = try? await Command.run(docker, ["rm", "-f", fixture, second])
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        _ = try await Command.run(docker, ["rm", "-f", fixture, second])
        try? FileManager.default.removeItem(at: directory)
    }

    private func curl(_ host: String, _ path: String, statusOnly: Bool = false) async throws -> String {
        var args = ["--noproxy", "*", "--silent", "--show-error", "--retry", "5", "--retry-delay", "1", "--retry-all-errors", "--max-time", "5", "--resolve", "\(host):80:127.0.0.1"]
        if statusOnly { args += ["-o", "/dev/null", "-w", "%{http_code}"] }
        args.append("http://\(host)\(path)")
        let result = try await Command.run("/usr/bin/curl", args)
        XCTAssertEqual(result.status, 0, result.output)
        return result.output
    }
}
