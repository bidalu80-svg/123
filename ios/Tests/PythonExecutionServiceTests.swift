import XCTest
@testable import ChatApp

final class PythonExecutionServiceTests: XCTestCase {
    func testRunPythonReturnsOutputAndExitCode() async throws {
        let service = PythonExecutionService()
        let result = try await service.runPython(code: "print('hello')")

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.output, "hello")
    }

    func testRunPythonSupportsForRangeAndAssignment() async throws {
        let service = PythonExecutionService()
        let code = """
        total = 0
        for i in range(1, 5):
            total = total + i
        print(total)
        """

        let result = try await service.runPython(code: code)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.output, "10")
    }

    func testRunPythonReportsRuntimeErrorByExitCode() async throws {
        let service = PythonExecutionService()
        let result = try await service.runPython(code: "print(1/0)")

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.output.contains("除数不能为 0"))
    }

    func testRunPythonSupportsInputViaStdin() async throws {
        let service = PythonExecutionService()
        let code = """
        name = input("请输入名字：")
        print(name)
        """
        let result = try await service.runPython(code: code, stdin: "IEXA\n")

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.output.contains("IEXA"))
    }

    func testRunPythonRejectsEmptyCode() async {
        let service = PythonExecutionService()

        do {
            _ = try await service.runPython(code: "   \n")
            XCTFail("Expected emptyCode error")
        } catch let error as PythonExecutionError {
            XCTAssertEqual(error, .emptyCode)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
