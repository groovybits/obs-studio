//
//  OBSCameraStreamSink.swift
//  camera-extension
//
//  Created by Sebastian Beckmann on 2022-09-30.
//  Changed by Patrick Heyer on 2022-10-16.
//  Modified to support multiple formats by <your name/assistant>.
//

import CoreMediaIO
import Foundation
import os.log

class OBSCameraStreamSink: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    let device: CMIOExtensionDevice

    /// All formats supported
    private let _streamFormats: [CMIOExtensionStreamFormat]

    /// Index of the currently active format
    var activeFormatIndex: Int = 0 {
	didSet {
	    if activeFormatIndex < 0 || activeFormatIndex >= _streamFormats.count {
		os_log(.error, "Invalid sink format index %d", activeFormatIndex)
	    }
	}
    }

    var client: CMIOExtensionClient?

    init(localizedName: String,
	 streamID: UUID,
	 streamFormats: [CMIOExtensionStreamFormat],
	 device: CMIOExtensionDevice)
    {
	self.device = device
	self._streamFormats = streamFormats
	super.init()
	// Create the sink stream
	self.stream = CMIOExtensionStream(localizedName: localizedName,
					  streamID: streamID,
					  direction: .sink,
					  clockType: .hostTime,
					  source: self)
    }

    var formats: [CMIOExtensionStreamFormat] {
	return _streamFormats
    }

    var availableProperties: Set<CMIOExtensionProperty> {
	return [
	    .streamActiveFormatIndex,
	    .streamFrameDuration,
	    .streamSinkBufferQueueSize,
	    .streamSinkBuffersRequiredForStartup,
	    // You can add .streamSinkBufferUnderrunCount or .streamSinkEndOfData if needed
	]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
	-> CMIOExtensionStreamProperties
    {
	let props = CMIOExtensionStreamProperties(dictionary: [:])
	for prop in properties {
	    switch prop {
	    case .streamActiveFormatIndex:
		props.activeFormatIndex = activeFormatIndex

	    case .streamFrameDuration:
		let frameDuration = CMTime(value: 1, timescale: Int32(OBSCameraFrameRate))
		props.frameDuration = frameDuration

	    case .streamSinkBufferQueueSize:
		// A small queue size is typically fine
		props.sinkBufferQueueSize = 30

	    case .streamSinkBuffersRequiredForStartup:
		// We need at least 1 buffer to begin
		props.sinkBuffersRequiredForStartup = 1

	    default:
		break
	    }
	}
	return props
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
	// If the client tries to set a new active format index
	if let newIndex = streamProperties.activeFormatIndex {
	    if newIndex >= 0, newIndex < _streamFormats.count {
		if newIndex != activeFormatIndex {
		    os_log(.info, "Sink stream: changing activeFormatIndex to %d", newIndex)
		    activeFormatIndex = newIndex
		    // Notify device
		    if let deviceSource = device.source as? OBSCameraDeviceSource {
			deviceSource.setActiveFormat(newIndex)
		    }
		}
	    } else {
		os_log(.error, "Out-of-range format index for sink: %d", newIndex)
	    }
	}
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
	self.client = client
	return true
    }

    func startStream() throws {
	guard let deviceSource = device.source as? OBSCameraDeviceSource else {
	    fatalError("Unexpected device source in sink startStream()")
	}
	if let cl = client {
	    deviceSource.startStreamingSink(client: cl)
	}
    }

    func stopStream() throws {
	guard let deviceSource = device.source as? OBSCameraDeviceSource else {
	    fatalError("Unexpected device source in sink stopStream()")
	}
	deviceSource.stopStreamingSink()
    }
}
