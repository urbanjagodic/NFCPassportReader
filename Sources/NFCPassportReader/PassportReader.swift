//
//  PassportReader.swift
//  NFCTest
//
//  Created by Andy Qua on 11/06/2019.
//  Copyright © 2019 Andy Qua. All rights reserved.
//

import Foundation

#if !os(macOS)
import UIKit
import CoreNFC
import Security

typealias ByteArray = [UInt8]

@available(iOS 13, *)
public class PassportReader : NSObject {
    private typealias NFCCheckedContinuation = CheckedContinuation<NFCPassportModel, Error>
    private var nfcContinuation: NFCCheckedContinuation?

    private var passport : NFCPassportModel = NFCPassportModel()
    
    private var readerSession: NFCTagReaderSession?
    private var currentlyReadingDataGroup : DataGroupId?
    
    private var dataGroupsToRead : [DataGroupId] = []
    private var readAllDatagroups = false
    private var skipSecureElements = true
    private var skipCA = false
    private var skipPACE = false

    private var bacHandler : BACHandler?
    private var caHandler : ChipAuthenticationHandler?
    private var paceHandler : PACEHandler?
    private var accessKey: PACEAccessKey?
    private var dataAmountToReadOverride : Int? = nil

    
    private var pinNumber : String?
    private var challenge : String?
    
    private var scanCompletedHandler: ((NFCPassportModel?, NFCPassportReaderError?)->())!
    private var nfcViewDisplayMessageHandler: ((NFCViewDisplayMessage) -> String?)?
    private var masterListURL : URL?
    private var shouldNotReportNextReaderSessionInvalidationErrorUserCanceled : Bool = false

    // By default, Passive Authentication uses the new RFS5652 method to verify the SOD, but can be switched to use
    // the previous OpenSSL CMS verification if necessary
    public var passiveAuthenticationUsesOpenSSL : Bool = false

    public init( logLevel: LogLevel = .info, masterListURL: URL? = nil ) {
        super.init()
        
        Log.logLevel = logLevel
        self.masterListURL = masterListURL
    }
    
    public func setMasterListURL( _ masterListURL : URL ) {
        self.masterListURL = masterListURL
    }
    
    // This function allows you to override the amount of data the TagReader tries to read from the NFC
    // chip. NOTE - this really shouldn't be used for production but is useful for testing as different
    // passports support different data amounts.
    // It appears that the most reliable is 0xA0 (160 chars) but some will support arbitary reads (0xFF or 256)
    public func overrideNFCDataAmountToRead( amount: Int ) {
        dataAmountToReadOverride = amount
    }

    @available(*, deprecated, message: "Use readPassport( accessKey: ...) instead")
    public func readPassport( mrzKey : String, tags : [DataGroupId] = [], skipSecureElements : Bool = true, skipCA : Bool = false, skipPACE : Bool = false, customDisplayMessage : ((NFCViewDisplayMessage) -> String?)? = nil) async throws -> NFCPassportModel {
        try await readPassport(
            accessKey: .mrz(mrzKey),
            tags: tags,
            skipSecureElements: skipSecureElements,
            skipCA: skipCA,
            skipPACE: skipPACE,
            customDisplayMessage: customDisplayMessage
        )
    }

    public func readPassport( accessKey : PACEAccessKey, pin : String? = nil, challenge: String? = nil, tags : [DataGroupId] = [], skipSecureElements : Bool = true, skipCA : Bool = false, skipPACE : Bool = false, customDisplayMessage : ((NFCViewDisplayMessage) -> String?)? = nil) async throws -> NFCPassportModel {
        
        self.passport = NFCPassportModel()
        self.accessKey = accessKey
        self.skipCA = skipCA
        self.skipPACE = skipPACE
        
        self.pinNumber = pin
        self.challenge = challenge
        
        self.dataGroupsToRead.removeAll()
        self.dataGroupsToRead.append( contentsOf:tags)
        self.nfcViewDisplayMessageHandler = customDisplayMessage
        self.skipSecureElements = skipSecureElements
        self.currentlyReadingDataGroup = nil
        self.bacHandler = nil
        self.caHandler = nil
        self.paceHandler = nil
        
        // If no tags specified, read all
        if self.dataGroupsToRead.count == 0 {
            // Start off with .COM, will always read (and .SOD but we'll add that after), and then add the others from the COM
            self.dataGroupsToRead.append(contentsOf:[.COM, .SOD] )
            self.readAllDatagroups = true
        } else {
            // We are reading specific datagroups
            self.readAllDatagroups = false
        }
        
        guard NFCNDEFReaderSession.readingAvailable else {
            throw NFCPassportReaderError.NFCNotSupported
        }
        
        if NFCTagReaderSession.readingAvailable {
            readerSession = NFCTagReaderSession(pollingOption: [.iso14443], delegate: self, queue: nil)
            
            self.updateReaderSessionMessage( alertMessage: NFCViewDisplayMessage.requestPresentPassport )
            readerSession?.begin()
        }
        
        return try await withCheckedThrowingContinuation({ (continuation: NFCCheckedContinuation) in
            self.nfcContinuation = continuation
        })
    }
}

@available(iOS 13, *)
extension PassportReader : NFCTagReaderSessionDelegate {
    // MARK: - NFCTagReaderSessionDelegate
    public func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {
        // If necessary, you may perform additional operations on session start.
        // At this point RF polling is enabled.
        Log.debug( "tagReaderSessionDidBecomeActive" )
    }
    
    public func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        // If necessary, you may handle the error. Note session is no longer valid.
        // You must create a new session to restart RF polling.
        Log.debug( "tagReaderSession:didInvalidateWithError - \(error.localizedDescription)" )
        self.readerSession?.invalidate()
        self.readerSession = nil

        if let readerError = error as? NFCReaderError, readerError.code == NFCReaderError.readerSessionInvalidationErrorUserCanceled
            && self.shouldNotReportNextReaderSessionInvalidationErrorUserCanceled {
            
            self.shouldNotReportNextReaderSessionInvalidationErrorUserCanceled = false
        } else {
            var userError = NFCPassportReaderError.UnexpectedError
            if let readerError = error as? NFCReaderError {
                Log.error( "tagReaderSession:didInvalidateWithError - Got NFCReaderError - \(readerError.localizedDescription)" )
                switch (readerError.code) {
                case NFCReaderError.readerSessionInvalidationErrorUserCanceled:
                    Log.error( "     - User cancelled session" )
                    userError = NFCPassportReaderError.UserCanceled
                default:
                    Log.error( "     - some other error - \(readerError.localizedDescription)" )
                    userError = NFCPassportReaderError.UnexpectedError
                }
            } else {
                Log.error( "tagReaderSession:didInvalidateWithError - Received error - \(error.localizedDescription)" )
            }
            nfcContinuation?.resume(throwing: userError)
            nfcContinuation = nil
        }
    }
    
    public func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        Log.debug( "tagReaderSession:didDetect - \(tags[0])" )
        if tags.count > 1 {
            Log.debug( "tagReaderSession:more than 1 tag detected! - \(tags)" )

            let errorMessage = NFCViewDisplayMessage.error(.MoreThanOneTagFound)
            self.invalidateSession(errorMessage: errorMessage, error: NFCPassportReaderError.MoreThanOneTagFound)
            return
        }

        let tag = tags.first!
        var passportTag: NFCISO7816Tag
        switch tags.first! {
        case let .iso7816(tag):
            passportTag = tag
        default:
            Log.debug( "tagReaderSession:invalid tag detected!!!" )

            let errorMessage = NFCViewDisplayMessage.error(NFCPassportReaderError.TagNotValid)
            self.invalidateSession(errorMessage:errorMessage, error: NFCPassportReaderError.TagNotValid)
            return
        }
        
        Task { [passportTag] in
            do {
                try await session.connect(to: tag)
                
                Log.debug( "tagReaderSession:connected to tag - starting authentication" )
                self.updateReaderSessionMessage( alertMessage: NFCViewDisplayMessage.authenticatingWithPassport)
                
                let tagReader = TagReader(tag:passportTag)
                
                if let newAmount = self.dataAmountToReadOverride {
                    tagReader.overrideDataAmountToRead(newAmount: newAmount)
                }
                
                tagReader.progress = { [unowned self] (progress) in
                    if let dgId = self.currentlyReadingDataGroup {
                        self.updateReaderSessionMessage( alertMessage: NFCViewDisplayMessage.readingUSerData)
                    } else {
                        self.updateReaderSessionMessage( alertMessage: NFCViewDisplayMessage.authenticatingWithPassport)
                    }
                }
                
                let passportModel = try await self.startReading( tagReader : tagReader)
                nfcContinuation?.resume(returning: passportModel)
                nfcContinuation = nil

                
            } catch let error as NFCPassportReaderError {
                let errorMessage = NFCViewDisplayMessage.error(error)
                self.invalidateSession(errorMessage: errorMessage, error: error)
            } catch let error {

                nfcContinuation?.resume(throwing: error)
                nfcContinuation = nil
                Log.debug( "tagReaderSession:failed to connect to tag - \(error.localizedDescription)" )
                let errorMessage = NFCViewDisplayMessage.error(NFCPassportReaderError.ConnectionError)
                self.invalidateSession(errorMessage: errorMessage, error: NFCPassportReaderError.ConnectionError)
            }
        }
    }
    
    func updateReaderSessionMessage(alertMessage: NFCViewDisplayMessage ) {
        self.readerSession?.alertMessage = self.nfcViewDisplayMessageHandler?(alertMessage) ?? alertMessage.description
    }
}

extension Data {
    struct HexEncodingOptions: OptionSet {
        let rawValue: Int
        static let upperCase = HexEncodingOptions(rawValue: 1 << 0)
    }

    func hexEncodedString(options: HexEncodingOptions = []) -> String {
        let format = options.contains(.upperCase) ? "%02hhX" : "%02hhx"
        return self.map { String(format: format, $0) }.joined()
    }
}


@available(iOS 13, *)
extension PassportReader {
    
    func startReading(tagReader : TagReader) async throws -> NFCPassportModel {
        guard let accessKey else {
            preconditionFailure("accessKey not set")
        }

        if !skipPACE {
            do {
                let data = try await tagReader.readCardAccess()
                Log.verbose( "Read CardAccess - data \(binToHexRep(data))" )
                let cardAccess = try CardAccess(data)
                passport.cardAccess = cardAccess
     
                Log.info( "Starting Password Authenticated Connection Establishment (PACE)" )
                 
                let paceHandler = try PACEHandler( cardAccess: cardAccess, tagReader: tagReader )
                try await paceHandler.doPACE( accessKey: accessKey )
                passport.PACEStatus = .success
                Log.debug( "PACE Succeeded" )
            } catch {
                passport.PACEStatus = .failed
                switch accessKey {
                case .can:
                    Log.error( "PACE Failed - BAC fallback skipped because accessKey == .can" )
                    throw error
                case .mrz:
                    Log.error( "PACE Failed - falling back to BAC" )
                }
            }
            
            _ = try await tagReader.selectPassportApplication()
        }
        
        // If either PACE isn't supported, we failed whilst doing PACE or we didn't even attempt it, then fall back to BAC
        if passport.PACEStatus != .success {
            try await doBACAuthentication(tagReader : tagReader)
        }
        
        // Now to read the datagroups
        try await readDataGroups(tagReader: tagReader)
        
        
        self.updateReaderSessionMessage(alertMessage: NFCViewDisplayMessage.authenticatingWithPin)

        
        let response = try await tagReader.executeAPDUCommands(stringCommand: "00A40000023F00")
        var dataTest = Data()
        dataTest.append(contentsOf: [response.sw1, response.sw2])
                
        
        
        let response2 = try await tagReader.executeAPDUCommands(stringCommand: "00A4040C0AE828BD080F014E585030")
        var dataTest2 = Data()
        dataTest2.append(contentsOf: [response2.sw1, response2.sw2])
                
        
        // Authenticating with PIN
        
        let dataPin = Data(self.pinNumber!.utf8)
        let hexPin = dataPin.map{ String(format:"%02x", $0) }.joined()
        
        
        let response3 = try await tagReader.executeAPDUCommands(stringCommand: "0020000506\(hexPin)")
        var dataTest3 = Data()
        dataTest3.append(contentsOf: [response3.sw1, response3.sw2])
                
        
        self.updateReaderSessionMessage(alertMessage: NFCViewDisplayMessage.pinauthenticationSuccessful)

        
        
        let response4 = try await tagReader.executeAPDUCommands(stringCommand: "002281B604910222A1")
        var dataTest4 = Data()
        dataTest4.append(contentsOf: [response4.sw1, response4.sw2])
                
        
        // Signing challenge
        
        self.updateReaderSessionMessage(alertMessage: NFCViewDisplayMessage.signingChallenge)
        
        let challengeResponse = try await tagReader.executeAPDUCommands(stringCommand: "002A9E9A30\(self.challenge!)00")
        var dataChallenge = Data()
        dataChallenge.append(contentsOf: [challengeResponse.sw1, challengeResponse.sw2])
        
        var signedChallengeData = Data()
        signedChallengeData.append(contentsOf: challengeResponse.data)
        
        var signedChallengeHexString = hexString(data: signedChallengeData)
        
        
        self.passport.addSignedChallenge(challenge: signedChallengeHexString)
        
        // READING CERT DATA
        
        self.updateReaderSessionMessage(alertMessage: NFCViewDisplayMessage.readingCertificate)
        
        
        let response5 = try await tagReader.executeAPDUCommands(stringCommand: "00A4000002001D")
        var dataTest5 = Data()
        dataTest5.append(contentsOf: [response5.sw1, response5.sw2])
        
        
        let certDataStream = NSMutableData()
        let readLength = 200
        var offset = 0
        var readBuffer: ByteArray?
        
        while(true) {
            
            let command = "00B0" + String(format: "%04X", offset * readLength) + "C8"
            let responseApduCert = try await tagReader.executeAPDUCommands(stringCommand: command)
            
            readBuffer = responseApduCert.data
            certDataStream.append(readBuffer!, length: readBuffer!.count)
            offset += 1
            if (readBuffer!.count < readLength) {
                break
            }
        }
        
        //let base64StringCert = (certDataStream as Data).base64EncodedString()
        
        var certificateHexString = hexString(data: certDataStream as Data)
        
        self.passport.addUserCertificate(certificate: certificateHexString)
        self.updateReaderSessionMessage(alertMessage: NFCViewDisplayMessage.successfulRead)

        
        self.shouldNotReportNextReaderSessionInvalidationErrorUserCanceled = true
        self.readerSession?.invalidate()

        return self.passport
    }
    
    
    func doActiveAuthenticationIfNeccessary( tagReader : TagReader) async throws {
        guard self.passport.activeAuthenticationSupported else {
            return
        }
        
        Log.info( "Performing Active Authentication" )
        
        let challenge = generateRandomUInt8Array(8)
        Log.verbose( "Generated Active Authentication challange - \(binToHexRep(challenge))")
        let response = try await tagReader.doInternalAuthentication(challenge: challenge)
        self.passport.verifyActiveAuthentication( challenge:challenge, signature:response.data )
    }
    

    func doBACAuthentication(tagReader : TagReader) async throws {
        self.currentlyReadingDataGroup = nil
        
        Log.info( "Starting Basic Access Control (BAC)" )
        
        self.passport.BACStatus = .failed

        switch accessKey {
        case .none:
            Log.error("Basic Access Control (BAC) - FAILED! No accessKey set.")
        case .mrz( let mrzKey ):
            self.bacHandler = BACHandler( tagReader: tagReader )
            try await bacHandler?.performBACAndGetSessionKeys( mrzKey: mrzKey )
            Log.info( "Basic Access Control (BAC) - SUCCESS!" )

            self.passport.BACStatus = .success
        case .can:
            Log.error("Basic Access Control (BAC) - FAILED! accessKey == .can. BAC is only supported with .mrz")
        }

    }

    func readDataGroups( tagReader: TagReader ) async throws {
        
        // Read only DG1
        var dataGroup1 = DataGroupId.DG1
        
        self.updateReaderSessionMessage(alertMessage: NFCViewDisplayMessage.readingUSerData)
        if let dg = try await readDataGroup(tagReader:tagReader, dgId: dataGroup1) {
            self.passport.addDataGroup(dataGroup1, dataGroup:dg)
        }
    }
    
    func readDataGroup( tagReader : TagReader, dgId : DataGroupId ) async throws -> DataGroup?  {

        self.currentlyReadingDataGroup = dgId
        Log.info( "Reading tag - \(dgId)" )
        var readAttempts = 0
        
        self.updateReaderSessionMessage( alertMessage: NFCViewDisplayMessage.readingUSerData)

        repeat {
            do {
                let response = try await tagReader.readDataGroup(dataGroup:dgId)
                let dg = try DataGroupParser().parseDG(data: response)
                return dg
            } catch let error as NFCPassportReaderError {
                Log.error( "TagError reading tag - \(error)" )

                // OK we had an error - depending on what happened, we may want to try to re-read this
                // E.g. we failed to read the last Datagroup because its protected and we can't
                let errMsg = error.value
                Log.error( "ERROR - \(errMsg)" )
                
                var redoBAC = false
                if errMsg == "Session invalidated" || errMsg == "Class not supported" || errMsg == "Tag connection lost"  {
                    // Check if we have done Chip Authentication, if so, set it to nil and try to redo BAC
                    if self.caHandler != nil {
                        self.caHandler = nil
                        redoBAC = true
                    } else {
                        // Can't go any more!
                        throw error
                    }
                } else if errMsg == "Security status not satisfied" || errMsg == "File not found" {
                    // Can't read this element as we aren't allowed - remove it and return out so we re-do BAC
                    self.dataGroupsToRead.removeFirst()
                    redoBAC = true
                } else if errMsg == "SM data objects incorrect" || errMsg == "Class not supported" {
                    // Can't read this element security objects now invalid - and return out so we re-do BAC
                    redoBAC = true
                } else if errMsg.hasPrefix( "Wrong length" ) || errMsg.hasPrefix( "End of file" ) {  // Should now handle errors 0x6C xx, and 0x67 0x00
                    // OK passport can't handle max length so drop it down
                    tagReader.reduceDataReadingAmount()
                    redoBAC = true
                }
                
                if redoBAC {
                    // Redo BAC and try again
                    try await doBACAuthentication(tagReader : tagReader)
                } else {
                    // Some other error lets have another try
                }
            }
            readAttempts += 1
        } while ( readAttempts < 2 )
        
        return nil
    }

    func invalidateSession(errorMessage: NFCViewDisplayMessage, error: NFCPassportReaderError) {
        // Mark the next 'invalid session' error as not reportable (we're about to cause it by invalidating the
        // session). The real error is reported back with the call to the completed handler
        self.shouldNotReportNextReaderSessionInvalidationErrorUserCanceled = true
        self.readerSession?.invalidate(errorMessage: self.nfcViewDisplayMessageHandler?(errorMessage) ?? errorMessage.description)
        nfcContinuation?.resume(throwing: error)
        nfcContinuation = nil
    }
    
    func hexString(data: Data) -> String {
        return data.map { String(format: "%02x", $0) }.joined()
    }
    
}
#endif
