import CloudKit
import CoreLocation
import Foundation

/// A point on Earth as a value: latitude and longitude in degrees, and altitude in meters when it
/// is known.
public struct Coordinate: Hashable, Codable, Sendable {
    public var latitude: Double
    public var longitude: Double
    /// Meters above sea level, or `nil` when unknown.
    public var altitude: Double?

    public init(latitude: Double, longitude: Double, altitude: Double? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
    }

    /// The coordinate of `location`, with its altitude when that is valid.
    public init(_ location: CLLocation) {
        latitude = location.coordinate.latitude
        longitude = location.coordinate.longitude
        altitude = location.verticalAccuracy >= 0 ? location.altitude : nil
    }

    /// A `CLLocation` at this coordinate, timestamped now.
    public var location: CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            altitude: altitude ?? 0, horizontalAccuracy: 0, verticalAccuracy: altitude == nil ? -1 : 0,
            timestamp: Date()
        )
    }
}

/// The storage behind a `@Location` property: the `CLLocation` CloudKit stores.
///
/// The property reads it as a `Coordinate`. `$name` reads and sets the `CLLocation` itself, keeping
/// its timestamp, accuracy, course, and speed. How accurate the course and speed are is not kept.
public struct LocationField: @unchecked Sendable {
    /// The type CloudKit stores, so generated code needn't import CoreLocation.
    public typealias Stored = CLLocation

    /// The stored location, with every detail it was saved with.
    public var location: CLLocation?

    /// A location set in code, at `coordinate`.
    public init(_ coordinate: Coordinate?) {
        location = coordinate?.location
    }

    /// A location read from storage, with every detail it was saved with.
    public init(saved location: CLLocation?) {
        self.location = location
    }

    /// The location as a value. Setting it stores a new `CLLocation` at that coordinate.
    public var coordinate: Coordinate? {
        get { location.map(Coordinate.init) }
        set { location = newValue?.location }
    }
}

/// Two locations are equal when they are at the same coordinate at the same time.
extension LocationField: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.coordinate == rhs.coordinate && lhs.location?.timestamp == rhs.location?.timestamp
    }
}

extension LocationField: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(coordinate)
    }
}
