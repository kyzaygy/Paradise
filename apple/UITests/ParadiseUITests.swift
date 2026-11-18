import XCTest

/// Drives the home screen in demo mode (fixture servers, simulated tunnel, no network).
/// Each launch is slow on CI, so every test walks through several functions in one launch.
/// The tests run in name order: test1… seeds a favorite that test2… expects after a relaunch.
final class ParadiseUITests: XCTestCase {
  private var app: XCUIApplication!

  override func setUp() {
    continueAfterFailure = true
  }

  private func launch(_ scenario: String, keep: Bool = false) {
    app = XCUIApplication()
    app.launchArguments = ["-ParadiseDemo", scenario, "-pref.language", "en"]
    if keep { app.launchArguments += ["-ParadiseDemoKeep", "YES"] }
    app.launch()
    XCTAssertTrue(element("status.title").waitForExistence(timeout: 30), "home screen did not appear")
    if scenario != "empty" {
      XCTAssertTrue(element("row.DE").waitForExistence(timeout: 15), "server list did not load")
    }
  }

  private func element(_ id: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: id).firstMatch
  }

  private func label(_ id: String) -> String { element(id).label }

  private func wait(_ id: String, label expected: String, timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line) {
    let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", expected), object: element(id))
    let result = XCTWaiter().wait(for: [done], timeout: timeout)
    XCTAssertEqual(result, .completed, "\(id): expected “\(expected)”, got “\(label(id))”", file: file, line: line)
  }

  private func waitContains(_ id: String, _ text: String, timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line) {
    let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", text), object: element(id))
    let result = XCTWaiter().wait(for: [done], timeout: timeout)
    XCTAssertEqual(result, .completed, "\(id): expected to contain “\(text)”, got “\(label(id))”", file: file, line: line)
  }

  private func waitSelected(_ id: String, timeout: TimeInterval = 6) -> Bool {
    let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: element(id))
    return XCTWaiter().wait(for: [done], timeout: timeout) == .completed
  }

  private func above(_ a: String, _ b: String) -> Bool { element(a).frame.minY < element(b).frame.minY }

  /// Frames of a few elements, for failure messages.
  private func frames(_ ids: String...) -> String {
    ids.map { "\($0) \(element($0).frame)" }.joined(separator: ", ")
  }

  /// Closes a sheet by swiping it down.
  private func dismissOverlay() {
    app.swipeDown(velocity: .fast)
    sleep(1)
  }

  // MARK: 1. Everything on the reference screen

  func test1HomeScreenFunctions() {
    launch("reference")

    XCTContext.runActivity(named: "initial state matches the mock") { _ in
      XCTAssertEqual(label("status.title"), "Not Connected")
      XCTAssertEqual(label("status.subtitle"), "Select a server")
      XCTAssertEqual(label("info.ip"), "212.109.219.74")
      XCTAssertEqual(label("info.location"), "Estonia, Tallinn")
      XCTAssertTrue(label("info.protocol").hasSuffix("WireGuard"), label("info.protocol"))
      for cc in ["DE", "GB", "NL", "FR", "US", "CA", "RU", "TR", "BR", "SG", "AU"] {
        XCTAssertTrue(element("node.\(cc)").exists, "map node \(cc) missing")
      }
      XCTAssertTrue(label("node.DE").contains("24 ms"), label("node.DE"))
      XCTAssertTrue(label("row.DE").contains("24 ms"), "map and list must show the same ping: \(label("row.DE"))")
      XCTAssertTrue(label("row.DE").contains("Germany") && label("row.DE").contains("Frankfurt"), label("row.DE"))
      XCTAssertTrue(label("row.DE").contains("WG") && label("row.DE").contains("10 Gbps"), label("row.DE"))
      XCTAssertTrue(above("row.DE", "row.NL") && above("row.NL", "row.GB"), "rows keep the subscription order")
      XCTAssertFalse(element("row.DE").isSelected)
    }

    XCTContext.runActivity(named: "selection sync: row, map node, status card") { _ in
      element("row.NL").tap()
      XCTAssertTrue(waitSelected("row.NL"), "row not selected")
      XCTAssertTrue(waitSelected("node.NL"), "map node not highlighted")
      wait("status.subtitle", label: "Netherlands, Amsterdam")
    }

    XCTContext.runActivity(named: "Fastest selects the lowest ping") { _ in
      element("region.fastest").tap()
      XCTAssertTrue(waitSelected("row.DE"))
      wait("status.subtitle", label: "Germany, Frankfurt")
    }

    XCTContext.runActivity(named: "region filters") { _ in
      element("region.asia").tap()
      XCTAssertTrue(element("row.SG").waitForExistence(timeout: 4))
      XCTAssertFalse(element("row.DE").exists)
      element("region.americas").tap()
      XCTAssertTrue(element("row.US").waitForExistence(timeout: 4))
      XCTAssertTrue(element("row.BR").exists && element("row.CA").exists)
      XCTAssertFalse(element("row.DE").exists)
      element("region.europe").tap()
      XCTAssertTrue(element("row.DE").waitForExistence(timeout: 4))
      XCTAssertFalse(element("row.US").exists)
      element("region.all").tap()
      XCTAssertTrue(element("row.US").waitForExistence(timeout: 4))
    }

    XCTContext.runActivity(named: "ping sort cycles ascending, descending, off") { _ in
      element("table.ping").tap()
      XCTAssertTrue(element("row.DE").waitForExistence(timeout: 4))
      XCTAssertTrue(above("row.DE", "row.NL"), "fastest first")
      element("table.ping").tap()
      XCTAssertTrue(element("row.AU").waitForExistence(timeout: 4), "slowest first: Australia on top")
      XCTAssertTrue(above("row.AU", "row.SG"))
      element("table.ping").tap()
      XCTAssertTrue(element("row.DE").waitForExistence(timeout: 4))
      XCTAssertTrue(above("row.DE", "row.NL"))
    }

    // the map steps come before the search: searching opens the panel over the map
    XCTContext.runActivity(named: "connect, timer, IP and location, disconnect") { _ in
      element("action.connect").tap()
      wait("status.title", label: "Connected")
      waitContains("status.subtitle", "Germany, Frankfurt")
      let first = label("status.subtitle")
      sleep(2)
      XCTAssertNotEqual(label("status.subtitle"), first, "timer does not tick")
      waitContains("info.ip", "203.0.113.")
      wait("info.location", label: "Germany, Frankfurt")
      XCTAssertTrue(element("status.rates").waitForExistence(timeout: 4), "traffic rates missing")
      XCTAssertEqual(element("action.connect").label, "Disconnect")
      element("action.connect").tap()
      wait("status.title", label: "Not Connected")
      wait("info.ip", label: "212.109.219.74")
    }

    XCTContext.runActivity(named: "power button and map node") { _ in
      element("action.power").tap()
      wait("status.title", label: "Connected")
      let node = element("node.GB")
      XCTAssertTrue(node.isHittable, "map node is covered: \(frames("node.GB", "tab.servers"))")
      node.tap() // switches the tunnel to the fastest server of that country
      waitContains("status.subtitle", "United Kingdom, London")
      XCTAssertTrue(waitSelected("row.GB"), "the tap did not reach the map node: \(frames("node.GB", "tab.servers"))")
      element("action.power").tap()
      wait("status.title", label: "Not Connected")
    }

    XCTContext.runActivity(named: "country list from a map node") { _ in
      element("node.US").press(forDuration: 1.2)
      let show = app.buttons["Show servers"]
      guard show.waitForExistence(timeout: 4) else {
        XCTFail("a long press did not open the country menu: \(frames("node.US", "tab.servers"))")
        return
      }
      show.tap()
      XCTAssertTrue(element("region.country").waitForExistence(timeout: 4))
      XCTAssertTrue(element("row.US").exists)
      XCTAssertFalse(element("row.DE").exists)
      element("region.country").tap()
      XCTAssertTrue(element("row.DE").waitForExistence(timeout: 4))
    }

    XCTContext.runActivity(named: "search") { _ in
      element("panel.search").tap()
      let field = element("panel.searchField")
      XCTAssertTrue(field.waitForExistence(timeout: 4))
      field.tap()
      field.typeText("lon")
      XCTAssertTrue(element("row.GB").waitForExistence(timeout: 4))
      XCTAssertFalse(element("row.DE").exists)
      element("panel.search").tap()
      XCTAssertTrue(element("row.DE").waitForExistence(timeout: 4), "closing the search clears it")
    }

    XCTContext.runActivity(named: "favorites: row star and action bar star") { _ in
      let row = element("row.DE")
      row.coordinate(withNormalizedOffset: CGVector(dx: 40.0 / 616.0, dy: 0.5)).tap()
      element("tab.favorites").tap()
      XCTAssertTrue(element("row.DE").waitForExistence(timeout: 4))
      XCTAssertFalse(element("row.NL").exists)
      element("tab.servers").tap()
      element("row.FR").tap()
      XCTAssertTrue(waitSelected("row.FR"))
      element("action.favorite").tap()
      element("tab.favorites").tap()
      XCTAssertTrue(element("row.FR").waitForExistence(timeout: 4), "action bar star adds the selected server")
      element("tab.routes").tap()
      XCTAssertTrue(element("route.all").waitForExistence(timeout: 4))
      XCTAssertTrue(element("route.config").exists)
      element("tab.servers").tap()
      XCTAssertTrue(element("row.DE").waitForExistence(timeout: 4))
    }

    XCTContext.runActivity(named: "bell, more menu, control center") { _ in
      element("header.bell").tap()
      XCTAssertTrue(app.staticTexts["Demo mode: sample servers, no network requests."].waitForExistence(timeout: 5))
      dismissOverlay()
      element("header.menu").tap()
      XCTAssertTrue(app.buttons["Add"].waitForExistence(timeout: 4))
      XCTAssertTrue(app.buttons["Share"].exists && app.buttons["Diagnostics"].exists)
      app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
      sleep(1)
      element("action.settings").tap()
      XCTAssertTrue(app.segmentedControls.buttons["Settings"].waitForExistence(timeout: 5))
      app.segmentedControls.buttons["Data"].tap()
      XCTAssertTrue(app.segmentedControls.buttons["Data"].isSelected)
    }
  }

  // MARK: 2. Favorites survive a relaunch

  func test2FavoritesPersist() {
    launch("reference", keep: true)
    element("tab.favorites").tap()
    XCTAssertTrue(element("row.DE").waitForExistence(timeout: 5), "favorite from the previous launch is gone")
  }

  // MARK: 3. Protocol menu and long names

  func test3ProtocolMenuAndLongNames() {
    launch("long")
    XCTAssertTrue(element("row.BA").waitForExistence(timeout: 5))
    XCTAssertEqual(element("row.BA").frame.height, element("row.DE").frame.height, accuracy: 1, "a long name changed the row height")
    element("info.protocol").tap()
    let trojan = app.buttons["Trojan"]
    XCTAssertTrue(trojan.waitForExistence(timeout: 4), "protocol menu did not open")
    trojan.tap()
    waitContains("info.protocol", "Trojan")
    XCTAssertTrue(element("row.DE").waitForExistence(timeout: 4))
    XCTAssertTrue(label("row.DE").contains("Trojan"), label("row.DE"))
    XCTAssertFalse(element("row.NL").exists)
    element("info.protocol").tap()
    app.buttons["Auto"].tap()
    XCTAssertTrue(element("row.NL").waitForExistence(timeout: 4))
  }

  // MARK: 4. Other states

  func test4States() {
    launch("connecting")
    XCTAssertEqual(label("status.title"), "Connecting…")
    waitContains("status.subtitle", "Netherlands, Amsterdam")
    app.terminate()

    launch("empty")
    XCTAssertEqual(label("status.subtitle"), "Select a server")
    XCTAssertTrue(element("table.empty").waitForExistence(timeout: 4))
    XCTAssertFalse(element("node.DE").exists)
  }
}
