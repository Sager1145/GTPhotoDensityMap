//
//  PhotoCluster.swift
//  PhotoDensityMap
//
//  Created with Claude
//

import Foundation
import CoreLocation
import MapKit

// MARK: - Photo Location

struct PhotoLocation: Identifiable {
    let id: String // PHAsset localIdentifier
    let coordinate: CLLocationCoordinate2D
    let creationDate: Date?
    
    init(id: String, coordinate: CLLocationCoordinate2D, creationDate: Date? = nil) {
        self.id = id
        self.coordinate = coordinate
        self.creationDate = creationDate
    }
}
