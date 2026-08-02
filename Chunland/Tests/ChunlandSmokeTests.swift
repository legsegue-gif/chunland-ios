import XCTest

// 最小冒烟测试 —— 让 ChunlandTests target 的源目录非空（否则空目录不被 git 跟踪、
// CI checkout 缺目录致 xcodegen「missing source directory」）。后续可在此补真实单测。
final class ChunlandSmokeTests: XCTestCase {
    func testPlaceholder() {
        XCTAssertEqual(1 + 1, 2)
    }
}
