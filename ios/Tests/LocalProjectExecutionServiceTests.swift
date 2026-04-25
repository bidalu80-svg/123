import XCTest
@testable import ChatApp

final class LocalProjectExecutionServiceTests: XCTestCase {
    func testUnsupportedRequirementsAllowsBundledPackages() {
        let raw = """
        requests==2.32.3
        pytest>=8.0
        click
        """

        XCTAssertEqual(LocalProjectExecutionService.unsupportedRequirements(from: raw), [])
    }

    func testUnsupportedRequirementsFlagsNonBundledPackages() {
        let raw = """
        numpy==2.1.0
        pandas
        -e .
        """

        XCTAssertEqual(
            LocalProjectExecutionService.unsupportedRequirements(from: raw),
            ["numpy", "pandas", "-e ."]
        )
    }
}
