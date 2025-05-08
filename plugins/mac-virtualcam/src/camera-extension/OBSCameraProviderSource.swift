//
//  OBSCameraProviderSource.swift
//  camera-extension
//
//  Created by Sebastian Beckmann on 2022-09-30.
//  Changed by Patrick Heyer on 2022-10-16.
//  Retains original logic, references revised OBSCameraDeviceSource
//

import CoreMediaIO
import Foundation

class OBSCameraProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: OBSCameraDeviceSource!

    init(clientQueue: DispatchQueue?, deviceUUID: UUID, sourceUUID: UUID, sinkUUID: UUID) {
	super.init()

	provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
	deviceSource = OBSCameraDeviceSource(
	    localizedName: "Groovy OBS Virtual Camera",
	    deviceUUID: deviceUUID,
	    sourceUUID: sourceUUID,
	    sinkUUID: sinkUUID
	)
	do {
	    try provider.addDevice(deviceSource.device)
	} catch {
	    fatalError("Failed to add device: \(error.localizedDescription)")
	}
    }

    func connect(to client: CMIOExtensionClient) throws {
	// Not used in this sample
    }

    func disconnect(from client: CMIOExtensionClient) {
	// Not used in this sample
    }

    var availableProperties: Set<CMIOExtensionProperty> {
	return [.providerName, .providerManufacturer]
    }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
	-> CMIOExtensionProviderProperties
    {
	let props = CMIOExtensionProviderProperties(dictionary: [:])
	if properties.contains(.providerName) {
	    props.name = "OBS Camera Extension Provider"
	}
	if properties.contains(.providerManufacturer) {
	    props.manufacturer = "OBS Project"
	}
	return props
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {
	// No provider-level properties to set
    }
}
