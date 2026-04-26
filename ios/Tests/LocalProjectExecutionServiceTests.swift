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

    func testUnsupportedPyprojectDependenciesAllowsBundledPackages() {
        let raw = """
        [project]
        dependencies = [
          "requests>=2.32.0",
          "click",
          "httpx"
        ]
        """

        XCTAssertEqual(LocalProjectExecutionService.unsupportedPyprojectDependencies(from: raw), [])
    }

    func testUnsupportedPyprojectDependenciesFlagsNonBundledPackages() {
        let raw = """
        [project]
        dependencies = [
          "numpy>=2.0",
          "pandas"
        ]

        [dependency-groups]
        dev = [
          "pytest",
          "aiohttp"
        ]
        """

        XCTAssertEqual(
            LocalProjectExecutionService.unsupportedPyprojectDependencies(from: raw),
            ["numpy", "pandas", "aiohttp"]
        )
    }

    func testUnsupportedPyprojectDependenciesSupportsPoetrySections() {
        let raw = """
        [tool.poetry.dependencies]
        python = "^3.11"
        requests = "^2.32.0"
        lxml = "^5.3.0"
        """

        XCTAssertEqual(
            LocalProjectExecutionService.unsupportedPyprojectDependencies(from: raw),
            ["lxml"]
        )
    }

    func testIsSyntaxFailureRecognizesIndentationError() {
        let output = """
        *** Error compiling '/tmp/crawler.py'...
        Sorry: IndentationError: unexpected indent (crawler.py, line 12)
        """

        XCTAssertTrue(LocalProjectExecutionService.isSyntaxFailure(output))
    }

    func testIsSyntaxFailureRecognizesSyntaxError() {
        let output = """
        Traceback (most recent call last):
          File "/tmp/main.py", line 7
            if True print("oops")
                    ^^^^^
        SyntaxError: invalid syntax
        """

        XCTAssertTrue(LocalProjectExecutionService.isSyntaxFailure(output))
    }
}
