import SwiftUI
import CompositorServices

let OVERSAMPLING: Float = 1
let START_VOLUME: String = "c60"

@main
struct visionShaderApp: App {
    @State private var volumeModell: VolumeModell
    @State private var visionProPose = VisionProPositon()
    
    init() {
        self.volumeModell = VolumeModell()
    }
    
    var body: some Scene {
        WindowGroup {
            VolumeControll(volumeModell: volumeModell, visionProPose: visionProPose)
        }.windowStyle(.plain)
        
        ImmersiveSpace(id: "AxisView") {
            AxisView(volumeModell: volumeModell, visionProPose: visionProPose)
        }.immersionStyle(selection: .constant(.mixed), in: .mixed)
        
        ImmersiveSpace(id: "FullView") {
            CompositorLayer(configuration: ContentStageConfiguration()) { layerRenderer in
                let fullView = FullView(layerRenderer, volumeModell: volumeModell)
                fullView.startRenderLoop()
                
                layerRenderer.onSpatialEvent = { eventCollection in
//                    print(eventCollection.first)
//                    var events = eventCollection.map { mySpatialEvent($0) }
                }
            }
        }.immersionStyle(selection: .constant(.full), in: .full)
    }
}
