import XCTest
@testable import ScreenpunkCore

final class AuthoringPackageDependenciesTests: XCTestCase {
    private func html(_ source: String) -> AuthoringScreenFile { .init(path: "index.html", content: source) }
    func testConcreteCosmoOmissionAndNestedCSSImportAreRejected() throws {
        XCTAssertThrowsError(try AuthoringPackageDependencies.validate(files: [html("<img src='cosmo.svg'>")]))
        XCTAssertThrowsError(try AuthoringPackageDependencies.validate(files: [html("<link href='css/main.css'>"), .init(path: "css/main.css", content: "@import 'missing.css';")]))
        XCTAssertThrowsError(try AuthoringPackageDependencies.validate(files: [html("<style>body{background:url(cosmo.svg)}</style>")]))
        XCTAssertThrowsError(try AuthoringPackageDependencies.validate(files: [html("<img srcset='one.svg 1x, missing.svg 2x'>"), .init(path: "one.svg", content: "<svg/>")]))
    }
    func testSVGPresentationResourcesAreChecked() throws {
        XCTAssertThrowsError(try AuthoringPackageDependencies.validate(files: [.init(path: "paint.svg", content: "<svg><rect fill=\"url(defs.svg#gradient)\"/></svg>")]))
    }
    func testScriptStringsDoNotBecomeStaticHTMLDependencies() throws {
        XCTAssertNoThrow(try AuthoringPackageDependencies.validate(files: [html("<script>const href='details'; const s=\"<img src='runtime.svg'>\";</script>")]))
        XCTAssertThrowsError(try AuthoringPackageDependencies.validate(files: [html("<script src='missing.js'></script>")]))
    }
    func testDataURLSrcsetDoesNotHideAnotherMissingCandidate() throws {
        XCTAssertThrowsError(try AuthoringPackageDependencies.validate(files: [html("<img srcset='data:image/png;base64,AAAA 1x, missing.svg 2x'>")]))
        XCTAssertThrowsError(try AuthoringPackageDependencies.validate(files: [html("<img srcset='data:image/png;base64,AAAA, missing.svg 2x'>")]))
    }
    func testCanonicalRelativeQueryFragmentsEntitiesAndEmbeddedData() throws {
        let files: [AuthoringScreenFile] = [html("<link href='css/main.css?v=1&amp;x=2'><img src='&#x63;osmo.svg#symbol'><a href='#top'>Top</a>"),
            .init(path: "css/main.css", content: "@import './other.css'; body{background:url('../cosmo.svg#image')}"),
            .init(path: "css/other.css", content: "/* url(ignored.svg) */ a{background:url(data:image/png;base64,AAAA)}"), .init(path: "cosmo.svg", content: "<svg><image href='data:image/png;base64,AAAA'/></svg>")]
        XCTAssertNoThrow(try AuthoringPackageDependencies.validate(files: files))
        XCTAssertNoThrow(try AuthoringPackageDependencies.validate(files: [html("<!-- <img src='ignored.svg'> --><a href='https://example.test/page'>External</a>")]))
    }
    func testTraversalEncodingAndBaseRewritingFailClosed() throws {
        for value in ["../escape.svg", "%2e%2e/escape.svg", "image%252e.svg", "dir%5cimage.svg", "screenpunk://package/missing.svg", "SCREENPUNK://PACKAGE/missing.svg"] {
            XCTAssertThrowsError(try AuthoringPackageDependencies.validate(files: [html("<img src='\(value)'>")]), value)
        }
        XCTAssertThrowsError(try AuthoringPackageDependencies.validate(files: [html("<base href='https://example.test/'><img src='hidden.svg'>")]))
    }
    func testManifestSizesAndHashesAreCheckedAgainstCompletedPackage() throws {
        let content = "<html></html>"
        var manifest = DashboardManifest(schemaVersion: 1, dashboardId: "fixture", name: "Fixture", revision: "revision", entrypoint: "index.html", sdkVersion: "1",
            target: .init(profileId: "profile", width: 1024, height: 768, scale: 1, orientation: "landscape"), connections: [],
            files: [.init(path: "index.html", bytes: content.utf8.count, sha256: AuthoringContract.contentDigest(Data(content.utf8)))])
        func package() throws -> [AuthoringScreenFile] { [html(content), .init(path: "manifest.json", content: String(decoding: try JSONEncoder().encode(manifest), as: UTF8.self))] }
        XCTAssertNoThrow(try AuthoringPackageDependencies.validateManifest(files: package()))
        manifest.files[0].sha256 = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try AuthoringPackageDependencies.validateManifest(files: package()))
        manifest.files[0].bytes = Int.max
        XCTAssertThrowsError(try AuthoringPackageDependencies.validateManifest(files: package()))
        manifest.files[0].bytes = -1
        XCTAssertThrowsError(try AuthoringPackageDependencies.validateManifest(files: package()))
    }

    func testQuotedTagsAttributeKindsAndPackageURLFormsRemainCompatible() throws {
        let source = """
        <!DOCTYPE html><HTML><BODY>
        <IMG title="2 > 1" SRC = cosmo.svg>
        <OBJECT DATA='/cosmo.svg'></OBJECT><VIDEO POSTER="cosmo.svg"></VIDEO>
        <svg><use XLINK:HREF="SCREENPUNK://PACKAGE/cosmo.svg#symbol"/></svg>
        <script SRC='app.js'>const markup="<img src='runtime.svg'>";</ScRiPt>
        <a href='//example.test/page'>External</a>
        </BODY></HTML>
        """
        XCTAssertNoThrow(try AuthoringPackageDependencies.validate(files: [html(source), .init(path:"cosmo.svg",content:"<svg/>"), .init(path:"app.js",content:"const ready=true;")]))
        XCTAssertThrowsError(try AuthoringPackageDependencies.validate(files: [html("<img title='2 > 1' src='missing.svg'>")]))
    }

    func testCSSCommentsStringsImportsAndSVGPaintFormsRemainCompatible() throws {
        let source = """
        <style>/* url(ignored.svg) */
        @IMPORT /* ordinary comment */ URL('css/main.css') screen;
        .tile{content:"url(text-only.svg)";background:uRl( 'cosmo.svg?version=1#image' )}
        </style>
        <svg><rect style="fill:url('cosmo.svg#paint')" stroke="url(#local)" filter="url(cosmo.svg#filter)" mask="url(cosmo.svg#mask)" clip-path="url(cosmo.svg#clip)" marker-start="url(cosmo.svg#start)" marker-mid="url(cosmo.svg#mid)" marker-end="url(cosmo.svg#end)"/></svg>
        """
        let files = [html(source), .init(path:"cosmo.svg",content:"<?xml version='1.0'?><svg><!-- ordinary comment --></svg>"), .init(path:"css/main.css",content:"@import './other.css'; body{background:url('../cosmo.svg')}"), .init(path:"css/other.css",content:"a{background:url(data:image/png;base64,AAAA)}")]
        XCTAssertNoThrow(try AuthoringPackageDependencies.validate(files: files))
        XCTAssertThrowsError(try AuthoringPackageDependencies.validate(files: [html("<style>body{content:'text';background:url('missing.svg')}</style>")]))
    }

    func testSrcsetDescriptorsAndEntityDecodingCheckEachOrdinaryCandidate() throws {
        let source = """
        <img src='&#X63;&#111;smo.svg?one=1&amp;two=2'>
        <img srcset='data:image/png;base64,AAAA 1x, cosmo.svg 2x'>
        <img srcset='data:image/png;base64,AAAA, /cosmo.svg 640w'>
        <img srcset='cosmo.svg .5x, cosmo.svg 1.5x'>
        """
        XCTAssertNoThrow(try AuthoringPackageDependencies.validate(files: [html(source), .init(path:"cosmo.svg",content:"<svg/>")]))
        XCTAssertThrowsError(try AuthoringPackageDependencies.validate(files: [html("<img srcset='cosmo.svg 1x, missing.svg 2x'>"), .init(path:"cosmo.svg",content:"<svg/>")]))
        XCTAssertThrowsError(try AuthoringPackageDependencies.validate(files: [html("<img srcset='cosmo.svg not-a-descriptor'>"), .init(path:"cosmo.svg",content:"<svg/>")]))
    }

    func testMalformedStaticSyntaxFailsExplicitly() throws {
        let malformed = ["<!-- unfinished comment", "<img src='cosmo.svg>", "<img src='cosmo.svg'", "<script>const message='ordinary';", "<style>body{color:blue}", "<script.invalid>text</script.invalid>", "<style>/* unfinished comment</style>", "<style>a{background:url('cosmo.svg')}</style" , "<style>a{background:url('cosmo.svg'}</style>", "<style>@import ordinary.css;</style>"]
        for source in malformed {
            XCTAssertThrowsError(try AuthoringPackageDependencies.validate(files: [html(source), .init(path:"cosmo.svg",content:"<svg/>")]),source)
        }
        XCTAssertThrowsError(try AuthoringPackageDependencies.validate(files:[.init(path:"style.css",content:"a{background:url(cosmo.svg")]))
    }

    func testAdmissionCountsSerializedEscapesBeforeScanning() throws {
        let files = [html("<img title='quote: \" newline:\n Unicode:😀' src='cosmo.svg'>"), .init(path:"cosmo.svg",content:"<svg/>")]
        let serializedBytes = try AuthoringContract.encodedCanonical(files).count
        XCTAssertNoThrow(try AuthoringPackageDependencies.validate(files:files,workLimit:4096,byteLimit:serializedBytes))
        XCTAssertThrowsError(try AuthoringPackageDependencies.validate(files:files,workLimit:4096,byteLimit:serializedBytes - 1))
        let tooMany = (0..<21).map { AuthoringScreenFile(path:"file-\($0).txt",content:"ordinary text") }
        XCTAssertThrowsError(try AuthoringPackageDependencies.validate(files:tooMany))
    }

    func testSmallWorkBudgetFailsClosedOnAnOrdinaryValidPackage() throws {
        let files = [html("<img src='cosmo.svg'>"), .init(path:"cosmo.svg",content:"<svg/>")]
        XCTAssertNoThrow(try AuthoringPackageDependencies.validate(files:files,workLimit:4096))
        XCTAssertThrowsError(try AuthoringPackageDependencies.validate(files:files,workLimit:8)) { error in
            XCTAssertTrue(String(describing:error).contains("work limit"))
        }
    }

    func testSelfClosingHTMLRawTextFailsClosedWhileSVGEmptyElementsRemainValid() throws {
        XCTAssertThrowsError(try AuthoringPackageDependencies.validate(files:[html("<style/>body{background:url(missing.svg)}</style>")]))
        XCTAssertThrowsError(try AuthoringPackageDependencies.validate(files:[html("<script/>const message='ordinary';</script>")]))
        XCTAssertNoThrow(try AuthoringPackageDependencies.validate(files:[.init(path:"drawing.svg",content:"<svg><style/><script href='app.js'/></svg>"), .init(path:"app.js",content:"const ready=true;")]))
        XCTAssertThrowsError(try AuthoringPackageDependencies.validate(files:[.init(path:"drawing.svg",content:"<svg><style/><script href='missing.js'/></svg>")]))
    }

    func testPinnedReaderRejectsTraversalDirectoriesSymlinksAndWrongHashes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("screenpunk-pinned-read-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = Data("exact raw bytes\r\n".utf8)
        try data.write(to: root.appendingPathComponent("asset.svg"))
        let hash = AuthoringContract.contentDigest(data)
        XCTAssertEqual(try AuthoringPinnedPackage.read(directory: root, path: "asset.svg", byteLength: data.count, digest: hash), data)
        XCTAssertThrowsError(try AuthoringPinnedPackage.read(directory: root, path: "../asset.svg", byteLength: data.count, digest: hash))
        XCTAssertThrowsError(try AuthoringPinnedPackage.read(directory: root, path: "asset.svg", byteLength: data.count + 1, digest: hash))
        XCTAssertThrowsError(try AuthoringPinnedPackage.read(directory: root, path: "asset.svg", byteLength: data.count, digest: String(repeating: "0", count: 64)))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.svg"), withDestinationURL: root.appendingPathComponent("asset.svg"))
        XCTAssertThrowsError(try AuthoringPinnedPackage.read(directory: root, path: "link.svg", byteLength: data.count, digest: hash))
        let directory = root.appendingPathComponent("dir.svg"); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertThrowsError(try AuthoringPinnedPackage.read(directory: root, path: "dir.svg", byteLength: 0, digest: AuthoringContract.contentDigest(Data())))
    }
}
