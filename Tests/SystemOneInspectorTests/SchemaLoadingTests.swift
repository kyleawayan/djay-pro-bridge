import Foundation
import XCTest
import SystemOneProbeSupport
@testable import SystemOneInspector

final class SchemaLoadingTests: XCTestCase {
    func testDelayedSchemaBlocksConnectionAndCaptureUntilCompletion() async {
        await MainActor.run {
            var complete: ((Result<ProtocolCatalog, Error>) -> Void)?
            let model = InspectorModel(schemaLoader: { complete = $0 })
            XCTAssertFalse(model.canConnect)
            XCTAssertTrue(model.busy)
            let phase = model.phase
            model.connect()
            model.loadCapture(URL(fileURLWithPath: "/nonexistent/synthetic.ndjson"))
            XCTAssertEqual(model.phase, phase)
            XCTAssertFalse(model.connected)
            complete?(.failure(CatalogError.notFound))
            XCTAssertTrue(model.canConnect)
            XCTAssertFalse(model.busy)
            XCTAssertTrue(model.schemaStatus.contains("numeric decoding"))
        }
    }
}
