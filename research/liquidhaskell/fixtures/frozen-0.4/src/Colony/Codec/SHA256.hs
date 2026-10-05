{-# LANGUAGE BangPatterns #-}
-- | Pure SHA-256 (FIPS 180-4), using only base, bytestring and array.
-- The compression arithmetic intentionally wraps modulo 2^32. Int is used
-- only for bounded buffer/array indices, never for digest arithmetic.
module Colony.Codec.SHA256 (sha256, sha256Hex) where

import Control.Monad.ST (ST, runST)
import Data.Array.ST (STUArray, newArray_, readArray, writeArray)
import Data.Array.Unboxed (UArray, (!), listArray)
import Data.Bits ((.&.), (.|.), complement, rotateR, shiftL, shiftR, xor)
import qualified Data.ByteString as BS
import Data.Word (Word8, Word32, Word64)

data Hash = Hash !Word32 !Word32 !Word32 !Word32
                 !Word32 !Word32 !Word32 !Word32

initialHash :: Hash
initialHash = Hash 0x6a09e667 0xbb67ae85 0x3c6ef372 0xa54ff53a
                   0x510e527f 0x9b05688c 0x1f83d9ab 0x5be0cd19

-- | Hash a strict byte string and return exactly 32 bytes in network order.
-- Blocks are read directly from the input. Only the final one or two blocks
-- are copied for padding; the schedule and compression state are bounded.
sha256 :: BS.ByteString -> BS.ByteString
sha256 input = hashBytes (finish (blocks 0 initialHash))
  where
    !inputLength = BS.length input
    !completeLength = inputLength - inputLength `rem` 64
    blocks !offset !state
      | offset == completeLength = state
      | otherwise = blocks (offset + 64) (compress state input offset)
    !tailLength = inputLength - completeLength
    !zeroCount = (55 - tailLength) `mod` 64
    -- FIPS 180-4 encodes the original bit length as a big-endian Word64.
    !bitLength = fromIntegral inputLength * 8 :: Word64
    padded = BS.concat
      [ BS.drop completeLength input, BS.singleton 0x80
      , BS.replicate zeroCount 0, BS.pack (word64Bytes bitLength)
      ]
    finish !state =
      let !first = compress state padded 0
      in if BS.length padded == 64 then first else compress first padded 64

-- | Lowercase hexadecimal representation of 'sha256', always 64 characters.
sha256Hex :: BS.ByteString -> String
sha256Hex = BS.foldr byteHex [] . sha256
  where
    byteHex byte rest = hex (byte `shiftR` 4) : hex (byte .&. 0x0f) : rest
    hex nibble = "0123456789abcdef" !! fromIntegral nibble

hashBytes :: Hash -> BS.ByteString
hashBytes (Hash a b c d e f g h) =
  BS.pack (concatMap word32Bytes [a,b,c,d,e,f,g,h])

word32Bytes :: Word32 -> [Word8]
word32Bytes word = [fromIntegral (word `shiftR` n) | n <- [24,16,8,0]]

word64Bytes :: Word64 -> [Word8]
word64Bytes word = [fromIntegral (word `shiftR` n) | n <- [56,48,40,32,24,16,8,0]]

readWord32 :: BS.ByteString -> Int -> Word32
readWord32 bytes offset =
  (byte 0 `shiftL` 24) .|. (byte 1 `shiftL` 16) .|.
  (byte 2 `shiftL` 8) .|. byte 3
  where
    byte n = fromIntegral (BS.index bytes (offset + n))

compress :: Hash -> BS.ByteString -> Int -> Hash
compress original bytes offset = runST $ do
  schedule <- newArray_ (0,63)
  loadSchedule schedule bytes offset 0
  expandSchedule schedule 16
  result <- rounds schedule 0 original
  pure (addHash original result)

loadSchedule :: STUArray s Int Word32 -> BS.ByteString -> Int -> Int -> ST s ()
loadSchedule schedule bytes offset !i
  | i == 16 = pure ()
  | otherwise = do
      writeArray schedule i (readWord32 bytes (offset + 4 * i))
      loadSchedule schedule bytes offset (i + 1)

expandSchedule :: STUArray s Int Word32 -> Int -> ST s ()
expandSchedule schedule !i
  | i == 64 = pure ()
  | otherwise = do
      a <- readArray schedule (i - 16)
      b <- readArray schedule (i - 15)
      c <- readArray schedule (i - 7)
      d <- readArray schedule (i - 2)
      writeArray schedule i (a + smallSigma0 b + c + smallSigma1 d)
      expandSchedule schedule (i + 1)

rounds :: STUArray s Int Word32 -> Int -> Hash -> ST s Hash
rounds schedule !i !state@(Hash a b c d e f g h)
  | i == 64 = pure state
  | otherwise = do
      word <- readArray schedule i
      let !t1 = h + bigSigma1 e + choose e f g + roundConstants ! i + word
          !t2 = bigSigma0 a + majority a b c
      rounds schedule (i + 1) (Hash (t1 + t2) a b c (d + t1) e f g)

addHash :: Hash -> Hash -> Hash
addHash (Hash a b c d e f g h) (Hash a' b' c' d' e' f' g' h') =
  Hash (a + a') (b + b') (c + c') (d + d')
       (e + e') (f + f') (g + g') (h + h')

choose, majority :: Word32 -> Word32 -> Word32 -> Word32
choose x y z = (x .&. y) `xor` (complement x .&. z)
majority x y z = (x .&. y) `xor` (x .&. z) `xor` (y .&. z)

smallSigma0, smallSigma1, bigSigma0, bigSigma1 :: Word32 -> Word32
smallSigma0 x = rotateR x 7 `xor` rotateR x 18 `xor` shiftR x 3
smallSigma1 x = rotateR x 17 `xor` rotateR x 19 `xor` shiftR x 10
bigSigma0 x = rotateR x 2 `xor` rotateR x 13 `xor` rotateR x 22
bigSigma1 x = rotateR x 6 `xor` rotateR x 11 `xor` rotateR x 25

roundConstants :: UArray Int Word32
roundConstants = listArray (0,63)
  [ 0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5
  , 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5
  , 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3
  , 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174
  , 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc
  , 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da
  , 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7
  , 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967
  , 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13
  , 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85
  , 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3
  , 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070
  , 0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5
  , 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3
  , 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208
  , 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
  ]
