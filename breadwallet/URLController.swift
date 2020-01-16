//
//  URLController.swift
//  breadwallet
//
//  Created by Adrian Corscadden on 2017-05-26.
//  Copyright © 2017 breadwallet LLC. All rights reserved.
//

import UIKit

func getSenderAppInfo(request: DigiIdRequest?) -> (unknownApp: Bool, appURI: String) {
    var unknownApp = true
    var url = ""
    
    if let origin = request?.originURL {
        switch(senderApp) {
        case "com.apple.mobilesafari":
            // Safari does not have an url scheme. We can only hope that iOS opens the url again using Safari.
            // That is, the default browser happens to be Safari.
            url = origin
            unknownApp = false
        case "com.google.chrome":
            // If google chrome was the sender, we can easily open it using an url scheme.
            url = "googlechrome://\(origin)"
            unknownApp = false
        default:
            // another browser or app sent us here
            print("DigiID: an unknown application requested DigiID", senderApp)
            unknownApp = true
        }
    }
    
    return (unknownApp: unknownApp, appURI: url)
}

class URLController : Trackable {

    init(store: Store, walletManager: WalletManager) {
        self.store = store
        self.walletManager = walletManager
    }

    private let store: Store
    private let walletManager: WalletManager
    private var xSource, xSuccess, xError, uri: String?

    func handleUrl(_ url: URL) -> Bool {
        /*saveEvent("send.handleURL", attributes: [
            "scheme" : url.scheme ?? C.null,
            "host" : url.host ?? C.null,
            "path" : url.path
        ])*/

        switch url.scheme ?? "" {
        case "auroracoinwallet":
            if let query = url.query {
                for component in query.components(separatedBy: "&") {
                    let pair = component.components(separatedBy: "+")
                    if pair.count < 2 { continue }
                    let key = pair[0]
                    var value = String(component[component.index(key.endIndex, offsetBy: 2)...])
                    value = (value.replacingOccurrences(of: "+", with: " ") as NSString).removingPercentEncoding!
                    switch key {
                    case "x-source":
                        xSource = value
                    case "x-success":
                        xSuccess = value
                    case "x-error":
                        xError = value
                    case "uri":
                        uri = value
                    default:
                        print("Key not supported: \(key)")
                    }
                }
            }

            if url.host == "scanqr" || url.path == "/scanqr" {
                store.trigger(name: .scanQr)
            } else if url.host == "addresslist" || url.path == "/addresslist" {
                store.trigger(name: .copyWalletAddresses(xSuccess, xError))
            } else if url.path == "/address" {
                if let success = xSuccess {
                    copyAddress(callback: success)
                }
            } else if let uri = isBitcoinUri(url: url, uri: uri) {
                return handleBitcoinUri(uri)
            }
            return true
            
        case "auroracoin":
            return handleBitcoinUri(url)
            
        case "aurid":
            if BRDigiID.isBitIDURL(url) {
                handleBitId(url)
                return true
            }
            return false
            
        default:
            return false
        }
    }

    private func isBitcoinUri(url: URL, uri: String?) -> URL? {
        guard let uri = uri else { return nil }
        guard let bitcoinUrl = URL(string: uri) else { return nil }
        if (url.host == "auroracoin-uri" || url.path == "/auroracoin-uri") && bitcoinUrl.scheme == "auroracoin" {
            return url
        } else {
            return nil
        }
    }

    private func copyAddress(callback: String) {
        if let url = URL(string: callback), let wallet = walletManager.wallet {
            let queryLength = url.query?.utf8.count ?? 0
            let callback = callback.appendingFormat("%@address=%@", queryLength > 0 ? "&" : "?", wallet.receiveAddress)
            if let callbackURL = URL(string: callback) {
                UIApplication.shared.openURL(callbackURL)
            }
        }
    }

    private func handleBitcoinUri(_ uri: URL) -> Bool {
        if let request = PaymentRequest(string: uri.absoluteString) {
            store.trigger(name: .receivedPaymentRequest(request))
            return true
        } else {
            return false
        }
    }

    private func handleBitId(_ url: URL) {
        let bitid = BRDigiID(url: url, walletManager: walletManager)
        
        // senderApp
        let req = DigiIdRequest(string: url.absoluteString)
        
        let message = String(format: S.DigiID.authenticationRequest, bitid.url.host!)
        let alert = UIAlertController(title: S.DigiID.title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: S.DigiID.deny, style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: S.DigiID.approve, style: .default, handler: { _ in
            bitid.runCallback(store: self.store) { data, response, error in
                if let resp = response as? HTTPURLResponse, error == nil && resp.statusCode >= 200 && resp.statusCode < 300 {
                    let senderAppInfo = getSenderAppInfo(request: req)
                    if senderAppInfo.unknownApp {
                        // we can not open the sender app again, we will just display a messagebox
                        let alert = UIAlertController(title: S.DigiID.success, message: nil, preferredStyle: .alert)
                        alert.addAction(UIAlertAction(title: S.Button.ok, style: .default, handler: nil))
                        self.present(alert: alert)
                    } else {
                        // open the sender app
                        if let u = URL(string: senderAppInfo.appURI) {
                            DispatchQueue.main.async { UIApplication.shared.openURL(u) }
                        }
                    }
                } else {
                    let statusCode = (response as? HTTPURLResponse)?.statusCode
                    let additionalInformation = statusCode != nil ? "\(statusCode!)" : ""
                    
                    var errorInformation: String {
                        guard let data = data else { return S.DigiID.errorMessage }
                        do {
                            // check if server gave json response in format { message: <error description> }
                            let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                            return json["message"] as! String
                        } catch {
                            // just return response as string
                            return String(data: data, encoding: String.Encoding.utf8) ?? S.DigiID.errorMessage
                        }
                    }
                    
                    // show alert controller and display error description
                    let alert = UIAlertController(title: S.DigiID.error, message: "\(errorInformation).\n\n\(additionalInformation)", preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: S.Button.ok, style: .default, handler: nil))
                    self.present(alert: alert)
                }
            }
        }))
        present(alert: alert)
    }

    private func present(alert: UIAlertController) {
        store.trigger(name: .showAlert(alert))
    }
}
