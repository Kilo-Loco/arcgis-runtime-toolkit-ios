//
// Copyright 2019 Esri.

// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0

// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import UIKit
import ARKit
import ArcGIS

public class ArcGISARView: UIView {
    
    // MARK: public properties
    
    /// The view used to display the ARKit camera image and 3D SceneKit content
    public lazy private(set) var arSCNView = ARSCNView(frame: .zero)
    
    /// The view used to display ArcGIS 3D content
    public lazy private(set) var sceneView = AGSSceneView(frame: .zero)
    
    /// The world tracking information used by ARKit
    public var arConfiguration: ARConfiguration = {
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravityAndHeading
        if #available(iOS 11.3, *) {
            config.planeDetection = [.horizontal, .vertical]
        } else {
            config.planeDetection = [.horizontal]
        }
        return config
        }() {
        didSet {
            //start tracking using the new configuration
            startTracking()
        }
    }

    /// The viewpoint camera used to set the initial view of the sceneView instead of the devices GPS location via the locationManager
    public var originCamera: AGSCamera?
    
    /// The translation factor used to support a table top AR experience
    public var translationTransformationFactor: Double = 1.0
    
    // We implement ARSessionDelegate methods, but will use `sessionDelegate` to forward them to clients
    weak open var sessionDelegate: ARSessionDelegate?
    
    // We implement SCNSceneRendererDelegate methods, but will use `scnSceneRendererDelegate` to forward them to clients
    weak open var scnSceneRendererDelegate: SCNSceneRendererDelegate?

    // MARK: private properties
    
    /// Whether to display the camera image or not
    private var renderVideoFeed = true
    
    /// Used to determine the device location when originCamera is not set
    private lazy var locationManager: CLLocationManager = {
        let lm = CLLocationManager()
        lm.desiredAccuracy = kCLLocationAccuracyBest
        lm.delegate = self
        return lm
    }()
    
    /// Initial location from locationManager
    private var initialLocation: CLLocation?
    
    /// Current horizontal accuracy of the device
    private var horizontalAccuracy: CLLocationAccuracy = .greatestFiniteMagnitude;
    
    /// The intial camera position and orientation whether it was set via originCamera or the locationManager
    private var initialTransformationMatrix = AGSTransformationMatrix()
    
    /// Whether ARKit supported on this device?
    private var isSupported = false
    
    /// Whether the client has been notfiied of start/failure
    private var notifiedStartOrFailure = false
    
    /// These are used when calculating framerate
    var frameCount:Int = 0
    var frameCountTimer: Timer?
    
    // A quaternion used to compensate for the pitch beeing 90 degrees on ARKit; used to calculate the current device transformation for each frame
    let compensationQuat:simd_quatf = simd_quaternion(Float(sin(45 / (180 / Float.pi))), 0, 0, Float(cos(45 / (180 / Float.pi))))
    
    /// The quaternion used to represent the device orientation; used to calculate the current device transformation for each frame; defaults to landcape-left
    var orientationQuat:simd_quatf = simd_quaternion(0, 0, 1, 0)
    
    // MARK: Initializers
    
    public override init(frame: CGRect) {
        super.init(frame: frame)
        sharedInitialization()
    }
    
    required public init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        sharedInitialization()
    }
    
    /// Initializer used to denote whether to display the live camera image
    ///
    /// - Parameter renderVideoFeed: whether to dispaly the live camera image
    public convenience init(renderVideoFeed: Bool){
        self.init(frame: CGRect.zero)
        self.renderVideoFeed = renderVideoFeed
    }
    
    /// Initialization code shared between all initializers
    private func sharedInitialization(){
        //
        // ARKit initialization
        isSupported = ARWorldTrackingConfiguration.isSupported
        
        addSubviewWithConstraints(arSCNView)
        arSCNView.session.delegate = self
        (arSCNView as SCNSceneRenderer).delegate = self
        
        //
        // add sceneView to view and setup constraints
        addSubviewWithConstraints(sceneView)

        //
        // make our sceneView's background transparent, no atmosphereEffect
        sceneView.isBackgroundTransparent = true
        sceneView.atmosphereEffect = .none
        
        //
        // tell the sceneView we will be calling `renderFrame()` manually
        sceneView.isManualRendering = true
        
        //
        // we haven't yet notified user of start or failure
        notifiedStartOrFailure = false
        
        //
        // set intitial orientationQuat
        orientationChanged(notification: nil)
    }
    
    // MARK: Public
    
    /// Determines the map point for the given screen point
    ///
    /// - Parameter screenPoint: the point in screen coordinates
    /// - Returns: the map point corresponding to screenPoint
    public func arScreenToLocation(screenPoint: AGSPoint) -> AGSPoint {
        return AGSPoint(x: 0.0, y: 0.0, spatialReference: nil)
    }
    
    /// Resets the device tracking, using originCamera if it's not nil or the device's GPS location via the locationManager
    public func resetTracking() {
        initialLocation = nil
        startTracking()
    }

    /// Resets the device tracking, using the device's GPS location via the locationManager
    ///
    /// - Returns: reset operation success or failure
    public func resetUsingLocationServices() -> Bool {
        return false
    }
    
    /// Resets the device tracking using a spacial anchor
    ///
    /// - Returns: reset operation success or failure
    public func resetUsingSpatialAnchor() -> Bool {
        return false
    }
    
    /// Starts device tracking
    public func startTracking() {
        
        if !isSupported {
            didStartOrFailWithError(ArcGISARView.notSupportedError())
            return
        }
        
        if let origin = originCamera {
            //
            // we have a starting camera
            initialTransformationMatrix = origin.transformationMatrix
            sceneView.setViewpointCamera(origin)
            finalizeStart()
        }
        else {
            //
            // no starting camera, use location manger to get initial location
            let authStatus = CLLocationManager.authorizationStatus()
            switch authStatus {
            case .notDetermined:
                startWithAccessNotDetermined()
            case .restricted, .denied:
                startWithAccessDenied()
            case .authorizedAlways, .authorizedWhenInUse:
                startWithAccessAuthorized()
            }
        }
        
        //
        // we need to know when the device orientation changes in order to update the Camera transformation
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.orientationChanged(notification:)),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
        
        //
        // reset frameCount and start timer to capture frame rate
        frameCount = 0
        frameCountTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true, block: { [weak self] (timer) in
            print("Frame rate = \(String(reflecting: self?.frameCount))")
            self?.frameCount = 0
        })
    }

    /// Suspends device tracking
    public func stopTracking() {
        arSCNView.session.pause()
        stopUpdatingLocationAndHeading()
        
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        NotificationCenter.default.removeObserver(self)

        frameCountTimer?.invalidate()
    }
    
    // MARK: Private
    
    /// Operations that happen after device tracking has started
    fileprivate func finalizeStart() {
        //
        // hide the camera image if necessary
        arSCNView.isHidden = !renderVideoFeed
        
        //
        // run the ARSession
        arSCNView.session.run(arConfiguration, options:.resetTracking)
        didStartOrFailWithError(nil)
    }

    /// Adds subView to superView with appropriate constraints
    ///
    /// - Parameter subview: the subView to add
    fileprivate func addSubviewWithConstraints(_ subview: UIView) {
        // add subview to view and setup constraints
        addSubview(subview)
        subview.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            subview.leadingAnchor.constraint(equalTo: self.leadingAnchor),
            subview.trailingAnchor.constraint(equalTo: self.trailingAnchor),
            subview.topAnchor.constraint(equalTo: self.topAnchor),
            subview.bottomAnchor.constraint(equalTo: self.bottomAnchor)
            ])
    }
    
    /// Start the locationManager with undetermined access
    fileprivate func startWithAccessNotDetermined() {
        if (Bundle.main.object(forInfoDictionaryKey: "NSLocationWhenInUseUsageDescription") != nil) {
            locationManager.requestWhenInUseAuthorization()
        }
        if (Bundle.main.object(forInfoDictionaryKey: "NSLocationAlwaysUsageDescription") != nil) {
            locationManager.requestAlwaysAuthorization()
        }
        else{
            didStartOrFailWithError(ArcGISARView.missingPListKeyError())
        }
    }
    
    /// Start updating the location and heading via the locationManager
    fileprivate func startUpdatingLocationAndHeading() {
        locationManager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() {
            locationManager.startUpdatingHeading()
        }
    }
    
    /// Stop updating location and heading
    fileprivate func stopUpdatingLocationAndHeading() {
        locationManager.stopUpdatingLocation()
        if CLLocationManager.headingAvailable() {
            locationManager.stopUpdatingHeading()
        }
    }

    /// Start the locationManager with denied access
    fileprivate func startWithAccessDenied() {
        didStartOrFailWithError(ArcGISARView.accessDeniedError())
    }
    
    /// Start the locationManager with authorized access
    fileprivate func startWithAccessAuthorized() {
        startUpdatingLocationAndHeading()
    }
    
    /// Potential notification to the user of an error starting device tracking
    ///
    /// - Parameter error: error that ocurred when starting tracking
    fileprivate func didStartOrFailWithError(_ error: Error?) {
        if !notifiedStartOrFailure, let error = error {
            // TODO: present error to user...
            print("didStartOrFailWithError: \(String(reflecting:error))")
        }
        
        notifiedStartOrFailure = true;
    }
    
    /// Handle a change in authorization status to "denied"
    fileprivate func handleAuthStatusChangedAccessDenied() {
        // auth status changed to denied
        stopUpdatingLocationAndHeading()
        
        // we were waiting for user prompt to come back, so notify
        didStartOrFailWithError(ArcGISARView.accessDeniedError())
    }
    
    /// Handle a change in authorization status to "authorized"
    fileprivate func handleAuthStatusChangedAccessAuthorized() {
        // auth status changed to authorized
        // we were waiting for status to come in to start the datasource
        // now that we have authorization - start it
        didStartOrFailWithError(nil)
        
        // need to start location manager updates
        startUpdatingLocationAndHeading()
    }
    
    /// Called when device orientation changes
    ///
    /// - Parameter notification: the notification
    @objc func orientationChanged(notification: Notification?) {
        // handle rotation here
        switch UIApplication.shared.statusBarOrientation {
        case .landscapeLeft:
            orientationQuat = simd_quaternion(0, 0, 1.0, 0);
        case .landscapeRight:
            orientationQuat = simd_quaternion(0, 0, 0, 1.0);
        case .portrait:
            orientationQuat = simd_quaternion(0, 0, sqrt(0.5), sqrt(0.5));
        case .portraitUpsideDown:
            orientationQuat = simd_quaternion(0, 0, -sqrt(0.5), sqrt(0.5));
        default:
            break
        }
    }
    
    // MARK: Errors
    
    /// Error used when ARKit is not supported on the current device
    ///
    /// - Returns: error stating ARKit not supported
    fileprivate class func notSupportedError() -> NSError {
        let userInfo = [NSLocalizedDescriptionKey : "The device does not support ARKit functionality."]
        return NSError(domain: AGSErrorDomain, code: 0, userInfo: userInfo)
    }
    
    /// Error used when access to the device location is denied
    ///
    /// - Returns: error stating access to location information is denied
    fileprivate class func accessDeniedError() -> NSError{
        let userInfo = [NSLocalizedDescriptionKey : "Access to the device location is denied."]
        return NSError(domain: kCLErrorDomain, code: CLError.Code.denied.rawValue, userInfo: userInfo)
    }
    
    /// Error used when required plist information is missing
    ///
    /// - Returns: error stating plist information is missing
    fileprivate class func missingPListKeyError() -> NSError{
        let userInfo = [NSLocalizedDescriptionKey : "You must specify a location usage description key (NSLocationWhenInUseUsageDescription or NSLocationAlwaysUsageDescription) in your plist."]
        return NSError(domain: kCLErrorDomain, code: CLError.Code.denied.rawValue, userInfo: userInfo)
    }
}

// MARK: - ARSessionDelegate

extension ArcGISARView: ARSessionDelegate {
    
    /**
     This is called when a new frame has been updated.
     
     @param session The session being run.
     @param frame The frame that has been updated.
     */
    public func session(_ session: ARSession, didUpdate frame: ARFrame) {
        sessionDelegate?.session?(session, didUpdate: frame)
    }

    /**
     This is called when new anchors are added to the session.
     
     @param session The session being run.
     @param anchors An array of added anchors.
     */
    public func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        sessionDelegate?.session?(session, didAdd: anchors)
    }
    
    /**
     This is called when anchors are updated.
     
     @param session The session being run.
     @param anchors An array of updated anchors.
     */
    public func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        sessionDelegate?.session?(session, didUpdate: anchors)
    }
    
    /**
     This is called when anchors are removed from the session.
     
     @param session The session being run.
     @param anchors An array of removed anchors.
     */
    public func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        sessionDelegate?.session?(session, didRemove: anchors)
    }
}

// MARK: - ARSessionObserver
extension ArcGISARView: ARSessionObserver {
    // AR session methods
    
    /**
     This is called when a session fails.
     
     @discussion On failure the session will be paused.
     @param session The session that failed.
     @param error The error being reported (see ARError.h).
     */
    public func session(_ session: ARSession, didFailWithError error: Error) {
        guard error is ARError else { return }
        
        let errorWithInfo = error as NSError
        let messages = [
            errorWithInfo.localizedDescription,
            errorWithInfo.localizedFailureReason,
            errorWithInfo.localizedRecoverySuggestion
        ]
        
        // Remove optional error messages.
        let errorMessage = messages.compactMap({ $0 }).joined(separator: "\n")
        
        DispatchQueue.main.async {
            // Present an alert describing the error.
            let alertController = UIAlertController(title: "Could not start tracking.", message: errorMessage, preferredStyle: .alert)
            let restartAction = UIAlertAction(title: "Restart Tracking", style: .default) { _ in
                alertController.dismiss(animated: true, completion: nil)
                self.startTracking()
            }
            alertController.addAction(restartAction)
            
            guard let rootController = UIApplication.shared.keyWindow?.rootViewController else { return }
            rootController.present(alertController, animated: true, completion: nil)
        }
        
        sessionDelegate?.session?(session, didFailWithError: error)
    }
    
    /**
     This is called when the camera’s tracking state has changed.
     
     @param session The session being run.
     @param camera The camera that changed tracking states.
     */
    public func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        sessionDelegate?.session?(session, cameraDidChangeTrackingState: camera)
    }
    
    /**
     This is called when a session is interrupted.
     
     @discussion A session will be interrupted and no longer able to track when
     it fails to receive required sensor data. This happens when video capture is interrupted,
     for example when the application is sent to the background or when there are
     multiple foreground applications (see AVCaptureSessionInterruptionReason).
     No additional frame updates will be delivered until the interruption has ended.
     @param session The session that was interrupted.
     */
    public func sessionWasInterrupted(_ session: ARSession) {
        sessionDelegate?.sessionWasInterrupted?(session)
    }
    
    /**
     This is called when a session interruption has ended.
     
     @discussion A session will continue running from the last known state once
     the interruption has ended. If the device has moved, anchors will be misaligned.
     To avoid this, some applications may want to reset tracking (see ARSessionRunOptions)
     or attempt to relocalize (see `-[ARSessionObserver sessionShouldAttemptRelocalization:]`).
     @param session The session that was interrupted.
     */
    public func sessionInterruptionEnded(_ session: ARSession) {
        sessionDelegate?.sessionWasInterrupted?(session)
    }
    
    /**
     This is called after a session resumes from a pause or interruption to determine
     whether or not the session should attempt to relocalize.
     
     @discussion To avoid misaligned anchors, apps may wish to attempt a relocalization after
     a session pause or interruption. If YES is returned: the session will begin relocalizing
     and tracking state will switch to limited with reason relocalizing. If successful, the
     session's tracking state will return to normal. Because relocalization depends on
     the user's location, it can run indefinitely. Apps that wish to give up on relocalization
     may call run with `ARSessionRunOptionResetTracking` at any time.
     @param session The session to relocalize.
     @return Return YES to begin relocalizing.
     */
    @available(iOS 11.3, *)
    public func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool {
        if let result = sessionDelegate?.sessionShouldAttemptRelocalization?(session) {
            return result
        }
        return false
    }
    
    /**
     This is called when the session outputs a new audio sample buffer.
     
     @param session The session being run.
     @param audioSampleBuffer The captured audio sample buffer.
     */
    public func session(_ session: ARSession, didOutputAudioSampleBuffer audioSampleBuffer: CMSampleBuffer) {
        sessionDelegate?.session?(session, didOutputAudioSampleBuffer: audioSampleBuffer)
    }
}

// MARK: - CLLocationManagerDelegate
extension ArcGISARView: CLLocationManagerDelegate {
    /*
     *  locationManager:didUpdateLocations:
     *
     *  Discussion:
     *    Invoked when new locations are available.  Required for delivery of
     *    deferred locations.  If implemented, updates will
     *    not be delivered to locationManager:didUpdateToLocation:fromLocation:
     *
     *    locations is an array of CLLocation objects in chronological order.
     */
    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last, location.horizontalAccuracy >= 0.0 else { return }
        
        if initialLocation == nil {
            initialLocation = location
            horizontalAccuracy = location.horizontalAccuracy
            
            let locationPoint = AGSPoint(x: location.coordinate.longitude,
                                         y: location.coordinate.latitude,
                                         z: location.altitude,
                                         spatialReference: .wgs84())
            let camera = AGSCamera(location: locationPoint, heading: 0.0, pitch: 0.0, roll: 0.0)
            initialTransformationMatrix = camera.transformationMatrix
            sceneView.setViewpointCamera(camera)
            
            finalizeStart()
            print("didUpdateLocations - initialLocation...")
        }
        else if location.horizontalAccuracy < horizontalAccuracy {
            horizontalAccuracy = location.horizontalAccuracy
            print("didUpdateLocations - accuracy improved...")
        }
        
    }
    
    /*
     *  locationManager:didUpdateHeading:
     *
     *  Discussion:
     *    Invoked when a new heading is available.
     */
    @available(iOS 3.0, *)
    public func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        
    }
    
    /*
     *  locationManager:didFailWithError:
     *
     *  Discussion:
     *    Invoked when an error has occurred. Error types are defined in "CLError.h".
     */
    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        didStartOrFailWithError(error)
    }

    /*
     *  locationManager:didChangeAuthorizationStatus:
     *
     *  Discussion:
     *    Invoked when the authorization status changes for this application.
     */
    public  func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        let authStatus = CLLocationManager.authorizationStatus()
        switch authStatus {
        case .notDetermined:
            break
        case .restricted, .denied:
            handleAuthStatusChangedAccessDenied()
        case .authorizedAlways, .authorizedWhenInUse:
            handleAuthStatusChangedAccessAuthorized()
        }
    }

    /*
     *  Discussion:
     *    Invoked when location updates are automatically paused.
     */
    public func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        
    }
    
    /*
     *  Discussion:
     *    Invoked when location updates are automatically resumed.
     *
     *    In the event that your application is terminated while suspended, you will
     *      not receive this notification.
     */
    @available(iOS 6.0, *)
    public func locationManagerDidResumeLocationUpdates(_ manager: CLLocationManager) {
        
    }
}

// MARK: - SCNSceneRendererDelegate
extension ArcGISARView: SCNSceneRendererDelegate {

    public  func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        scnSceneRendererDelegate?.renderer?(renderer, updateAtTime: time)
    }

    public func renderer(_ renderer: SCNSceneRenderer, didApplyAnimationsAtTime time: TimeInterval) {
        scnSceneRendererDelegate?.renderer?(renderer, didApplyConstraintsAtTime: time)
    }
    
    public func renderer(_ renderer: SCNSceneRenderer, didSimulatePhysicsAtTime time: TimeInterval) {
        scnSceneRendererDelegate?.renderer?(renderer, didSimulatePhysicsAtTime: time)
    }
    
    public func renderer(_ renderer: SCNSceneRenderer, didApplyConstraintsAtTime time: TimeInterval) {
        scnSceneRendererDelegate?.renderer?(renderer, didApplyConstraintsAtTime: time)
    }
    
    public func renderer(_ renderer: SCNSceneRenderer, willRenderScene scene: SCNScene, atTime time: TimeInterval) {
        
        //
        // get transform from SCNView.pointOfView
        //
        guard let transform = arSCNView.pointOfView?.transform else { return }
        let cameraTransform = float4x4.init(transform)
        
        let finalQuat:simd_quatf = simd_mul(simd_mul(compensationQuat, simd_quaternion(cameraTransform)), orientationQuat)
        var transformationMatrix = AGSTransformationMatrix(quaternionX: Double(finalQuat.vector.x),
                                                           quaternionY: Double(finalQuat.vector.y),
                                                           quaternionZ: Double(finalQuat.vector.z),
                                                           quaternionW: Double(finalQuat.vector.w),
                                                           translationX: Double(cameraTransform.columns.3.x) * translationTransformationFactor,
                                                           translationY: Double(-cameraTransform.columns.3.z) * translationTransformationFactor,
                                                           translationZ: Double(cameraTransform.columns.3.y) * translationTransformationFactor)
        
        transformationMatrix = initialTransformationMatrix.addTransformation(transformationMatrix)
        
        let camera = AGSCamera(transformationMatrix: transformationMatrix)
        sceneView.setViewpointCamera(camera)
        
        sceneView.renderFrame()
        frameCount = frameCount + 1
        
        //
        // call our scnSceneRendererDelegate
        //
        scnSceneRendererDelegate?.renderer?(renderer, willRenderScene: scene, atTime: time)
    }
    
    public func renderer(_ renderer: SCNSceneRenderer, didRenderScene scene: SCNScene, atTime time: TimeInterval) {
        scnSceneRendererDelegate?.renderer?(renderer, didRenderScene: scene, atTime: time)
    }
}
