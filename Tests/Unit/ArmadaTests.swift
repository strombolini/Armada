import XCTest
@testable import Armada

/// Pure-logic tests: matching, ranking, parsing. No network, no Codiv key needed.
final class CalculatorTests: XCTestCase {
    func testArithmetic() {
        XCTAssertEqual(Calculator.evaluate("2+2"), "4")
        XCTAssertEqual(Calculator.evaluate("15% of 80"), "12")
        XCTAssertEqual(Calculator.evaluate("2^10"), "1024")
        XCTAssertEqual(Calculator.evaluate("sqrt(144)"), "12")
        XCTAssertEqual(Calculator.evaluate("1500*1.08"), "1620")
        XCTAssertEqual(Calculator.evaluate("(3+4)*2"), "14")
        XCTAssertEqual(Calculator.evaluate("10/4"), "2.5")
    }

    func testRejectsNonExpressions() {
        XCTAssertNil(Calculator.evaluate("hello 2"))
        XCTAssertNil(Calculator.evaluate("resume"))
        XCTAssertNil(Calculator.evaluate("2+"))
        XCTAssertNil(Calculator.evaluate("lab 230"))
        XCTAssertNil(Calculator.evaluate("1/0"))   // not finite
    }
}

final class QueryWordsTests: XCTestCase {
    func testStopwordsAndShortTokensDropped() {
        XCTAssertEqual(Spotlight.words("the lease for my apartment"), ["lease", "apartment"])
        XCTAssertEqual(Spotlight.words("W2_Acme_2024.pdf"), ["acme", "2024", "pdf"])
    }

    func testNameShapedQueries() {
        XCTAssertTrue(SemanticSearch.looksLikeAName("resume.pdf"))
        XCTAssertTrue(SemanticSearch.looksLikeAName("lingbot_modal"))
        XCTAssertFalse(SemanticSearch.looksLikeAName("the lease for my apartment"))
        XCTAssertFalse(SemanticSearch.looksLikeAName("lasagna"))
    }
}

final class SystemIndexTests: XCTestCase {
    func testSettingsPanes() {
        XCTAssertEqual(SystemIndex.paneMatches("bluetooth").first?.0.name, "Bluetooth")
        XCTAssertEqual(SystemIndex.paneMatches("wifi").first?.0.name, "Wi-Fi")
        XCTAssertEqual(SystemIndex.paneMatches("dark mode").first?.0.name, "Appearance")
        XCTAssertEqual(SystemIndex.paneMatches("full disk access").first?.0.name, "Privacy & Security")
        XCTAssertEqual(SystemIndex.paneMatches("display settings").first?.0.name, "Displays")
        XCTAssertTrue(SystemIndex.paneMatches("lasagna recipe").isEmpty)
    }

    func testActions() {
        XCTAssertEqual(SystemIndex.actionMatches("lock").first?.0.name, "Lock Screen")
        XCTAssertEqual(SystemIndex.actionMatches("empty trash").first?.0.name, "Empty Trash")
        XCTAssertTrue(SystemIndex.actionMatches("re").isEmpty)
    }
}

@MainActor
final class MergeOrderTests: XCTestCase {
    private func entry(_ path: String) -> FSEntry {
        FSEntry(url: URL(fileURLWithPath: path), name: (path as NSString).lastPathComponent, isDirectory: false, isPackage: path.hasSuffix(".app"),
                size: 1, modified: Date(), created: Date(), kind: "x")
    }

    func testStrongAppBeatsFilesWeakAppAfter() {
        let claude = SearchResult(entry: entry("/Applications/Claude.app"), score: 0.95, prior: 0.95, sources: [.app])
        let weak = SearchResult(entry: entry("/Applications/Clock.app"), score: 0.35, prior: 0.35, sources: [.app])
        let file = SearchResult(entry: entry("/Users/x/CLAUDE.md"), score: 0.9, prior: 0.9, sources: [.walk])
        let merged = SearchController.merge(apps: [claude, weak], files: [file])
        XCTAssertEqual(merged.map(\.entry.name), ["Claude.app", "CLAUDE.md", "Clock.app"])
    }

    func testDedupesByIdentity() {
        let a = SearchResult(entry: entry("/Applications/Claude.app"), score: 0.95, prior: 0.95, sources: [.app])
        let same = SearchResult(entry: entry("/Applications/Claude.app"), score: 0.5, prior: 0.5, sources: [.walk])
        XCTAssertEqual(SearchController.merge(apps: [a], files: [same]).count, 1)
    }
}

final class WebIndexTests: XCTestCase {
    private func site(_ host: String, _ title: String, visits: Int = 50, bookmarked: Bool = false) -> WebIndex.Site {
        WebIndex.Site(url: URL(string: "https://\(host)/")!, host: host, title: title, visits: visits, lastVisit: Date(), bookmarked: bookmarked)
    }
    private lazy var index = WebIndex(sites: [site("youtube.com", "YouTube", visits: 169), site("docs.google.com", "Google Docs", visits: 40),
                                             site("news.ycombinator.com", "Hacker News", visits: 30), site("claude.ai", "Claude", visits: 200)],
                                      pages: [WebIndex.Page(url: URL(string: "https://www.youtube.com/results?search_query=vice+documentary")!, host: "youtube.com",
                                                            title: "vice documentary - YouTube", visits: 8)])

    func testSiteNameIsAStrongHit() {
        let hits = index.matches("youtube")
        XCTAssertEqual(hits.first?.name, "youtube.com")
        XCTAssertGreaterThanOrEqual(hits.first!.score, 0.9)          // goes above files, like Spotlight's Websites
        XCTAssertEqual(index.matches("YouTube.com").first?.name, "youtube.com")
        XCTAssertEqual(index.matches("https://www.youtube.com").first?.name, "youtube.com")
    }

    func testPrefixAndSubdomain() {
        XCTAssertEqual(index.matches("yout").first?.name, "youtube.com")
        XCTAssertEqual(index.matches("docs").first?.name, "docs.google.com")
        XCTAssertEqual(index.matches("hacker news").first?.name, "news.ycombinator.com")   // bookmark/page title
        XCTAssertTrue(index.matches("zz").isEmpty)
        XCTAssertTrue(index.matches("resume").isEmpty)
    }

    func testPageTitles() {
        let hits = index.matches("vice documentary")
        XCTAssertEqual(hits.first?.name, "vice documentary - YouTube")
        XCTAssertLessThan(hits.first!.score, 0.9)                     // pages rank after files
    }

    func testHostNormalisation() {
        XCTAssertEqual(WebIndex.host(of: URL(string: "https://www.YouTube.com/watch?v=1")!), "youtube.com")
        XCTAssertNil(WebIndex.host(of: URL(string: "http://localhost:3000/")!))
        XCTAssertNil(WebIndex.host(of: URL(string: "file:///Users/x")!))
        XCTAssertEqual(WebIndex.cleanTitle("(66) YouTube"), "YouTube")
        XCTAssertEqual(WebIndex.siteLabel("qwen-flash speed - Google Search"), "Google Search")
        XCTAssertEqual(WebIndex.siteLabel("(2) cats - YouTube"), "YouTube")
        XCTAssertEqual(WebIndex.siteLabel("Claude"), "Claude")
    }
}
