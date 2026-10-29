import XCTest
@testable import ScreenpunkApple
final class HomeAssistantQRPayloadTests: XCTestCase {
    func testConnectionAndRawToken() {
        let parsed = HomeAssistantQRPayload.parse(#"{"url":"http://homeassistant.local:8123","token":"abc.def.ghi","serviceCalls":["ignored"]}"#)
        XCTAssertEqual(parsed?.origin, "http://homeassistant.local:8123")
        XCTAssertEqual(parsed?.token, "abc.def.ghi")
        XCTAssertNil(HomeAssistantQRPayload.parse("abc.def.ghi")?.origin)
        XCTAssertEqual(HomeAssistantQRPayload.parse("abc.def.ghi")?.token, "abc.def.ghi")
    }
    func testRejectUnsafeOrUnrecognizedPayloads() {
        for text in ["https://example.com", "", #"{"origin":"https://user:secret@example.com","token":"abc"}"#, #"{"origin":"javascript:bad","token":"abc"}"#, #"{"origin":"https://example.com?token=secret","token":"abc"}"#, #"{"origin":"https://example.com","token":"a b"}"#] {
            XCTAssertNil(HomeAssistantQRPayload.parse(text))
        }
    }
}
