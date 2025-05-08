//
//  OBSCameraDeviceSource.swift
//  camera-extension
//
//  Created by Sebastian Beckmann on 2022-09-30.
//  Changed by Patrick Heyer on 2022-10-16.
//  Modified to consolidate multi-Resolution/FPS negotiation by groovybits 2025-05-07.
//

import AppKit
import CoreMediaIO
import Foundation
import IOKit.audio
import os.log

/// A tiny struct for resolution that conforms to `Hashable`, so we can use it as a dictionary key.
fileprivate struct Resolution: Hashable {
    let width: Int32
    let height: Int32
}

/// Default fallback frame rate for placeholders and sink polling
var OBSCameraFrameRate: Double = 60

/// Helper to create exact CMTime for common fractional frame rates.
/// e.g. 59.94 => 1001/60000, 29.97 => 1001/30000, etc.
/// Otherwise it falls back to (1, Int32(fps.rounded())) for general usage.
fileprivate func fpsToCMTime(_ fps: Double) -> CMTime {
    // A small epsilon for matching
    let eps = 0.0001

    // Detect standard fractional NTSC rates:
    // 59.94 => 1001/60000
    if abs(fps - 59.94) < eps {
	return CMTime(value: 1001, timescale: 60000)
    }
    // 29.97 => 1001/30000
    if abs(fps - 29.97) < eps {
	return CMTime(value: 1001, timescale: 30000)
    }
    // 23.976 => 1001/24000
    if abs(fps - 23.976) < eps {
	return CMTime(value: 1001, timescale: 24000)
    }
    // If you have other fractional rates to handle, add them here

    // Otherwise, fallback to integer timescale approach
    let roundedFPS = Int32(fps.rounded())
    let safeTimescale = max(roundedFPS, 1)  // avoid 0 or negative timescale
    return CMTime(value: 1, timescale: safeTimescale)
}

class OBSCameraDeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!

    // Our two streams
    private var _streamSource: OBSCameraStreamSource!
    private var _streamSink: OBSCameraStreamSink!

    // Counters for how many clients are currently streaming from or to the device.
    var _streamingCounter: UInt32 = 0
    var _streamingSinkCounter: UInt32 = 0

    // Timers for placeholders and for sink consumption
    private var _placeholderTimer: DispatchSourceTimer?
    private var _consumeBufferTimer: DispatchSourceTimer?
    private let _timerQueue = DispatchQueue(
	label: "timerQueue",
	qos: .userInteractive,
	attributes: [],
	autoreleaseFrequency: .workItem,
	target: .global(qos: .userInteractive)
    )

    // Current format description used for outgoing frames
    private var _videoDescription: CMFormatDescription!
    // Pool for creating pixel buffers (placeholder frames, etc.)
    var _bufferPool: CVPixelBufferPool!
    // Aux attributes (like allocation threshold)
    var _bufferAuxAttributes: NSDictionary!

    // The placeholder image for times when sink is not sending frames
    private var _placeholderImage: NSImage!

    // Track whether the sink is actively providing frames
    var sinkStarted = false
    // Last timing info for sink frames
    var lastTimingInfo = CMSampleTimingInfo()

    // All generated format descriptions (one per resolution) for the device
    private var _supportedFormatDescriptions: [CMFormatDescription] = []
    // Currently active format index
    private var _currentFormatIndex: Int = 0

    init(localizedName: String, deviceUUID: UUID, sourceUUID: UUID, sinkUUID: UUID) {
	super.init()

	// Create the underlying device
	self.device = CMIOExtensionDevice(
	    localizedName: localizedName,
	    deviceID: deviceUUID,
	    legacyDeviceID: nil,
	    source: self
	)

	//----------------------------------------------------------------
	// 1) Define resolutions & possible fps. We group by (width, height)
	//----------------------------------------------------------------
	let inputResAndFPS: [(Int32, Int32, Double)] = [
	    (1920, 1080, 60),
	    (1920, 1080, 30),
	    (1920, 1080, 29.970030),
	    (2560, 1440, 60),
	    (2560, 1440, 30),
	    (3840, 2160, 60),
	    (3840, 2160, 30),
	    (1080, 1920, 60),
	    (1080, 1920, 30),
	    (1440, 2560, 60),
	    (1440, 2560, 30),
	    (2160, 3840, 60),
	    (2160, 3840, 30),
	    (1280, 720, 60),
	    (1280, 720, 59.94),
	    (1280, 720, 30),
	    (1280, 720, 29.970030),
	    (720, 1280, 60),
	    (1280, 720, 59.94),
	    (720, 1280, 30),
	    (1280, 720, 29.970030),
	    (720, 480, 60),
	    (720, 480, 59.94),
	    (720, 480, 30),
	    (720, 480, 29.970030),
	]

	// Dictionary: Resolution -> Set of fps (Double)
	var resolutionFPSMap: [Resolution : Set<Double>] = [:]

	for (w, h, fps) in inputResAndFPS {
	    let key = Resolution(width: w, height: h)
	    if resolutionFPSMap[key] == nil {
		resolutionFPSMap[key] = []
	    }
	    resolutionFPSMap[key]?.insert(fps)
	}

	// We'll build an array of CMIOExtensionStreamFormats from that dictionary
	var streamFormats: [CMIOExtensionStreamFormat] = []

	for (res, fpsSet) in resolutionFPSMap {
	    let (width, height) = (res.width, res.height)

	    // Sort the FPS values so we can get min/max
	    let sortedFPS = fpsSet.sorted() // ascending
	    var desc: CMFormatDescription?

	    let status = CMVideoFormatDescriptionCreate(
		allocator: kCFAllocatorDefault,
		codecType: kCVPixelFormatType_32BGRA,
		width: width,
		height: height,
		extensions: nil,
		formatDescriptionOut: &desc
	    )
	    guard status == noErr, let videoDesc = desc else {
		os_log(.error, "Failed to create CMFormatDescription for %dx%d", width, height)
		continue
	    }
	    _supportedFormatDescriptions.append(videoDesc)

	    // Build validFrameDurations using fpsToCMTime
	    var allDurations: [CMTime] = []
	    for f in sortedFPS {
		let dur = fpsToCMTime(f)
		allDurations.append(dur)
	    }

	    guard let fastest = allDurations.min(by: { $0 < $1 }),
		  let slowest = allDurations.max(by: { $0 < $1 })
	    else {
		continue
	    }

	    let streamFormat = CMIOExtensionStreamFormat(
		formatDescription: videoDesc,
		maxFrameDuration: slowest,  // largest interval => slowest fps
		minFrameDuration: fastest,  // smallest interval => fastest fps
		validFrameDurations: allDurations
	    )
	    streamFormats.append(streamFormat)
	    os_log(.info, "Created format for %dx%d with FPS set: %@", width, height, String(describing: fpsSet))
	}

	// Choose a "default" format index. For example, look for 1920×1080
	if let idx = streamFormats.firstIndex(where: {
	    let dims = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
	    return dims.width == 1920 && dims.height == 1080
	}) {
	    _currentFormatIndex = idx
	} else {
	    _currentFormatIndex = 0
	}

	// Create the source and sink with the entire formats array
	_streamSource = OBSCameraStreamSource(
	    localizedName: "OBS Camera Extension Stream Source",
	    streamID: sourceUUID,
	    streamFormats: streamFormats,
	    device: device
	)
	_streamSink = OBSCameraStreamSink(
	    localizedName: "OBS Camera Extension Stream Sink",
	    streamID: sinkUUID,
	    streamFormats: streamFormats,
	    device: device
	)

	// Add both streams to the device
	do {
	    try device.addStream(_streamSource.stream)
	    try device.addStream(_streamSink.stream)
	} catch {
	    fatalError("Failed to add streams to device: \(error.localizedDescription)")
	}

	// 2) Initialize our video description & pixel buffer pool
	if _currentFormatIndex < _supportedFormatDescriptions.count {
	    _videoDescription = _supportedFormatDescriptions[_currentFormatIndex]
	    let dims = CMVideoFormatDescriptionGetDimensions(_videoDescription)
	    let attrs: NSDictionary = [
		kCVPixelBufferWidthKey: dims.width,
		kCVPixelBufferHeightKey: dims.height,
		kCVPixelBufferPixelFormatTypeKey: _videoDescription.mediaSubType,
		kCVPixelBufferIOSurfacePropertiesKey: [:]
	    ]
	    var pool: CVPixelBufferPool?
	    let rv = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs, &pool)
	    if rv == kCVReturnSuccess, let p = pool {
		_bufferPool = p
		_bufferAuxAttributes = [kCVPixelBufferPoolAllocationThresholdKey: 5]
	    } else {
		fatalError("Failed to create pixel buffer pool for default format")
	    }
	}

	// 3) Load the placeholder image
	let placeholderURL = Bundle.main.url(forResource: "placeholder", withExtension: "png")
	if let url = placeholderURL, let img = NSImage(contentsOf: url) {
	    _placeholderImage = img
	} else {
	    fatalError("Unable to find or load placeholder.png in bundle")
	}
    }

    // MARK: - CMIOExtensionDeviceSource

    var availableProperties: Set<CMIOExtensionProperty> {
	return [.deviceTransportType, .deviceModel]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
	-> CMIOExtensionDeviceProperties
    {
	let props = CMIOExtensionDeviceProperties(dictionary: [:])
	if properties.contains(.deviceTransportType) {
	    props.transportType = kIOAudioDeviceTransportTypeVirtual
	}
	if properties.contains(.deviceModel) {
	    props.model = "OBS Camera Extension"
	}
	return props
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {
	// No device-level properties to set in this sample
    }

    // Rebuild the video format and pixel buffer pool when a new active format is selected
    func setActiveFormat(_ newIndex: Int) {
	guard newIndex >= 0 && newIndex < _supportedFormatDescriptions.count else {
	    os_log(.error, "Requested format index %d is out of range", newIndex)
	    return
	}
	if newIndex == _currentFormatIndex {
	    return
	}
	_currentFormatIndex = newIndex

	_videoDescription = _supportedFormatDescriptions[newIndex]
	let dims = CMVideoFormatDescriptionGetDimensions(_videoDescription)

	// Release old pool
	if let oldPool = _bufferPool {
	    CVPixelBufferPoolFlush(oldPool, .excessBuffers)
	}

	let attrs: NSDictionary = [
	    kCVPixelBufferWidthKey: dims.width,
	    kCVPixelBufferHeightKey: dims.height,
	    kCVPixelBufferPixelFormatTypeKey: _videoDescription.mediaSubType,
	    kCVPixelBufferIOSurfacePropertiesKey: [:]
	]
	var pool: CVPixelBufferPool?
	let rv = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs, &pool)
	guard rv == kCVReturnSuccess, let newPool = pool else {
	    os_log(.error, "Failed to create new pixel buffer pool for %dx%d", dims.width, dims.height)
	    return
	}
	_bufferPool = newPool
	_bufferAuxAttributes = [kCVPixelBufferPoolAllocationThresholdKey: 5]

	os_log(.info, "Switched active format to index %d => %dx%d", newIndex, dims.width, dims.height)

	// Also update the stream source/sink's activeFormatIndex to keep them in sync
	_streamSource.activeFormatIndex = newIndex
	_streamSink.activeFormatIndex = newIndex
    }

    // MARK: - Source Streaming

	func startStreaming() {
	    guard _bufferPool != nil else {
		return
	    }
	    _streamingCounter += 1

	    if _streamingCounter == 1 {
		// Grab the active format from the source
		let currentFormat = _streamSource.formats[_streamSource.activeFormatIndex]
		let dur = currentFormat.minFrameDuration
		let fps = Double(dur.timescale) / Double(dur.value)
		let placeholderInterval = 1.0 / fps

		_placeholderTimer = DispatchSource.makeTimerSource(flags: .strict, queue: _timerQueue)
		_placeholderTimer?.schedule(deadline: .now(),
					    repeating: placeholderInterval,
					    leeway: .seconds(0))
		_placeholderTimer?.setEventHandler {
		    [weak self] in
		    guard let self = self else { return }
		    if self.sinkStarted {
			return
		    }
		    self.sendPlaceholderFrame()
		}
		_placeholderTimer?.resume()
	    }
	}

    func stopStreaming() {
	if _streamingCounter > 1 {
	    _streamingCounter -= 1
	} else {
	    _streamingCounter = 0
	    _placeholderTimer?.cancel()
	    _placeholderTimer = nil
	}
    }

    private func sendPlaceholderFrame() {
	guard let pool = _bufferPool else { return }

	var pixelBuffer: CVPixelBuffer?
	let err = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
	    kCFAllocatorDefault,
	    pool,
	    _bufferAuxAttributes,
	    &pixelBuffer
	)
	if err == kCVReturnPoolAllocationFailed {
	    os_log(.error, "No available PixelBuffers in PixelBufferPool: \(err)")
	    return
	}
	guard let pb = pixelBuffer else {
	    return
	}

	CVPixelBufferLockBaseAddress(pb, [])
	let width = CVPixelBufferGetWidth(pb)
	let height = CVPixelBufferGetHeight(pb)
	let rowBytes = CVPixelBufferGetBytesPerRow(pb)
	guard let baseAddr = CVPixelBufferGetBaseAddress(pb) else {
	    CVPixelBufferUnlockBaseAddress(pb, [])
	    return
	}

	guard let cgCtx = CGContext(
	    data: baseAddr,
	    width: width,
	    height: height,
	    bitsPerComponent: 8,
	    bytesPerRow: rowBytes,
	    space: CGColorSpaceCreateDeviceRGB(),
	    bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
	) else {
	    CVPixelBufferUnlockBaseAddress(pb, [])
	    return
	}

	let nsCtx = NSGraphicsContext(cgContext: cgCtx, flipped: false)
	NSGraphicsContext.saveGraphicsState()
	NSGraphicsContext.current = nsCtx
	_placeholderImage.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
	NSGraphicsContext.restoreGraphicsState()
	CVPixelBufferUnlockBaseAddress(pb, [])

	var sampleBuffer: CMSampleBuffer?
	var timingInfo = CMSampleTimingInfo()
	timingInfo.presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock())

	let sbStatus = CMSampleBufferCreateForImageBuffer(
	    allocator: kCFAllocatorDefault,
	    imageBuffer: pb,
	    dataReady: true,
	    makeDataReadyCallback: nil,
	    refcon: nil,
	    formatDescription: _videoDescription,
	    sampleTiming: &timingInfo,
	    sampleBufferOut: &sampleBuffer
	)
	guard sbStatus == noErr, let sb = sampleBuffer else {
	    return
	}

	_streamSource.stream.send(
	    sb,
	    discontinuity: [],
	    hostTimeInNanoseconds: UInt64(
		timingInfo.presentationTimeStamp.seconds * Double(NSEC_PER_SEC)
	    )
	)
    }

    // MARK: - Sink Streaming

	func startStreamingSink(client: CMIOExtensionClient) {
	    _streamingSinkCounter += 1
	    sinkStarted = true

	    if _consumeBufferTimer == nil {
		// 1) Find the currently active format
		let currentFormat = _streamSource.formats[_streamSource.activeFormatIndex]

		// 2) We’ll assume minFrameDuration is the “fastest” fps the user can do
		//    If the chosen fps is 30, then minFrameDuration ~ 1/30.
		//    If it’s 29.97 => 1001/30000, etc.
		let dur = currentFormat.minFrameDuration
		// Invert that to get framesPerSecond
		// framesPerSecond = timescale / value (assuming value != 0).
		let framesPerSecond = Double(dur.timescale) / Double(dur.value)

		// 3) Poll at 3x the chosen fps
		// e.g. if user picked 30 fps => framesPerSecond=30 => pollInterval=1/(30*3)=1/90
		let pollInterval = 1.0 / (framesPerSecond * 3.0)

		_consumeBufferTimer = DispatchSource.makeTimerSource(flags: .strict, queue: _timerQueue)
		_consumeBufferTimer?.schedule(deadline: .now(),
					      repeating: pollInterval,
					      leeway: .seconds(0))
		_consumeBufferTimer?.setEventHandler { [weak self] in
		    self?.consumeBuffer(client)
		}
		_consumeBufferTimer?.resume()
	    }
	}

    func stopStreamingSink() {
	sinkStarted = false
	if _streamingSinkCounter > 1 {
	    _streamingSinkCounter -= 1
	} else {
	    _streamingSinkCounter = 0
	    _consumeBufferTimer?.cancel()
	    _consumeBufferTimer = nil
	}
    }

    func consumeBuffer(_ client: CMIOExtensionClient) {
	if !sinkStarted {
	    return
	}
	_streamSink.stream.consumeSampleBuffer(from: client) {
	    [weak self] sampleBuffer, sequenceNumber, discontinuity, hasMore, error in
	    guard let self = self, let sb = sampleBuffer else {
		return
	    }
	    self.lastTimingInfo.presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock())

	    let output = CMIOExtensionScheduledOutput(
		sequenceNumber: sequenceNumber,
		hostTimeInNanoseconds: UInt64(
		    self.lastTimingInfo.presentationTimeStamp.seconds * Double(NSEC_PER_SEC)
		)
	    )

	    // If there are active source clients, forward the sample buffer
	    if self._streamingCounter > 0 {
		self._streamSource.stream.send(
		    sb,
		    discontinuity: [],
		    hostTimeInNanoseconds: UInt64(
			sb.presentationTimeStamp.seconds * Double(NSEC_PER_SEC)
		    )
		)
	    }
	    self._streamSink.stream.notifyScheduledOutputChanged(output)
	}
    }
}
