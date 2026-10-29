#if os(iOS)
/// Home Assistant keeps its own payload parser while sharing the local camera surface.
typealias HomeAssistantQRScanner = ConnectionQRScanner
#endif
