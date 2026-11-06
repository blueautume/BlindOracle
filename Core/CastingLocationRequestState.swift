import Foundation

/// The form owns acceptance of results independently of the location service.
/// LocationService also isolates each CLLocationManager request, so a callback
/// from an older manager cannot become a result for a replacement request.
struct CastingLocationRequestState: Equatable {
    private(set) var requestID: UUID?
    private(set) var automaticAttempted = false
    var isWaiting: Bool { requestID != nil }

    mutating func beginAutomatic(needsLocation: Bool, isSupplement: Bool,
                                 hasLocation: Bool, explicitlyCleared: Bool) -> UUID? {
        guard needsLocation, !isSupplement, !hasLocation, !explicitlyCleared,
              !automaticAttempted, !isWaiting else { return nil }
        automaticAttempted = true
        return beginManual(needsLocation: needsLocation)
    }

    mutating func beginManual(needsLocation: Bool) -> UUID? {
        guard needsLocation, !isWaiting else { return nil }
        let id = UUID()
        requestID = id
        return id
    }

    @discardableResult mutating func finish(requestID id: UUID) -> Bool {
        guard requestID == id else { return false }
        requestID = nil
        return true
    }

    mutating func cancel() { requestID = nil }
}
