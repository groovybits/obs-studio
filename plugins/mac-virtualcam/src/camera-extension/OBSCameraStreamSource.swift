//
//  OBSCameraStreamSource.swift
//  camera-extension
//
//  Created by Sebastian Beckmann on 2022-09-30.
//  Changed by Patrick Heyer on 2022-10-16.
//  Modified to support multiple formats by <your name/assistant>.
//

import CoreMediaIO
import Foundation
import os.log

class OBSCameraStreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    let device: CMIOExtensionDevice

    /// All formats supported by this stream
    private let _streamFormats: [CMIOExtensionStreamFormat]

    /// Index of the currently active format in _streamFormats
    var activeFormatIndex: Int = 0 {
	didSet {
	    if activeFormatIndex < 0 || activeFormatIndex >= _streamFormats.count {
		os_log(.error, "Invalid source format index %d", activeFormatIndex)
	    }
	}
    }

    init(localizedName: String,
	 streamID: UUID,
	 streamFormats: [CMIOExtensionStreamFormat],
	 device: CMIOExtensionDevice)
    {
	self.device = device
	self._streamFormats = streamFormats
	super.init()
	// Create the underlying CMIOExtensionStream
	self.stream = CMIOExtensionStream(
	    localizedName: localizedName,
	    streamID: streamID,
	    direction: .source,
	    clockType: .hostTime,
	    source: self
	)
    }

    /// Expose the list of possible formats
    var formats: [CMIOExtensionStreamFormat] {
	return _streamFormats
    }

    /// Which stream properties do we support?
    var availableProperties: Set<CMIOExtensionProperty> {
	return [.streamActiveFormatIndex, .streamFrameDuration]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
	-> CMIOExtensionStreamProperties
    {
	let streamProps = CMIOExtensionStreamProperties(dictionary: [:])
	for prop in properties {
	    switch prop {
	    case .streamActiveFormatIndex:
		streamProps.activeFormatIndex = activeFormatIndex

	    case .streamFrameDuration:
		// Use global OBSCameraFrameRate
		let frameDuration = CMTime(value: 1, timescale: Int32(OBSCameraFrameRate))
		streamProps.frameDuration = frameDuration

	    default:
		break
	    }
	}
	return streamProps
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
	// If the client wants to change the active format index, do so.
	if let newIndex = streamProperties.activeFormatIndex {
	    if newIndex >= 0, newIndex < _streamFormats.count {
		if newIndex != activeFormatIndex {
		    os_log(.info, "Source stream: changing activeFormatIndex to %d", newIndex)
		    activeFormatIndex = newIndex

		    // Update the device to switch the resolution
		    if let deviceSource = device.source as? OBSCameraDeviceSource {
			deviceSource.setActiveFormat(newIndex)
		    }
		}
	    } else {
		os_log(.error, "Requested out-of-range format index for source: %d", newIndex)
	    }
	}
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
	// Optionally, we could check entitlements, etc. For now, allow all.
	return true
    }

    func startStream() throws {
	guard let deviceSource = device.source as? OBSCameraDeviceSource else {
	    fatalError("Unexpected device source in startStream()")
	}
	deviceSource.startStreaming()
    }

    func stopStream() throws {
	guard let deviceSource = device.source as? OBSCameraDeviceSource else {
	    fatalError("Unexpected device source in stopStream()")
	}
	deviceSource.stopStreaming()
    }
}
