//
//  NFCViewDisplayMessage.swift
//  NFCPassportReader
//
//  Created by Andy Qua on 09/02/2021.
//

import Foundation

@available(iOS 13, macOS 10.15, *)
public enum NFCViewDisplayMessage {
    case requestPresentPassport
    case authenticatingWithPassport
    case readingUserData
    case error(NFCPassportReaderError)
    case successfulRead
    case readingCertificate
    case authenticatingWithPin
    case pinauthenticationSuccessful
    case signingChallenge
    case tagNotValid
    case moreThanOneTagFound
    case connectionError
    case authenticationFailed
    case invalidPin(String)
}

@available(iOS 13, macOS 10.15, *)
extension NFCViewDisplayMessage {
    public var description: String {
        switch self {
            case .requestPresentPassport:
                return "Hold your iPhone near an NFC enabled passport."
            case .authenticatingWithPassport:
                return "Authenticating with passport ..."
            case .readingUserData:
                return "Reading user data ..."
            case .tagNotValid:
                return "Tag not valid."
            case .moreThanOneTagFound:
                return "More than 1 tags was found. Please present only 1 tag."
            case .connectionError:
                return "Connection error. Please try again."
            case .authenticationFailed:
                return "Invalid CAN Key for this document."
            case .invalidPin(let pinTriesLeft):
                return "Invalid PIN code. You have \(pinTriesLeft) tries left."
            case .error(_):
                return "Sorry, there was a problem reading the document. Please try again"
            case .successfulRead:
                return "Identity document read successfully"
            case .readingCertificate:
                return "Reading user certificate"
            case .authenticatingWithPin:
                return "Authenticating with PIN"
            case .pinauthenticationSuccessful:
                return "PIN authentication successful"
            case .signingChallenge:
                return "Signing challenge"
        }
    }
    
//    func handleProgress(percentualProgress: Int) -> String {
//        let p = (percentualProgress/20)
//        let full = String(repeating: "🟢 ", count: p)
//        let empty = String(repeating: "⚪️ ", count: 5-p)
//        return "\(full)\(empty)"
//    }
}
