import Foundation

/// Read-only app resources. Each library installs its own ordinary, editable package.
enum StarterScreens {
    struct Template { let id: String; let artifact: ScreenArtifact }
    static let ids = ["starter-weather", "starter-nasa"]
    @MainActor static func templates() throws -> [Template] {
#if SWIFT_PACKAGE
        let bundle = Bundle.module
#else
        let bundle = Bundle.main
#endif
        return try zip(ids, ["weather", "nasa"]).map { id, name in
            guard let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "StarterScreens") else {
                throw DeviceError.message("The starter screens could not be opened.")
            }
            let artifact = try JSONDecoder().decode(ScreenArtifact.self, from: Data(contentsOf: url))
            try ScreenLibrary.validate(artifact)
            return Template(id: id, artifact: artifact)
        }
    }
}
