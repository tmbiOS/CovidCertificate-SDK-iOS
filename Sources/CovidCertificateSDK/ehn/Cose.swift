//
//  Cose.swift
//
//
//  Created by Dominik Mocher on 07.04.21.
//

import Foundation
import Security
import SwiftCBOR

public struct Cose {
    private let type: CoseType
    let protectedHeader: CoseHeader
    let unprotectedHeader: CoseHeader?
    let payload: CBOR
    public let signature: Data
    public var ucCert: [CBOR: CBOR]? {
        payload.decodeBytestring()?.asMap()?[-260]?[1]?.asMap()
    }

    public var keyId: Data? {
        var keyData: Data?
        if let unprotectedKeyId = unprotectedHeader?.keyId {
            keyData = Data(unprotectedKeyId)
        }
        if let protectedKeyId = protectedHeader.keyId {
            keyData = Data(protectedKeyId)
        }
        return keyData
    }

    public var signatureStruct: Data? {
        guard let header = protectedHeader.rawHeader else {
            return nil
        }

        /* Structure according to https://tools.ietf.org/html/rfc8152#section-4.2 */
        switch type {
        case .sign1:
            let context = CBOR(stringLiteral: type.rawValue)
            let externalAad = CBOR.byteString([UInt8]()) /* no external application specific data */
            let cborArray = CBOR(arrayLiteral: context, header, externalAad, payload)
            return Data(cborArray.encode())
        default:
            return nil
        }
    }

    init?(from data: Data) {
        guard let decodedData = try? CBOR.decode(data.bytes) else {
            return nil
        }
        if let cose = try? CBORDecoder(input: data.bytes).decodeItem()?.asCose(),
           let type = CoseType.from(tag: cose.0),
           let protectedHeader = CoseHeader(fromBytestring: cose.1[0]),
           let signature = cose.1[3].asBytes() {
            self.type = type
            self.protectedHeader = protectedHeader
            unprotectedHeader = CoseHeader(from: cose.1[1])
            payload = cose.1[2]
            self.signature = Data(signature)
        } else {
            guard let decodedDataList = decodedData.asList() else {
                return nil
            }

            let headerCBOR = decodedDataList[0]
            guard let header = CoseHeader(fromBytestring: headerCBOR) else { return nil }
            protectedHeader = header

            let text = decodedDataList[2]
            payload = text

            unprotectedHeader = nil
            // if not sign1 this is an array of signatures
            guard let sigBytes = decodedDataList[3].asBytes() else {
                return nil
            }
            signature = Data(sigBytes)
            // TODO: we should also support multiple signatures
            type = .sign1
        }
    }

    @available(OSX 10.13, *)
    func hasValidSignature(for publicKey: SecKey) -> Bool {
        /* Only supporting Sign1 messages for the moment */
        switch type {
        case .sign1:
            return hasCoseSign1ValidSignature(for: publicKey)
        default:

            return false
        }
    }

    @available(OSX 10.13, *)
    private func hasCoseSign1ValidSignature(for key: SecKey) -> Bool {
        guard let signedData = signatureStruct else {
            return false
        }
        return verifySignature(key: key, signedData: signedData, rawSignature: signature)
    }

    @available(OSX 10.13, *)
    private func verifySignature(key: SecKey, signedData: Data, rawSignature: Data) -> Bool {
        var algorithm: SecKeyAlgorithm
        var signatureToVerify = rawSignature
        switch protectedHeader.algorithm {
        case .es256:
            algorithm = .ecdsaSignatureMessageX962SHA256
            signatureToVerify = Asn1Encoder().convertRawSignatureIntoAsn1(rawSignature)
        case .ps256:
            algorithm = .rsaSignatureMessagePSSSHA256
        default:

            return false
        }

        var error: Unmanaged<CFError>?
        let result = SecKeyVerifySignature(key, algorithm, signedData as CFData, signatureToVerify as CFData, &error)
        if let err = error?.takeUnretainedValue().localizedDescription {
            print(err)
        }
        error?.release()
        return result
    }

    // MARK: - Nested Types

    struct CoseHeader {
        fileprivate let rawHeader: CBOR?
        let keyId: [UInt8]?
        let algorithm: Algorithm?

        enum Headers: Int {
            case keyId = 4
            case algorithm = 1
        }

        enum Algorithm: UInt64 {
            case es256 = 6 // -7
            case ps256 = 36 // -37
            case ed25519 = 17
        }

        init?(fromBytestring cbor: CBOR) {
            guard let cborMap = cbor.decodeBytestring()?.asMap() else {
                return nil
            }
            let algValue = cborMap[Headers.algorithm]?.asUInt64() ?? Algorithm.ed25519.rawValue
            guard let alg = Algorithm(rawValue: algValue) else {
                return nil
            }
            self.init(alg: alg, keyId: cborMap[Headers.keyId]?.asBytes(), rawHeader: cbor)
        }

        init?(from cbor: CBOR) {
            let cborMap = cbor.asMap()
            var alg: Algorithm?
            if let algValue = cborMap?[Headers.algorithm]?.asUInt64() {
                alg = Algorithm(rawValue: algValue)
            }
            self.init(alg: alg, keyId: cborMap?[Headers.keyId]?.asBytes())
        }

        private init(alg: Algorithm?, keyId: [UInt8]?, rawHeader: CBOR? = nil) {
            algorithm = alg
            self.keyId = keyId
            self.rawHeader = rawHeader
        }
    }

    enum CoseType: String {
        case sign1 = "Signature1"
        case sign = "Signature"

        static func from(tag: CBOR.Tag) -> CoseType? {
            switch tag {
            case .coseSign1Item: return .sign1
            case .coseSignItem: return .sign
            default:
                return nil
            }
        }
    }
}

extension UnicodeScalar {
    var hexNibble: UInt8 {
        let value = self.value
        if 48 <= value && value <= 57 {
            return UInt8(value - 48)
        }
        else if 65 <= value && value <= 70 {
            return UInt8(value - 55)
        }
        else if 97 <= value && value <= 102 {
            return UInt8(value - 87)
        }
        fatalError("\(self) not a legal hex nibble")
    }
}

extension Data {
    init(hex: String) {
        let scalars = hex.unicodeScalars
        var bytes = Array<UInt8>(repeating: 0, count: (scalars.count + 1) >> 1)
        for (index, scalar) in scalars.enumerated() {
            var nibble = scalar.hexNibble
            if index & 1 == 0 {
                nibble <<= 4
            }
            bytes[index >> 1] |= nibble
        }
        self = Data(bytes)
    }
    
    func toHexString() -> String {
        self.bytes.toHexString()
    }
}

extension Array where Element == UInt8 {
    func toHexString() -> String {
        `lazy`.reduce(into: "") {
            var s = String($1, radix: 16)
            if s.count == 1 {
                s = "0" + s
            }
            $0 += s
        }
    }
}
