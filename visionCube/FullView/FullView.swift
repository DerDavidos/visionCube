import CompositorServices
import SwiftUI
import Metal
import MetalKit
import simd
import Spatial
import SwiftUI
import RealityKit
import RealityKitContent
import ARKit
import Accelerate

let maxBuffersInFlight = 10

class FullView {
    public let device: MTLDevice
    let commandQueue: MTLCommandQueue
    
    var pipelineState: MTLRenderPipelineState
    var depthState: MTLDepthStencilState
    var texture: MTLTexture
    
    let arSession: ARKitSession
    let worldTracking: WorldTrackingProvider
    let layerRenderer: LayerRenderer
    
    var vertCount: size_t = 0
    
    var view = simd_float4x4()
    var model = simd_float4x4()
    var clipBoxSize = simd_float3(1, 1, 1)
    var clipBoxShift = simd_float3(0, 0, 0)
    
    var cube: Tesselation!
    var meshNeedsUpdate = true
    
    var volumeModell: VolumeModell
    
    var volumeName: String
    
    var vertexBuffer: MTLBuffer!
    var matrixBuffer: MTLBuffer
    var parameterBuffer: MTLBuffer
    
    var matrix: UnsafeMutablePointer<MatricesArray>
    var param: UnsafeMutablePointer<ParamsArray>
    
    struct Matrices {
        var modelViewProjection: simd_float4x4
        var clip: simd_float4x4
    }
    
    struct RenderParams {
        var smoothStepStart: Float
        var smoothStepShift: Float
        var oversampling: Float
        var cameraPosInTextureSpace: simd_float3
        var minBounds: simd_float3
        var maxBounds: simd_float3
        var modelView: simd_float4x4
        var modelViewIT: simd_float4x4
    }
    
    init(_ layerRenderer: LayerRenderer, volumeModell: VolumeModell) {
        self.volumeModell = volumeModell
        self.volumeName = volumeModell.selectedVolume
        self.layerRenderer = layerRenderer
        self.device = layerRenderer.device
        self.commandQueue = self.device.makeCommandQueue()!
        
        do {
            pipelineState = try buildRenderPipelineWithDevice(device: device,
                                                              layerRenderer: layerRenderer, lighting: volumeModell.lighting)
        } catch {
            fatalError("Unable to compile render pipeline state.  Error info: \(error)")
        }
        
        let depthStateDescriptor = MTLDepthStencilDescriptor()
        depthStateDescriptor.depthCompareFunction = MTLCompareFunction.greater
        depthStateDescriptor.isDepthWriteEnabled = true
        self.depthState = device.makeDepthStencilState(descriptor:depthStateDescriptor)!
        
        do {
            texture = try loadTexture(device: device, dataset: volumeModell.dataset)
        } catch {
            fatalError("Unable to load texture. Error info: \(error)")
        }
        
        self.vertexBuffer = nil
        
        self.matrixBuffer = self.device.makeBuffer(length: MemoryLayout<Matrices>.stride * 2,
                                                   options: [MTLResourceOptions.storageModeShared])!
        matrix = UnsafeMutableRawPointer(matrixBuffer.contents()).bindMemory(to: MatricesArray.self, capacity: 1)
        
        self.parameterBuffer = self.device.makeBuffer(length: MemoryLayout<RenderParams>.stride * 2,
                                                      options: [MTLResourceOptions.storageModeShared])!
        param = UnsafeMutableRawPointer(parameterBuffer.contents()).bindMemory(to: ParamsArray.self, capacity: 1)
        
        worldTracking = WorldTrackingProvider()
        arSession = ARKitSession()
        cube = Tesselation.genBrick(center: Vec3(x: 0, y: 0, z: 0), size: Vec3(x: 1, y: 1, z: 1), texScale: Vec3(x: 1, y: 1, z: 1) ).unpack()
        
        self.vertexBuffer = self.device.makeBuffer(length: MemoryLayout<Float>.stride * cube.vertices.count,
                                                   options: [MTLResourceOptions.storageModeShared])!
        
        print("init")
    }
    
    func buildBuffers() {
        print("buildBuffers")
        let matrixDataSize = MemoryLayout<Matrices>.stride
        let paramDataSize = MemoryLayout<RenderParams>.stride
        
        matrixBuffer = device.makeBuffer(length: matrixDataSize)!
        parameterBuffer = device.makeBuffer(length: paramDataSize)!
    }
    
    func updateMatrices(drawable: LayerRenderer.Drawable,  deviceAnchor: DeviceAnchor?) {
        let translate = volumeModell.transform.translation
        let scale = SIMD3<Float>(volumeModell.transform.scale.x * Float(volumeModell.dataset.volume.width), volumeModell.transform.scale.y * Float(volumeModell.dataset.volume.height), volumeModell.transform.scale.z * Float(volumeModell.dataset.volume.depth)) / Float(volumeModell.dataset.volume.maxSize)
        
        let modelMatrix = Transform(scale: scale, rotation: volumeModell.transform.rotation, translation: translate).matrix
        
        let simdDeviceAnchor = deviceAnchor?.originFromAnchorTransform ?? matrix_identity_float4x4
        
        clipBoxSize.x = 1 - volumeModell.XClip
        clipBoxSize.y = 1 - volumeModell.YClip
        clipBoxSize.z = 1 - volumeModell.ZClip
        
        clipBoxShift.x = volumeModell.XClip / 2
        clipBoxShift.y = volumeModell.YClip / 2
        clipBoxShift.z = volumeModell.ZClip / 2
        let clipBox = Transform(scale: clipBoxSize, translation: clipBoxShift).matrix
        let minBounds = clipBox * simd_float4(-0.5, -0.5, -0.5, 1.0) + 0.5
        let maxBounds = clipBox * simd_float4(0.5, 0.5, 0.5, 1.0) + 0.5
        
        func projection(forView: Int,  renderParams: inout ShaderRenderParamaters, matrix: inout shaderMatrices) {
            
            let view = drawable.views[forView]
            let viewMatrix: simd_float4x4 = (simdDeviceAnchor * view.transform).inverse
            
            let projection: simd_float4x4 = simd_float4x4(ProjectiveTransform3D(leftTangent: Double(view.tangents[0]),
                                                                                rightTangent: Double(view.tangents[1]),
                                                                                topTangent: Double(view.tangents[2]),
                                                                                bottomTangent: Double(view.tangents[3]),
                                                                                nearZ: Double(drawable.depthRange.y),
                                                                                farZ: Double(drawable.depthRange.x),
                                                                                reverseZ: true))
            
            let viewToTexture = Transform(translation: SIMD3<Float>(0.5, 0.5,0.5)).matrix * simd_inverse(viewMatrix * modelMatrix)
            
            renderParams.cameraPosInTextureSpace = simd_make_float3(viewToTexture * simd_float4(0, 0, 0, 1))
            renderParams.oversampling = OVERSAMPLING
            renderParams.smoothStepStart = volumeModell.smoothStepStart
            renderParams.smoothStepShift = volumeModell.smoothStepShift
            renderParams.cameraPosInTextureSpace = simd_make_float3(viewToTexture * simd_float4(0, 0, 0, 1))
            renderParams.minBounds = simd_make_float3(minBounds)
            renderParams.maxBounds = simd_make_float3(maxBounds)
            renderParams.modelView = viewMatrix * modelMatrix * clipBox
            renderParams.modelViewIT = simd_transpose(simd_inverse(viewMatrix * modelMatrix * clipBox));
            
            matrix.clip = clipBox
            matrix.modelViewProjection = projection * viewMatrix * modelMatrix * clipBox
        }
        
        projection(forView: 0, renderParams: &param.pointee.params.0, matrix: &matrix.pointee.matrices.0)
        
        if drawable.views.count > 1 {
            projection(forView: 1, renderParams: &param.pointee.params.1, matrix: &matrix.pointee.matrices.1)
        }
        
        meshNeedsUpdate = true
    }
    
    func clipCubeToNearplane() {
        if !meshNeedsUpdate {
            print("NO UPDATE")
            return
        }
        
        meshNeedsUpdate = false
        
        let objectSpaceNearPlane = simd_transpose(view * model) * simd_float4(0, 0, 1.0, 0.1 + 0.01)
        let verts = meshPlane(
            posData: cube.vertices,
            A: objectSpaceNearPlane.x,
            B: objectSpaceNearPlane.y,
            C: objectSpaceNearPlane.z,
            D: objectSpaceNearPlane.w
        )
        
        let vertexDataSize = MemoryLayout<Float>.stride * verts.count
        
        vertexBuffer.contents().copyMemory(from: verts, byteCount: vertexDataSize * 2)
        vertCount = verts.count / 4
    }
    
    func renderFrame() {
        /// Per frame updates hare
        guard let frame = layerRenderer.queryNextFrame() else { return }
        
        if (volumeName != volumeModell.selectedVolume) {
            texture = try! loadTexture(device: device, dataset: volumeModell.dataset)
        }
        
        if (volumeModell.lightingNeedsUpdate) {
            pipelineState = try! buildRenderPipelineWithDevice(device: device,
                                                               layerRenderer: layerRenderer, lighting: volumeModell.lighting)
            volumeModell.lightingNeedsUpdate = false
        }
        
        frame.startUpdate()
        frame.endUpdate()
        
        guard let timing = frame.predictTiming() else { return }
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)
        
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            fatalError("Failed to create command buffer")
        }
        
        // Perform frame independent work
        guard let drawable = frame.queryDrawable() else { return }
        
        frame.startSubmission()
        
        let time = LayerRenderer.Clock.Instant.epoch.duration(to: drawable.frameTiming.presentationTime).timeInterval
        let deviceAnchor = worldTracking.queryDeviceAnchor(atTimestamp: time)
        
        drawable.deviceAnchor = deviceAnchor
        
        updateMatrices(drawable: drawable, deviceAnchor: deviceAnchor)
        clipCubeToNearplane()
        
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = drawable.colorTextures[0]
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0)
        renderPassDescriptor.depthAttachment.texture = drawable.depthTextures[0]
        renderPassDescriptor.depthAttachment.loadAction = .clear
        renderPassDescriptor.depthAttachment.storeAction = .store
        renderPassDescriptor.depthAttachment.clearDepth = 0.0
        renderPassDescriptor.rasterizationRateMap = drawable.rasterizationRateMaps.first
        if layerRenderer.configuration.layout == .layered {
            renderPassDescriptor.renderTargetArrayLength = drawable.views.count
        }
        
        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            fatalError("Failed to create render encoder")
        }
        
        renderEncoder.setCullMode(.back)
        renderEncoder.setFrontFacing(.counterClockwise)
        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setDepthStencilState(depthState)
        
        renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        renderEncoder.setVertexBuffer(matrixBuffer, offset: 0, index: 1)
        
        let viewports = drawable.views.map { $0.textureMap.viewport }
        renderEncoder.setViewports(viewports)
        
        if drawable.views.count > 1 {
            var viewMappings = (0..<drawable.views.count).map {
                MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: UInt32($0),
                                                  renderTargetArrayIndexOffset: UInt32($0))
            }
            renderEncoder.setVertexAmplificationCount(viewports.count, viewMappings: &viewMappings)
        }
        
        renderEncoder.setFragmentTexture(texture, index: TextureIndex.color.rawValue)
        
        renderEncoder.setFragmentBuffer(parameterBuffer, offset: 0, index: 0)
        
        renderEncoder.drawPrimitives(type: MTLPrimitiveType.triangle, vertexStart: 0, vertexCount: vertCount)
        
        renderEncoder.popDebugGroup()
        renderEncoder.endEncoding()
        drawable.encodePresent(commandBuffer: commandBuffer)
        commandBuffer.commit()
        
        frame.endSubmission()
    }
    
    func startRenderLoop() {
        Task {
            do {
                try await arSession.run([worldTracking])
            } catch {
                fatalError("Failed to initialize ARSession")
            }
            
            let renderThread = Thread {
                self.renderLoop()
            }
            renderThread.name = "Render Thread"
            renderThread.start()
        }
    }
    
    func renderLoop() {
        while true {
            if layerRenderer.state == .invalidated {
                print("Layer is invalidated")
                return
            } else if layerRenderer.state == .paused {
                layerRenderer.waitUntilRunning()
                continue
            } else {
                autoreleasepool {
                    self.renderFrame()
                }
            }
        }
    }
    
    private var tmpTranslation: SIMD3<Float> = .zero
    private var tmpRotation: simd_quatf = .init(.identity)
    private var tmpDistance: Double = 0.0
    
    func distanceBetweenVectors(v1: SIMD3<Double>, v2: SIMD3<Double>) -> Double {
        let deltaX = v2.x - v1.x
        let deltaY = v2.y - v1.y
        let deltaZ = v2.z - v1.z
        return sqrt(deltaX * deltaX + deltaY * deltaY + deltaZ * deltaZ)
    }
    
    func handleSpatialEvents(_ events: SpatialEventCollection) {
        if (events.count == 2) {
            var v1: SIMD3<Double>?
            var v2: SIMD3<Double>?
            for event in events {
                switch event.phase {
                case .active:
                    if v1 == nil {
                        v1 = event.inputDevicePose!.pose3D.position.vector
                    } else {
                        v2 = event.inputDevicePose!.pose3D.position.vector
                    }
                    print(event.inputDevicePose!.pose3D.position)
                case .cancelled:
                    print("Event cancelled")
                case .ended:
                    volumeModell.lastTransform.scale = volumeModell.transform.scale
                    tmpDistance = 0
                    print("Event ended normally")
                default:
                    break
                }
            }
            if (v1 != nil && v2 != nil) {
                let distance = distanceBetweenVectors(v1: v1!, v2: v2!)
                if tmpDistance == 0.0 {
                    tmpDistance = distance
                }
                volumeModell.transform.scale = SIMD3(repeating: volumeModell.lastTransform.scale.x * (Float(distance - tmpDistance) + 1))
                print((Float(distance - tmpDistance) + 1))
            }
           
            print()
            return
        }
        let event = events.first!
        switch event.phase {
        case .active:
            if let pose = event.inputDevicePose {
                if tmpTranslation == .zero {
                    tmpTranslation = SIMD3<Float>(pose.pose3D.position.vector)
                    tmpRotation = simd_quatf(pose.pose3D.rotation)
                }
                
                let translate = (SIMD3<Float>(pose.pose3D.position.vector) - tmpTranslation) * 2
                
                volumeModell.transform.rotation = volumeModell.lastTransform.rotation * simd_quatf(pose.pose3D.rotation) * tmpRotation.inverse
                volumeModell.transform.translation = volumeModell.lastTransform.translation + translate
            }
        case .cancelled:
            print("Event cancelled")
        case .ended:
            print("Event ended normally")
            volumeModell.lastTransform.translation = volumeModell.transform.translation
            volumeModell.lastTransform.rotation = volumeModell.transform.rotation
            tmpTranslation = .zero
            tmpRotation = .init(.identity)
        default:
            break
        }
    }
}
