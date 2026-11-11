import Foundation

/// Read-only app resources. Each library installs its own ordinary, editable package.
enum StarterScreens {
    struct Template { let id: String; let artifact: ScreenArtifact }
    static let ids = ["starter-weather", "starter-nasa"]
    static func bundledArtifact(named name: String) throws -> ScreenArtifact {
#if SWIFT_PACKAGE
        let bundle = Bundle.module
#else
        let bundle = Bundle.main
#endif
        guard let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "StarterScreens") else {
            throw DeviceError.message("The starter screens could not be opened.")
        }
        return try JSONDecoder().decode(ScreenArtifact.self, from: Data(contentsOf: url))
    }

    @MainActor static func templates() throws -> [Template] {
        let artifacts = [try StarterWeather.defaultArtifact(), try bundledArtifact(named: "nasa")]
        return try zip(ids, artifacts).map { id, artifact in
            try ScreenLibrary.validate(artifact)
            return Template(id: id, artifact: artifact)
        }
    }
}
