import XCTest

/// Drives the home screen in demo mode (fixture servers, simulated tunnel, no network).
/// Each test starts the app with `-ParadiseDemo <scenario>`; see Demo.swift.
final class ParadiseUITests: XCTestCase {
  private var app: XCUIApplication!

  override func setUp() {
    continueAfterFailure = false
  }

  private func launch(_ scenario: String, keep: Bool = false) {
    app = XCUIApplication()
    app.launchArguments = ["-ParadiseDemo", scenario, "-pref.language", "en"]
    if keep { app.launchArguments += ["-ParadiseDemoKeep", "YES"] }
    app.launch()
    XCTAssertTrue(element("status.title").waitForExistence(timeout: 20), "home screen did not appear")
    if scenario != "empty" {
      XCTAssertTrue(element("row.DE").waitForExistence(timeout: 10), "server list did not load")
    }
  }

  private func element(_ id: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: id).firstMatch
  }

  private func label(_ id: String) -> String { element(id).label }

  private func wait(_ id: String, label expected: String, timeout: TimeInterval = 6, file: StaticString = #filePath, line: UInt = #line) {
    let predicate = NSPredicate(format: "label == %@", expected)
    let done = XCTNSPredicateExpectation(predicate: predicate, object: element(id))
    let result = XCTWaiter().wait(for: [done], timeout: timeout)
    XCTAssertEqual(result, .completed, "\(id): expected “\(expected)”, got “\(label(id))”", file: file, line: line)
  }

  private func waitContains(_ id: String, _ text: String, timeout: TimeInterval = 6, file: StaticString = #filePath, line: UInt = #line) {
    let predicate = NSPredicate(format: "label CONTAINS %@", text)
    let done = XCTNSPredicateExpectation(predicate: predicate, object: element(id))
    let result = XCTWaiter().wait(for: [done], timeout: timeout)
    XCTAssertEqual(result, .completed, "\(id): expected to contain “\(text)”, got “\(label(id))”", file: file, line: line)
  }

  /// Taps the star at the start of a server row.
  private func tapRowStar(_ id: String) {
    let row = element(id)
    row.coordinate(withNormalizedOffset: CGVector(dx: 40.0 / 616.0, dy: 0.5)).tap()
  }

  // MARK: Initial state

  func testReferenceState() {
    launch("reference")
    XCTAssertEqual(label("status.title"), "Not Connected")
    XCTAssertEqual(label("status.subtitle"), "Select a server")
    XCTAssertEqual(label("info.ip"), "212.109.219.74")
    XCTAssertEqual(label("info.location"), "Estonia, Tallinn")
    XCTAssertTrue(label("info.protocol").hasSuffix("WireGuard"), label("info.protocol"))
    for cc in ["DE", "NL", "GB", "FR", "US"] {
      XCTAssertTrue(element("row.\(cc)").exists, "row \(cc) missing")
      XCTAssertFalse(element("row.\(cc)").isSelected, "row \(cc) should not be selected")
    }
    for cc in ["DE", "GB", "NL", "FR", "US", "CA", "RU", "TR", "BR", "SG", "AU"] {
      XCTAssertTrue(element("node.\(cc)").exists, "map node \(cc) missing")
    }
    // one source of latency: the map node and the row show the same number
    XCTAssertTrue(label("node.DE").contains("24 ms"), label("node.DE"))
    XCTAssertTrue(label("row.DE").contains("24 ms"), label("row.DE"))
    XCTAssertTrue(label("row.DE").contains("Germany") && label("row.DE").contains("Frankfurt"), label("row.DE"))
    XCTAssertTrue(label("row.DE").contains("WG") && label("row.DE").contains("10 Gbps"), label("row.DE"))
    // rows keep the subscription order: Germany, the Netherlands, the UK, France, the United States
    XCTAssertLessThan(element("row.DE").frame.minY, element("row.NL").frame.minY)
    XCTAssertLessThan(element("row.NL").frame.minY, element("row.GB").frame.minY)
  }

  // MARK: Connection

  func testConnectDisconnectWithTimer() {
    launch("reference")
    element("action.connect").tap()
    wait("status.title", label: "Connected")
    waitContains("status.subtitle", "Germany, Frankfurt") // nothing selected: the fastest server
    let first = label("status.subtitle")
    sleep(2)
    XCTAssertNotEqual(label("status.subtitle"), first, "timer does not tick")
    waitContains("info.ip", "203.0.113.")
    wait("info.location", label: "Germany, Frankfurt")
    XCTAssertTrue(element("row.DE").isSelected)
    XCTAssertEqual(element("action.connect").label, "Disconnect")
    element("action.connect").tap()
    wait("status.title", label: "Not Connected")
    wait("info.ip", label: "212.109.219.74")
    XCTAssertEqual(element("action.connect").label, "Connect")
  }

  func testPowerButtonInStatusCard() {
    launch("reference")
    element("action.power").tap()
    wait("status.title", label: "Connected")
    element("action.power").tap()
    wait("status.title", label: "Not Connected")
  }

  func testConnectingState() {
    launch("connecting")
    XCTAssertEqual(label("status.title"), "Connecting…")
    waitContains("status.subtitle", "Netherlands, Amsterdam")
  }

  func testConnectedStateShowsTrafficRates() {
    launch("connected")
    XCTAssertEqual(label("status.title"), "Connected")
    XCTAssertTrue(element("status.rates").waitForExistence(timeout: 4))
    XCTAssertTrue(label("status.rates").contains("↓"), label("status.rates"))
  }

  // MARK: Selection

  func testSelectionSyncBetweenRowsMapAndCard() {
    launch("reference")
    element("row.NL").tap()
    XCTAssertTrue(element("row.NL").waitForSelection())
    XCTAssertTrue(element("node.NL").isSelected, "map node not highlighted")
    wait("status.subtitle", label: "Netherlands, Amsterdam")
    element("node.GB").tap() // a country on the map connects to its fastest server
    wait("status.title", label: "Connected")
    waitContains("status.subtitle", "United Kingdom, London")
    XCTAssertTrue(element("row.GB").isSelected)
    XCTAssertFalse(element("row.NL").isSelected)
    XCTAssertTrue(element("node.GB").isSelected)
  }

  func testFastestSelectsLowestPing() {
    launch("reference")
    element("region.fastest").tap()
    XCTAssertTrue(element("row.DE").waitForSelection())
    wait("status.subtitle", label: "Germany, Frankfurt")
  }

  // MARK: Filters, sorting, search

  func testRegionFilters() {
    launch("reference")
    element("region.asia").tap()
    XCTAssertTrue(element("row.SG").waitForExistence(timeout: 3))
    XCTAssertFalse(element("row.DE").exists)
    element("region.americas").tap()
    XCTAssertTrue(element("row.US").waitForExistence(timeout: 3))
    XCTAssertTrue(element("row.CA").exists)
    XCTAssertTrue(element("row.BR").exists)
    XCTAssertFalse(element("row.DE").exists)
    element("region.europe").tap()
    XCTAssertTrue(element("row.DE").waitForExistence(timeout: 3))
    XCTAssertFalse(element("row.US").exists)
    element("region.all").tap()
    XCTAssertTrue(element("row.US").waitForExistence(timeout: 3))
  }

  func testPingSortCycles() {
    launch("full")
    // list order first: the United States (76 ms) comes before Türkiye (69 ms), as the subscription lists them
    XCTAssertLessThan(element("row.US").frame.minY, element("row.TR").frame.minY)
    element("table.ping").tap() // fastest first
    XCTAssertLessThan(element("row.TR").frame.minY, element("row.US").frame.minY)
    XCTAssertLessThan(element("row.DE").frame.minY, element("row.NL").frame.minY)
    element("table.ping").tap() // slowest first
    XCTAssertLessThan(element("row.AU").frame.minY, element("row.SG").frame.minY)
    XCTAssertLessThan(element("row.SG").frame.minY, element("row.BR").frame.minY)
    element("table.ping").tap() // back to the list order
    XCTAssertLessThan(element("row.US").frame.minY, element("row.TR").frame.minY)
  }

  func testSearch() {
    launch("reference")
    element("panel.search").tap()
    let field = element("panel.searchField")
    XCTAssertTrue(field.waitForExistence(timeout: 3))
    field.typeText("lon")
    XCTAssertTrue(element("row.GB").waitForExistence(timeout: 3))
    XCTAssertFalse(element("row.DE").exists)
    element("panel.search").tap() // closes the search and clears it
    XCTAssertTrue(element("row.DE").waitForExistence(timeout: 3))
  }

  func testProtocolMenuFiltersServers() {
    launch("long")
    element("info.protocol").tap()
    let trojan = app.buttons["Trojan"]
    XCTAssertTrue(trojan.waitForExistence(timeout: 3), "protocol menu did not open")
    trojan.tap()
    waitContains("info.protocol", "Trojan")
    XCTAssertTrue(element("row.DE").waitForExistence(timeout: 3))
    XCTAssertTrue(label("row.DE").contains("Trojan"), label("row.DE"))
    XCTAssertFalse(element("row.NL").exists)
    element("info.protocol").tap()
    app.buttons["Auto"].tap()
    XCTAssertTrue(element("row.NL").waitForExistence(timeout: 3))
  }

  func testLongNamesStayOnOneLine() {
    launch("long")
    XCTAssertTrue(element("row.BA").waitForExistence(timeout: 3))
    let row = element("row.BA").frame
    XCTAssertEqual(row.height, element("row.DE").frame.height, accuracy: 1, "a long name changed the row height")
    if !element("row.none").exists { element("row.BA").swipeUp() }
    XCTAssertTrue(element("row.none").waitForExistence(timeout: 3), "server without a country is missing")
  }

  func testCountryListFromMapNode() {
    launch("reference")
    element("node.FR").press(forDuration: 1.0)
    let show = app.buttons["Show servers"]
    XCTAssertTrue(show.waitForExistence(timeout: 3))
    show.tap()
    XCTAssertTrue(element("region.country").waitForExistence(timeout: 3))
    XCTAssertTrue(element("row.FR").exists)
    XCTAssertFalse(element("row.DE").exists)
    element("region.country").tap()
    XCTAssertTrue(element("row.DE").waitForExistence(timeout: 3))
  }

  // MARK: Favorites and tabs

  func testFavoritesPersistAcrossLaunches() {
    launch("reference")
    tapRowStar("row.DE")
    element("tab.favorites").tap()
    XCTAssertTrue(element("row.DE").waitForExistence(timeout: 3))
    XCTAssertFalse(element("row.NL").exists)
    app.terminate()
    launch("reference", keep: true)
    element("tab.favorites").tap()
    XCTAssertTrue(element("row.DE").waitForExistence(timeout: 3), "favorite was not kept")
    // the star in the action bar toggles the selected server
    element("tab.servers").tap()
    element("row.NL").tap()
    XCTAssertTrue(element("row.NL").waitForSelection())
    element("action.favorite").tap()
    element("tab.favorites").tap()
    XCTAssertTrue(element("row.NL").waitForExistence(timeout: 3))
  }

  func testTabs() {
    launch("reference")
    element("tab.routes").tap()
    XCTAssertTrue(element("route.all").waitForExistence(timeout: 3))
    XCTAssertTrue(element("route.config").exists)
    element("tab.favorites").tap()
    XCTAssertTrue(element("table.empty").waitForExistence(timeout: 3))
    element("tab.servers").tap()
    XCTAssertTrue(element("row.DE").waitForExistence(timeout: 3))
  }

  // MARK: Header, menu, sheets

  func testBellOpensNotifications() {
    launch("reference")
    element("header.bell").tap()
    let notice = app.staticTexts["Demo mode: sample servers, no network requests."]
    XCTAssertTrue(notice.waitForExistence(timeout: 4))
  }

  func testMoreMenu() {
    launch("reference")
    element("header.menu").tap()
    XCTAssertTrue(app.buttons["Add"].waitForExistence(timeout: 3))
    XCTAssertTrue(app.buttons["Share"].exists)
    XCTAssertTrue(app.buttons["Update subscriptions"].exists)
    XCTAssertTrue(app.buttons["Diagnostics"].exists)
  }

  func testSlidersOpenControlCenter() {
    launch("reference")
    element("action.settings").tap()
    XCTAssertTrue(app.segmentedControls.buttons["Settings"].waitForExistence(timeout: 4))
    app.segmentedControls.buttons["Config"].tap()
    app.segmentedControls.buttons["Data"].tap()
    XCTAssertTrue(app.segmentedControls.buttons["Data"].isSelected)
  }

  func testEmptyState() {
    launch("empty")
    XCTAssertEqual(label("status.subtitle"), "Select a server")
    XCTAssertTrue(element("table.empty").waitForExistence(timeout: 3))
    XCTAssertFalse(element("node.DE").exists)
  }
}

private extension XCUIElement {
  /// Waits until the element reports the selected trait.
  func waitForSelection(timeout: TimeInterval = 4) -> Bool {
    let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: self)
    return XCTWaiter().wait(for: [done], timeout: timeout) == .completed
  }
}
