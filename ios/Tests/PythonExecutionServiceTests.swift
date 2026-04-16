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

    func testRunPythonSequentialExecutionsRemainStable() async throws {
        let service = PythonExecutionService()

        let first = try await service.runPython(code: "print('first run')")
        let second = try await service.runPython(code: "print('second run')")

        XCTAssertEqual(first.exitCode, 0)
        XCTAssertEqual(second.exitCode, 0)
        XCTAssertEqual(first.output, "first run")
        XCTAssertEqual(second.output, "second run")
    }

    func testRunPythonSupportsElifBranch() async throws {
        let service = PythonExecutionService()
        let code = """
        x = 3
        if x > 5:
            print("big")
        elif x > 2:
            print("middle")
        else:
            print("small")
        """

        let result = try await service.runPython(code: code)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.output, "middle")
    }

    func testRunPythonSupportsBreakAndContinueInLoop() async throws {
        let service = PythonExecutionService()
        let code = """
        total = 0
        for i in range(1, 8):
            if i == 2:
                continue
            if i == 6:
                break
            total = total + i
        print(total)
        """

        let result = try await service.runPython(code: code)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.output, "13")
    }

    func testRunPythonSupportsNonFourSpaceIndentation() async throws {
        let service = PythonExecutionService()
        let code = """
        n = 1
        if n == 1:
          print("ok")
        """

        let result = try await service.runPython(code: code)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.output, "ok")
    }

    func testRunPythonSupportsTryExcept() async throws {
        let service = PythonExecutionService()
        let code = """
        try:
            print(1/0)
        except:
            print("fallback")
        print("done")
        """

        let result = try await service.runPython(code: code)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.output, "fallback\ndone")
    }

    func testRunPythonSupportsDictAndSubscript() async throws {
        let service = PythonExecutionService()
        let code = """
        data = {"name": "IEXA", "n": 2}
        print(data["name"])
        print(data["n"])
        """

        let result = try await service.runPython(code: code)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.output, "IEXA\n2")
    }

    func testRunPythonSupportsListAppendAndNegativeIndex() async throws {
        let service = PythonExecutionService()
        let code = """
        nums = []
        nums.append(3)
        nums.append(5)
        print(nums[-1])
        """

        let result = try await service.runPython(code: code)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.output, "5")
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
