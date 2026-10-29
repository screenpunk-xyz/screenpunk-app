import Foundation
import XCTest
@testable import DeviceAuthoring

final class LocalComputerDiscoveryTests: XCTestCase {
    private final class FakeBrowser: NetServiceBrowser {
        var searches = 0, stops = 0
        override func searchForServices(ofType type: String, inDomain domain: String) { searches += 1 }
        override func stop() { stops += 1 }
    }
    private final class FakeService: NetService {
        var resolves = 0, stops = 0
        var resolvedHost: String? = "fixture.local."
        var resolvedPort = 22
        override var hostName: String? { resolvedHost }
        override var port: Int { resolvedPort }
        override func resolve(withTimeout timeout: TimeInterval) { resolves += 1 }
        override func stop() { stops += 1 }
    }
    @MainActor private final class Deadlines {
        struct Item { let seconds: TimeInterval; let action: @MainActor () -> Void; var cancelled = false }
        var items: [Item] = []
        func schedule(_ seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) -> () -> Void {
            let index = items.count; items.append(.init(seconds: seconds, action: action))
            return { [weak self] in self?.items[index].cancelled = true }
        }
        func fire(_ index: Int, includingCancelled: Bool = false) {
            if includingCancelled || !items[index].cancelled { items[index].action() }
        }
    }
    @MainActor private final class Fixture {
        var browsers: [FakeBrowser] = [], services: [FakeService] = []
        let deadlines = Deadlines()
        var discovery: LocalComputerDiscovery!
        init(identities: Int = 4, concurrent: Int = 2) {
            discovery = LocalComputerDiscovery(limits: .init(identities: identities, concurrentResolutions: concurrent, duration: 10),
                makeBrowser: { [unowned self] in let value = FakeBrowser(); self.browsers.append(value); return value },
                makeService: { [unowned self] domain, type, name in
                    let value = FakeService(domain: domain, type: type, name: name)
                    self.services.append(value); return value
                }, scheduleDeadline: { [unowned self] seconds, action in self.deadlines.schedule(seconds, action) })
            discovery.start()
        }
        var browser: FakeBrowser { browsers.last! }
        var active: [FakeService] { services.filter { $0.resolves > 0 && $0.stops == 0 } }
        func announcement(_ name: String, type: String = "_ssh._tcp.", domain: String = "local.") -> FakeService {
            FakeService(domain: domain, type: type, name: name)
        }
        func find(_ name: String) { discovery.netServiceBrowser(browser, didFind: announcement(name), moreComing: true) }
        func remove(_ name: String) { discovery.netServiceBrowser(browser, didRemove: announcement(name), moreComing: true) }
    }
    @MainActor private func drain(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1_000 { if condition() { return }; await Task.yield() }
        XCTAssertTrue(condition(), "Expected bounded callback work to finish", file: file, line: line)
    }
    @MainActor func testAdmissionIsBoundedBeforeActorHopAndResolversAreCapped() async {
        let f = Fixture(); defer { f.discovery.stop() }
        for name in ["Zulu", "Alpha", "Mac", "Beta", "Ignored"] { f.find(name) }
        for _ in 0..<12 { f.find("Zulu"); f.find("Ignored") }
        XCTAssertEqual(f.discovery.budgetSnapshot.identities, 4)
        XCTAssertEqual(f.discovery.budgetSnapshot.callbackTasks, 4, "No actor tasks for duplicates or excess identities")
        XCTAssertTrue(f.services.isEmpty, "Admission is checked before queued actor work executes")
        await drain { f.active.count == 2 }
        XCTAssertEqual(f.discovery.budgetSnapshot.resolvers, 2)
        XCTAssertGreaterThanOrEqual(f.browser.stops, 1)
        for count in 1...4 {
            XCTAssertLessThanOrEqual(f.active.count, 2)
            f.discovery.netServiceDidResolveAddress(f.active[0])
            await drain { f.discovery.computers.count == count }
        }
        XCTAssertEqual(f.discovery.computers.map(\.name), ["Alpha", "Beta", "Mac", "Zulu"])
        XCTAssertEqual(f.services.count, 4)
        XCTAssertTrue(f.services.allSatisfy { $0.resolves == 1 && $0.stops == 1 && $0.delegate == nil })
        XCTAssertFalse(f.discovery.searching)
        XCTAssertTrue(f.deadlines.items[0].cancelled)
        XCTAssertTrue(f.discovery.message?.contains("limit") == true)
    }
    @MainActor func testFailureAndRemovalCannotRecycleAdmissionOrScheduleRepeatedCompletions() async {
        let f = Fixture(concurrent: 1); defer { f.discovery.stop() }
        f.find("First"); await drain { f.active.count == 1 }
        let first = f.active[0]
        for _ in 0..<12 {
            f.discovery.netService(first, didNotResolve: [:])
            f.discovery.netServiceDidResolveAddress(first)
        }
        XCTAssertEqual(f.discovery.budgetSnapshot.callbackTasks, 2)
        await drain { first.stops == 1 }
        XCTAssertTrue(f.discovery.computers.isEmpty)
        for _ in 0..<12 { f.remove("First"); f.find("First") }
        XCTAssertEqual(f.discovery.budgetSnapshot.identities, 1)
        XCTAssertEqual(f.discovery.budgetSnapshot.callbackTasks, 3)
        f.find("Second"); await drain { f.active.count == 1 }
        f.remove("Second"); await drain { f.active.isEmpty }
        f.find("Second"); f.find("Third"); f.find("Fourth"); f.find("Fifth")
        XCTAssertEqual(f.discovery.budgetSnapshot.identities, 4)
        await drain { f.active.count == 1 }
        for _ in 0..<2 {
            let service = f.active[0]; f.discovery.netService(service, didNotResolve: [:])
            await drain { service.stops == 1 }
        }
        XCTAssertFalse(f.discovery.searching)
        XCTAssertEqual(f.services.count, 4)
        XCTAssertLessThanOrEqual(f.discovery.budgetSnapshot.callbackTasks, 3 * 4 + 1)
        f.find("Fifth"); XCTAssertEqual(f.services.count, 4)
    }
    @MainActor func testDeadlineReleasesResolversPreservesResultsAndFencesOldGenerations() async {
        let f = Fixture(); defer { f.discovery.stop() }
        f.find("Alpha"); f.find("Beta"); await drain { f.active.count == 2 }
        let oldBrowser = f.browser, oldService = f.active.first { $0.name == "Beta" }!
        f.discovery.netServiceDidResolveAddress(f.active.first { $0.name == "Alpha" }!)
        await drain { f.discovery.computers.count == 1 }
        XCTAssertEqual(f.deadlines.items[0].seconds, 10)
        f.deadlines.fire(0)
        XCTAssertFalse(f.discovery.searching); XCTAssertEqual(oldService.stops, 1)
        XCTAssertTrue(f.active.isEmpty); XCTAssertEqual(f.discovery.computers.map(\.name), ["Alpha"])
        let tasks = f.discovery.budgetSnapshot.callbackTasks
        f.discovery.netServiceBrowser(oldBrowser, didFind: f.announcement("Stale"), moreComing: false)
        f.discovery.netServiceDidResolveAddress(oldService)
        XCTAssertEqual(f.discovery.budgetSnapshot.callbackTasks, tasks)
        f.discovery.start(); let newBrowser = f.browser
        XCTAssertTrue(f.discovery.computers.isEmpty)
        f.deadlines.fire(0, includingCancelled: true)
        f.discovery.netServiceBrowser(oldBrowser, didNotSearch: [:])
        f.discovery.netServiceBrowser(oldBrowser, didRemove: f.announcement("Alpha"), moreComing: false)
        f.discovery.netServiceBrowser(oldBrowser, didFind: f.announcement("Stale"), moreComing: false)
        f.find("Beta"); await drain { f.active.count == 1 }
        f.discovery.netServiceDidResolveAddress(oldService)
        for _ in 0..<3 { await Task.yield() }
        XCTAssertTrue(f.discovery.computers.isEmpty)
        XCTAssertTrue(f.discovery.searching); XCTAssertEqual(newBrowser.stops, 0)
        f.discovery.netServiceDidResolveAddress(f.active[0]); await drain { f.discovery.computers.count == 1 }
        f.discovery.stop(); XCTAssertEqual(f.discovery.computers[0].name, "Beta")
    }
    @MainActor func testInvalidMetadataAndResolvedAddressesCannotRetainResources() async {
        let f = Fixture(); defer { f.discovery.stop() }
        for service in [f.announcement("Wrong", type: "_http._tcp."), f.announcement("Elsewhere", domain: "example.test."),
                        f.announcement("Bad\nname"), f.announcement(String(repeating: "a", count: 64))] {
            f.discovery.netServiceBrowser(f.browser, didFind: service, moreComing: false)
        }
        XCTAssertEqual(f.discovery.budgetSnapshot.callbackTasks, 0)
        f.find("Invalid host"); f.find("Invalid port"); await drain { f.active.count == 2 }
        let one = f.active[0], two = f.active[1]
        one.resolvedHost = "bad\nhost"; two.resolvedPort = 0
        f.discovery.netServiceDidResolveAddress(one); f.discovery.netServiceDidResolveAddress(two)
        await drain { f.active.isEmpty }
        XCTAssertTrue(f.discovery.computers.isEmpty)
        XCTAssertEqual(one.stops, 1); XCTAssertEqual(two.stops, 1)
        XCTAssertEqual(f.discovery.budgetSnapshot.resolvers, 0)
    }
    @MainActor func testRemovalBeforeQueuedAdmissionAndCompletionDoesNotPublishStaleResult() async {
        let f = Fixture(); defer { f.discovery.stop() }
        f.find("Removed early"); f.remove("Removed early")
        for _ in 0..<5 { await Task.yield() }
        XCTAssertTrue(f.services.isEmpty)
        f.find("Removed during resolution"); await drain { f.active.count == 1 }
        let service = f.active[0]
        f.discovery.netServiceDidResolveAddress(service); f.remove(service.name)
        await drain { service.stops == 1 }
        XCTAssertTrue(f.discovery.computers.isEmpty)
        f.find(service.name)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(f.services.count, 1, "Removed identities cannot restart resolution in the same session")
    }
    @MainActor func testBrowserFailureClaimsOnlyOneTaskAndStopsOwnedWork() async {
        let f = Fixture(); defer { f.discovery.stop() }
        f.find("Current"); await drain { f.active.count == 1 }
        let service = f.active[0], before = f.discovery.budgetSnapshot.callbackTasks
        for _ in 0..<12 { f.discovery.netServiceBrowser(f.browser, didNotSearch: [:]); f.find("Ignored") }
        XCTAssertEqual(f.discovery.budgetSnapshot.callbackTasks, before + 1)
        await drain { !f.discovery.searching }
        XCTAssertEqual(service.stops, 1); XCTAssertTrue(f.deadlines.items[0].cancelled)
        XCTAssertTrue(f.discovery.message?.contains("manually") == true)
    }
}
