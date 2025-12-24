// CameraPreview.swift (Corrected and Simplified)

import SwiftUI
import AVFoundation
import UIKit

struct CameraPreview: View {
    let image: CGImage?
    
    var body: some View {
        if let cgImage = image {
            // The image should be resizable and fill the frame it is given.
            // The container will be responsible for the correct shape.
            Image(decorative: cgImage, scale: 1.0, orientation: .up)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            // Show blue until the first frame arrives
            Color.blue
        }
    }
}
