//  KeePassium Password Manager
//  Copyright © 2018-2025 KeePassium Labs <info@keepassium.com>
// 
//  This program is free software: you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 3 as published
//  by the Free Software Foundation: https://www.gnu.org/licenses/).
//  For commercial licensing, please contact the author.

import Foundation

public final class Salsa20: StreamCipher {
    private let blockSize = 64
    private static let sigma: [UInt8] =
        [0x65, 0x78, 0x70, 0x61, 0x6e, 0x64, 0x20, 0x33, 0x32, 0x2d, 0x62, 0x79, 0x74, 0x65, 0x20, 0x6b]
    private var key: SecureBytes
    private var iv: SecureBytes
    private var counter: UInt64
    private var block: [UInt8]
    private var posInBlock: Int

    init(key: SecureBytes, iv: SecureBytes) {
        assert(key.count == 32)
        assert(iv.count == 8)

        self.key = key.decrypted()
        self.iv = iv.decrypted()

        block = [UInt8](repeating: 0, count: blockSize)
        counter = 0
        posInBlock = blockSize
    }

    deinit {
        erase()
    }

    public func erase() {
        key.erase()
        iv.erase()
        block.erase()
        block = [UInt8](repeating: 0, count: blockSize) 
        counter = 0
    }

    func xor(bytes: inout [UInt8], progress: ProgressEx?) throws {
        let progressBatchSize = blockSize * 1024
        progress?.completedUnitCount = 0
        progress?.totalUnitCount = Int64(bytes.count / progressBatchSize) + 1

        key.withDecryptedBytes { keyBytes in
            iv.withDecryptedBytes { ivBytes in
                for i in 0..<bytes.count {
                    if posInBlock == blockSize {
                        var sigma = Salsa20.sigma
                        var counterBytes = counter.bytes
                        salsa20_core(&block, ivBytes, &counterBytes, keyBytes, &sigma)
                        counter += 1
                        posInBlock = 0
                        if i % progressBatchSize == 0 {
                            progress?.completedUnitCount += 1
                            if progress?.isCancelled ?? false { break }
                        }
                    }
                    bytes[i] ^= block[posInBlock]
                    posInBlock += 1
                }
            }
        }

        if let progress {
            progress.completedUnitCount = progress.totalUnitCount
            if progress.isCancelled {
                throw ProgressInterruption.cancelled(reason: progress.cancellationReason)
            }
        }
    }

    func encrypt(data: ByteArray, progress: ProgressEx? = nil) throws -> ByteArray {
        var outBytes = data.bytesCopy()
        try xor(bytes: &outBytes, progress: progress) 
        return ByteArray(bytes: outBytes)
    }

    func decrypt(data: ByteArray, progress: ProgressEx? = nil) throws -> ByteArray {
        return try encrypt(data: data, progress: progress) 
    }
}
