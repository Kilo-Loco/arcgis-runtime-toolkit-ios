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
    
    public lazy private(set) var arSCNView = ARSCNView(frame: .zero)
    public lazy private(set) var sceneView = AGSSceneView(frame: .zero)
    public var arConfiguration: ARConfiguration = ARWorldTrackingConfiguration() {
        didSet {
            //start tracking using the new configuration
            startTracking()
        }
    }

    public var originCamera: AGSCamera?
    public var translationTransformationFactor: Double = 1.0
    
    // we intercept these methods first, but will use `delegate` to forward them to clients
    weak open var delegate: ARSessionDelegate?

    // MARK: private properties
    
    private var renderVideoFeed = true
    
    private lazy var locationManager: CLLocationManager = {
        let lm = CLLocationManager()
        lm.desiredAccuracy = kCLLocationAccuracyBest
        lm.delegate = self
        return lm
    }()
    
    // initial location from locationManager
    private var initialLocation: CLLocation?
    private var horizontalAccuracy: CLLocationAccuracy = .greatestFiniteMagnitude;

    // is ARKit supported on this device?
    private var isSupported = false
    
    // has the client been notfiied of start/failure
    private var notifiedStartOrFailure = false
    
    // MARK: Initializers
    
    public override init(frame: CGRect) {
        super.init(frame: frame)
        sharedInitialization()
    }
    
    required public init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        sharedInitialization()
    }
    
    public convenience init(renderVideoFeed: Bool){
        self.init(frame: CGRect.zero)
        self.renderVideoFeed = renderVideoFeed
    }
    
    private func sharedInitialization(){
        //
        // ARKit initialization
        isSupported = ARWorldTrackingConfiguration.isSupported
        
        addSubviewWithConstraints(arSCNView)
        arSCNView.session.delegate = self
        
        //
        // add sceneView to view and setup constraints
        addSubviewWithConstraints(sceneView)

        //
        // make our sceneView's background transparent
        sceneView.isBackgroundTransparent = true
        sceneView.isManualRendering = true
        sceneView.atmosphereEffect = .none

        notifiedStartOrFailure = false
    }

    // MARK: Public
    
    public func arScreenToLocation(screenPoint: AGSPoint) -> AGSPoint {
        return AGSPoint(x: 0.0, y: 0.0, spatialReference: nil)
    }
    
    public func resetTracking() {
        // reset initial location, so we're sure to set it from the LocationManager (provided originCamera == nil)
        initialLocation = nil
        startTracking()
    }

    public func resetUsingLocationServices() -> Bool {
        return false
    }
    
    public func resetUsingSpatialAnchor() -> Bool {
        return false
    }
    
    public func startTracking() {
        
        if !isSupported {
            didStartOrFailWithError(ArcGISARView.notSupportedError())
            return
        }
        
        // TODO: look at original beta code and grab locationmanager started stuff
        if let origin = originCamera {
            //set origin on sceneView???
            sceneView.setViewpointCamera(origin)
            finalizeStart()
        }
        else {
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
    }

    public func stopTracking() {
        arSCNView.session.pause()
        stopUpdatingLocationAndHeading()
    }
    
    // MARK: Private
    fileprivate func finalizeStart() {
        arSCNView.isHidden = !renderVideoFeed
        arSCNView.session.run(arConfiguration, options:.resetTracking)
        didStartOrFailWithError(nil)
    }

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
    
    fileprivate func startUpdatingLocationAndHeading() {
        locationManager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() {
            locationManager.startUpdatingHeading()
        }
    }
    
    fileprivate func stopUpdatingLocationAndHeading() {
        locationManager.stopUpdatingLocation()
        if CLLocationManager.headingAvailable() {
            locationManager.stopUpdatingHeading()
        }
    }

    fileprivate func startWithAccessDenied() {
        didStartOrFailWithError(ArcGISARView.accessDeniedError())
    }
    
    fileprivate func startWithAccessAuthorized() {
        startUpdatingLocationAndHeading()
    }
    
    fileprivate func didStartOrFailWithError(_ error: Error?) {
        if !notifiedStartOrFailure, let error = error {
            // TODO: present error to user...
            print("didStartOrFailWithError: \(String(reflecting:error))")
        }
        
        notifiedStartOrFailure = true;
    }
    
    fileprivate func handleAuthStatusChangedAccessDenied() {
        // auth status changed to denied
        stopUpdatingLocationAndHeading()
        
        // we were waiting for user prompt to come back, so notify
        didStartOrFailWithError(ArcGISARView.accessDeniedError())
    }
    
    fileprivate func handleAuthStatusChangedAccessAuthorized() {
        // auth status changed to authorized
        // we were waiting for status to come in to start the datasource
        // now that we have authorization - start it
        didStartOrFailWithError(nil)
        
        // need to start location manager updates
        startUpdatingLocationAndHeading()
    }

    // MARK: Errors
    class func notSupportedError() -> NSError {
        let userInfo = [NSLocalizedDescriptionKey : "The device does not support ARKit functionality."]
        return NSError(domain: AGSErrorDomain, code: 0, userInfo: userInfo)
    }
    
    class func accessDeniedError() -> NSError{
        let userInfo = [NSLocalizedDescriptionKey : "Access to the device location is denied."]
        return NSError(domain: kCLErrorDomain, code: CLError.Code.denied.rawValue, userInfo: userInfo)
    }
    
    class func missingPListKeyError() -> NSError{
        let userInfo = [NSLocalizedDescriptionKey : "You must specify a location usage description key (NSLocationWhenInUseUsageDescription or NSLocationAlwaysUsageDescription) in your plist."]
        return NSError(domain: kCLErrorDomain, code: CLError.Code.denied.rawValue, userInfo: userInfo)
    }
}

// MARK: - ARSessionDelegate
extension ArcGISARView: ARSessionDelegate {
    // AR session delegate methods
    
    /**
     This is called when a new frame has been updated.
     
     @param session The session being run.
     @param frame The frame that has been updated.
     */
    public func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // TODO: updateCamera().....
        //print("didUpdateFrame...")
        delegate?.session?(session, didUpdate: frame)
        self.sceneView.renderFrame()
    }
    
    /**
     This is called when new anchors are added to the session.
     
     @param session The session being run.
     @param anchors An array of added anchors.
     */
    public func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        delegate?.session?(session, didAdd: anchors)
    }
    
    /**
     This is called when anchors are updated.
     
     @param session The session being run.
     @param anchors An array of updated anchors.
     */
    public func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        delegate?.session?(session, didUpdate: anchors)
    }
    
    /**
     This is called when anchors are removed from the session.
     
     @param session The session being run.
     @param anchors An array of removed anchors.
     */
    public func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        delegate?.session?(session, didRemove: anchors)
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
        
        delegate?.session?(session, didFailWithError: error)
    }
    
    /**
     This is called when the camera’s tracking state has changed.
     
     @param session The session being run.
     @param camera The camera that changed tracking states.
     */
    public func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        delegate?.session?(session, cameraDidChangeTrackingState: camera)
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
        delegate?.sessionWasInterrupted?(session)
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
        delegate?.sessionWasInterrupted?(session)
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
        if let result = delegate?.sessionShouldAttemptRelocalization?(session) {
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
        delegate?.session?(session, didOutputAudioSampleBuffer: audioSampleBuffer)
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
            sceneView.setViewpointCamera(camera)
            
            finalizeStart()
        }
        else if location.horizontalAccuracy < horizontalAccuracy {
            horizontalAccuracy = location.horizontalAccuracy
            // TODO: update current location???
        }
        
        print("didUpdateLocations...")
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
