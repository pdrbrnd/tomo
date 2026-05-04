import Foundation
import os

nonisolated let libraryLogger = Logger(subsystem: "com.pdrbrnd.tomo", category: "library")
nonisolated let indexLogger = Logger(subsystem: "com.pdrbrnd.tomo", category: "index")
nonisolated let metadataLogger = Logger(subsystem: "com.pdrbrnd.tomo", category: "metadata")
nonisolated let classifierLogger = Logger(subsystem: "com.pdrbrnd.tomo", category: "classifier")
nonisolated let conversionLogger = Logger(subsystem: "com.pdrbrnd.tomo", category: "conversion")
nonisolated let deliveryLogger = Logger(subsystem: "com.pdrbrnd.tomo", category: "delivery")
