// Copyright 2020 Esri
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import UIKit
import ArcGIS

class EditWithBranchVersioningViewController: UIViewController {
    /// The label to display branch versioning status.
    @IBOutlet var statusLabel: UILabel!
    /// The button to creat a version.
    @IBOutlet var createBarButtonItem: UIBarButtonItem!
    /// The button to switch to a version.
    @IBOutlet var switchBarButtonItem: UIBarButtonItem!
    
    /// The map view managed by the view controller.
    @IBOutlet var mapView: AGSMapView! {
        didSet {
            mapView.map = makeMap()
            mapView.touchDelegate = self
            mapView.callout.delegate = self
        }
    }
    /// The geodatabase's default branch version name.
    var defaultVersionName: String!
    /// The geodatabase's existing version names in sorted order.
    var existingVersionNames = [String]() {
        didSet {
            existingVersionNames.sort()
        }
    }
    /// The name of the branch that the user is currently on.
    var currentVersionName: String! {
        didSet(newValue) {
            if newValue != nil {
                DispatchQueue.main.async { self.setStatus(message: newValue) }
            }
        }
    }
    
    var serviceGeodatabase: AGSServiceGeodatabase!
    var featureLayer: AGSFeatureLayer!
    var selectedFeature: AGSFeature?
    var identifyOperation: AGSCancelable?
    
    private enum DamageType: String, CaseIterable {
        case destroyed = "Destroyed"
        case major = "Major"
        case minor = "Minor"
        case affected = "Affected"
        case inaccessible = "Inaccessible"
        case `default` = "Default"
    }
    
    /// Create a map.
    ///
    /// - Returns: An `AGSMap` object.
    func makeMap() -> AGSMap {
        let map = AGSMap(basemap: .streetsVector())
        let serviceGeodatabase = AGSServiceGeodatabase(url: URL(string: "https://sampleserver7.arcgisonline.com/arcgis/rest/services/DamageAssessment/FeatureServer")!)
        serviceGeodatabase.credential = AGSCredential(user: "editor01", password: "editor01.password")
        SVProgressHUD.show(withStatus: "Loading service geodatabase…")
        serviceGeodatabase.load { [weak self] error in
            SVProgressHUD.dismiss()
            guard let self = self else { return }
            if serviceGeodatabase.loadStatus == .loaded {
                let featureLayer = AGSFeatureLayer(featureTable: serviceGeodatabase.table(withLayerID: 0)!)
                self.featureLayer = featureLayer
                map.operationalLayers.add(featureLayer)
                
                SVProgressHUD.show(withStatus: "Loading feature layer…")
                featureLayer.load { [weak self] error in
                    SVProgressHUD.dismiss()
                    if let error = error {
                        self?.presentAlert(error: error)
                    } else if let extent = featureLayer.fullExtent {
                        self?.mapView.setViewpoint(AGSViewpoint(targetExtent: extent), completion: nil)
                        self?.createBarButtonItem.isEnabled = true
                    }
                }
                self.defaultVersionName = serviceGeodatabase.defaultVersionName
                // It seems to be detached at first.
//                self.currentVersionName = serviceGeodatabase.versionName
                self.currentVersionName = serviceGeodatabase.defaultVersionName
                self.fetchVersions(geodatabase: serviceGeodatabase) { [weak self] result in
                    switch result {
                    case .success(let versions):
                        self?.existingVersionNames = versions
                        self?.switchBarButtonItem.isEnabled = true
                    case .failure(let error as NSError):
                        // Provide additional error reason to users.
                        let errorMessage = error.localizedDescription + (error.localizedFailureReason ?? "")
                        self?.presentAlert(title: "Error", message: errorMessage)
                    }
                }
                self.switchVersion(geodatabase: serviceGeodatabase, to: serviceGeodatabase.defaultVersionName)
            } else if let error = error {
                self.presentAlert(error: error)
            }
        }
        self.serviceGeodatabase = serviceGeodatabase
        return map
    }
    
    func identifyPixel(at screenPoint: CGPoint, completion: @escaping (AGSFeature) -> Void) {
        // Clear selection before identify.
        if let selectedFeature = selectedFeature {
            self.featureLayer.unselectFeature(selectedFeature)
        }
        // Clear in-progress identify operation.
        identifyOperation?.cancel()
        identifyOperation = nil
        // Identify the tapped feature.
        identifyOperation = mapView.identifyLayer(featureLayer, screenPoint: screenPoint, tolerance: 10.0, returnPopupsOnly: false) { [weak self] identifyResult in
            guard let self = self else { return }
            guard !identifyResult.geoElements.isEmpty, let firstFeature = identifyResult.geoElements.first as? AGSFeature else {
                return
            }
            self.featureLayer.select(firstFeature)
            self.selectedFeature = firstFeature
            completion(firstFeature)
        }
    }
    
    @IBAction func createBarButtonItemTapped(_ sender: UIBarButtonItem) {
        chooseVersionAccessPermission(sender) { permission in
            self.createBranchAlert(permission: permission) { parameters in
                self.createVersion(geodatabase: self.serviceGeodatabase, parameters: parameters) { [weak self] result in
                    switch result {
                    case .success(let versionName):
                        self?.existingVersionNames.append(versionName)
                    case .failure(let error as NSError):
                        // Provide additional error reason to users.
                        let errorMessage = error.localizedDescription + (error.localizedFailureReason ?? "")
                        self?.presentAlert(title: "Error", message: errorMessage)
                    }
                }
            }
        }
    }
    
    @IBAction func switchBarButtonItemTapped(_ sender: UIBarButtonItem) {
        chooseVersionToSwitch(sender) { versionName in
             self.switchVersion(geodatabase: self.serviceGeodatabase, to: versionName)
        }
    }
    
    func createServiceParameters(uniqueName: String, description: String?, accessPermission: AGSVersionAccess) -> AGSServiceVersionParameters {
        let parameters = AGSServiceVersionParameters()
        parameters.name = uniqueName
        parameters.access = accessPermission
        if let description = description {
            parameters.parametersDescription = description
        }
        return parameters
    }
    
    func fetchVersions(geodatabase: AGSServiceGeodatabase, completion: @escaping (Result<[String], Error>) -> Void) {
        geodatabase.fetchVersions { serviceVersionInfo, error in
            if let info = serviceVersionInfo {
                // Fetch versions succeeded.
                completion(.success(info.map { $0.name }))
            } else if let error = error {
                // Failed to fetch versions.
                completion(.failure(error))
            }
        }
    }
    
    func createVersion(geodatabase: AGSServiceGeodatabase, parameters: AGSServiceVersionParameters, completion: @escaping (Result<String, Error>) -> Void) {
        geodatabase.createVersion(with: parameters) { serviceVersionInfo, error in
            if let info = serviceVersionInfo {
                // Create version succeeded.
                completion(.success(info.name))
            } else if let error = error {
                // Failed to create version.
                completion(.failure(error))
            }
        }
    }
    
    func switchVersion(geodatabase: AGSServiceGeodatabase, to branchVersionName: String) {
        // Always apply local edits before switching to a new branch.
        applyLocalEdits(geodatabase: geodatabase) {
            geodatabase.switchVersion(withName: branchVersionName) { [weak self] error in
                guard let self = self else { return }
                if let error = error {
                    self.presentAlert(error: error)
                } else {
                    self.currentVersionName = branchVersionName
                    // Reload feature table with the new version.
                    self.featureLayer.featureTable?.load()
                }
            }
        }
    }
    
    func applyLocalEdits(geodatabase: AGSServiceGeodatabase, completion: (() -> Void)? = nil) {
        if geodatabase.hasLocalEdits() {
            SVProgressHUD.show(withStatus: "Applying local edits…")
            geodatabase.applyEdits { _, _ in
                SVProgressHUD.dismiss()
                completion?()
            }
        } else {
            completion?()
        }
    }
    
    func undoLocalEdits(geodatabase: AGSServiceGeodatabase) {
        if geodatabase.hasLocalEdits() {
            SVProgressHUD.show(withStatus: "Discarding local edits…")
            geodatabase.undoLocalEdits { _ in
                SVProgressHUD.dismiss()
            }
        }
    }
    
    // MARK: UI
    
    func setStatus(message: String) {
        statusLabel.text = message
    }
    
    func showCallout(_ feature: AGSFeature, tapLocation: AGSPoint?) {
        let damageLabel = feature.attributes["typdamage"] as? String
        mapView.callout.title = damageLabel ?? "Default"
        mapView.callout.show(for: feature, tapLocation: tapLocation, animated: true)
    }
    
    /// Move the currently selected feature to the given map point, by updating the selected feature's geometry and feature table.
    func moveFeature(feature: AGSFeature, to mapPoint: AGSPoint) {
        // Create an alert to confirm that the user wants to update the geometry.
        let alert = UIAlertController(title: "Confirm Update", message: "Are you sure you want to move the selected feature?", preferredStyle: .alert)
        // Clear the selection and selected feature if "No" is selected.
        let cancelAction = UIAlertAction(title: "Cancel", style: .cancel) { _ in
            self.featureLayer.unselectFeature(feature)
        }
        
        let moveAction = UIAlertAction(title: "Move", style: .default) { _ in
            // Set the selected feature's geometry to the new map point.
            feature.geometry = mapPoint
            // Update the selected feature's feature table.
            feature.featureTable?.update(feature) { _ in
                self.featureLayer.unselectFeature(feature)
                self.selectedFeature = nil
            }
        }
        alert.addAction(cancelAction)
        alert.addAction(moveAction)
        present(alert, animated: true)
    }
    
    func editFeatureDamageAttribute(feature: AGSFeature, sourceRect: CGRect) {
        let alertController = UIAlertController(
            title: "Damage type",
            message: "Choose a damage type for the building.",
            preferredStyle: .actionSheet
        )
        DamageType.allCases.forEach { type in
            let action = UIAlertAction(title: type.rawValue, style: .default) { _ in
                feature.attributes["typdamage"] = type.rawValue
                feature.featureTable?.update(feature)
                self.mapView.callout.dismiss()
            }
            alertController.addAction(action)
        }
        let cancelAction = UIAlertAction(title: "Cancel", style: .cancel) { _ in
            self.mapView.callout.dismiss()
        }
        alertController.addAction(cancelAction)
        alertController.popoverPresentationController?.sourceRect = sourceRect
        present(alertController, animated: true)
    }
    
    func createBranchAlert(permission: AGSVersionAccess, completion: @escaping (AGSServiceVersionParameters) -> Void) {
        // Create an object to observe changes from the text fields.
        var textFieldObserver: NSObjectProtocol!
        // An alert to get user input for branch name and description.
        let alertController = UIAlertController(
            title: "Create branch version",
            message: "Please provide a branch name and a description.",
            preferredStyle: .alert
        )
        // Remove observer on cancel.
        let cancelAction = UIAlertAction(title: "Cancel", style: .cancel) { _ in
            NotificationCenter.default.removeObserver(textFieldObserver!)
        }
        // Create a new version and remove observer.
        let createAction = UIAlertAction(title: "Create", style: .default) { [weak self] _ in
            guard let self = self else { return }
            NotificationCenter.default.removeObserver(textFieldObserver!)
            let branchTextField = alertController.textFields![0]
            let descriptionTextField = alertController.textFields![1]
            // If the text field is empty, do nothing.
            guard let branchText = branchTextField.text?.trimmingCharacters(in: .whitespacesAndNewlines), !branchText.isEmpty else { return }
            let descriptionText = descriptionTextField.text
            let parameters = self.createServiceParameters(uniqueName: branchText, description: descriptionText, accessPermission: permission)
            completion(parameters)
        }
        createAction.isEnabled = false
        alertController.addAction(cancelAction)
        alertController.addAction(createAction)
        alertController.preferredAction = createAction
        
        // The text field for version name.
        alertController.addTextField { textField in
            textField.placeholder = "Version name must be unique"
            textField.delegate = self
            textFieldObserver = NotificationCenter.default.addObserver(
                forName: UITextField.textDidChangeNotification,
                object: textField,
                queue: .main
            ) { _ in
                let text = alertController.textFields?[0].text?.trimmingCharacters(in: .whitespacesAndNewlines)
                // Enable the done button if
                // 1. branch version textfield is not empty.
                let notEmpty = text?.isEmpty == false
                // 2. branch version string does not exceed 62 characters.
                let noLongerThan62Characters = text?.count ?? 0 <= 62
                createAction.isEnabled = notEmpty && noLongerThan62Characters
            }
        }
        // The text field for version description.
        alertController.addTextField { textField in
            textField.placeholder = "Branch version description here"
        }
        present(alertController, animated: true)
    }
    
    func chooseVersionToSwitch(_ sender: UIBarButtonItem, completion: @escaping (String) -> Void) {
        let alertController = UIAlertController(
            title: "Choose branch version",
            message: "Choose to switch to another branch.",
            preferredStyle: .actionSheet
        )
        existingVersionNames.forEach { name in
            let action = UIAlertAction(title: name, style: .default) { _ in
                completion(name)
            }
            alertController.addAction(action)
        }
        let cancelAction = UIAlertAction(title: "Cancel", style: .cancel)
        alertController.addAction(cancelAction)
        alertController.popoverPresentationController?.barButtonItem = sender
        present(alertController, animated: true)
    }
    
    func chooseVersionAccessPermission(_ sender: UIBarButtonItem, completion: @escaping (AGSVersionAccess) -> Void) {
        let alertController = UIAlertController(
            title: "Branch version access level",
            message: "Choose an access level for the new branch version.",
            preferredStyle: .actionSheet
        )
        let versionAccessPermission: KeyValuePairs<String, AGSVersionAccess> = [
            "Public": .public,
            "Protected": .protected,
            "Private": .private
        ]
        versionAccessPermission.forEach { name, permission in
            let action = UIAlertAction(title: name, style: .default) { _ in
                completion(permission)
            }
            alertController.addAction(action)
        }
        let cancelAction = UIAlertAction(title: "Cancel", style: .cancel)
        alertController.addAction(cancelAction)
        alertController.popoverPresentationController?.barButtonItem = sender
        present(alertController, animated: true)
    }
    
    // MARK: UIViewController
    
    override func viewDidLoad() {
        super.viewDidLoad()
        // Add the source code button item to the right of navigation bar.
        (navigationItem.rightBarButtonItem as? SourceCodeBarButtonItem)?.filenames  = ["EditWithBranchVersioningViewController"]
    }
}

extension EditWithBranchVersioningViewController: AGSGeoViewTouchDelegate {
    func geoView(_ geoView: AGSGeoView, didTapAtScreenPoint screenPoint: CGPoint, mapPoint: AGSPoint) {
        // Dismiss presenting callout, if any.
        mapView.callout.dismiss()
        // Tap to identify a pixel on the feature layer.
        if let selectedFeature = selectedFeature {
            moveFeature(feature: selectedFeature, to: mapPoint)
        } else {
            identifyPixel(at: screenPoint) { feature in
                self.showCallout(feature, tapLocation: mapPoint)
            }
        }
    }
}

// MARK: - AGSCalloutDelegate

extension EditWithBranchVersioningViewController: AGSCalloutDelegate {
    func didTapAccessoryButton(for callout: AGSCallout) {
        // Show editing options actionsheet.
        editFeatureDamageAttribute(feature: selectedFeature!, sourceRect: callout.bounds)
    }
}

// MARK: - UITextFieldDelegate

extension EditWithBranchVersioningViewController: UITextFieldDelegate {
    // Ensure that the text field will only accept numbers.
    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        let text = (textField.text! as NSString).replacingCharacters(in: range, with: string)
        // Must not include special characters: . ; ' "
        let invalidCharacters = ".;'\""
        return CharacterSet(charactersIn: invalidCharacters).isDisjoint(with: CharacterSet(charactersIn: text))
    }
}
