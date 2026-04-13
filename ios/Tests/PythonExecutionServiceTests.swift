import XCTest
@testable import ChatApp

final class PythonExecutionServiceTests: XCTestCase {
    override func tearDown() {
        URLProtocolPythonStub.handler = nil
        super.tearDown()
    }

    func testRunPythonReturnsOutputAndExitCode() async throws {
        URLProtocolPythonStub.handler = { request in
            let body = """
            {
              "run": {
                "stdout": "hello\\n",
                "stderr": "",
                "output": "hello\\n",
                "code": 0
              }
            }
            """
            let data = try XCTUnwrap(body.data(using: .utf8))
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )
            )
            return (response, data)
        }

        let service = makeStubbedService()
        let result = try await service.runPython(code: "print('hello')")

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.output, "hello\n")
    }

    func testRunPythonFallsBackToSecondEndpoint() async throws {
        URLProtocolPythonStub.handler = { request in
            guard let url = request.url?.absoluteString else {
                throw URLError(.badURL)
            }

            if url.contains("first.endpoint") {
                let response = try XCTUnwrap(
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 500,
                        httpVersion: nil,
                        headerFields: nil
                    )
                )
                return (response, Data())
            }

            let body = """
            {
              "run": {
                "stdout": "ok",
                "stderr": "",
                "output": "ok",
                "code": 0
              }
            }
            """
            let data = try XCTUnwrap(body.data(using: .utf8))
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )
            )
            return (response, data)
        }

        let service = makeStubbedService(
            endpoints: [
                "https://first.endpoint/api/v2/execute",
                "https://second.endpoint/api/v2/execute"
            ]
        )
        let result = try await service.runPython(code: "print('ok')")
        XCTAssertEqual(result.output, "ok")
    }

    func testRunPythonRejectsEmptyCode() async {
        let service = makeStubbedService()

        do {
            _ = try await service.runPython(code: "   \n")
            XCTFail("Expected emptyCode error")
        } catch let error as PythonExecutionError {
            XCTAssertEqual(error, .emptyCode)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeStubbedService(endpoints: [String] = ["https://first.endpoint/api/v2/execute"]) -> PythonExecutionService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolPythonStub.self]
        let session = URLSession(configuration: configuration)
        return PythonExecutionService(session: session, executeEndpoints: endpoints)
    }
}

private final class URLProtocolPythonStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
