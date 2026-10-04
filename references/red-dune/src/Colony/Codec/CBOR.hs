{-# LANGUAGE BangPatterns #-}
-- | Restricted RFC 8949 core deterministic CBOR. Map keys are unsigned field
-- tags; all lengths are definite and every integer/length uses shortest form.
-- No floating point, semantic tags, indefinite items or duplicate map keys.
module Colony.Codec.CBOR
  ( CBOR(..), CodecError(..), DecodeLimits(..), defaultDecodeLimits
  , encodeCanonical, decodeCanonical, decodeCanonicalWith
  ) where

import Control.Monad (unless, when)
import Data.Bits ((.&.), (.|.), shiftR)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Builder as B
import qualified Data.ByteString.Lazy as BL
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Word (Word8, Word64)

newtype CodecError = CodecError String deriving (Eq, Show)

data CBOR = CInteger !Integer | CBytes !BS.ByteString | CText !T.Text
          | CArray ![CBOR] | CMap ![(Word64,CBOR)] | CBool !Bool | CNull
  deriving (Eq, Show)

-- These are parser budgets, not claims about a platform's available memory.
-- The foundation uses a conservative 1 MiB per-text cap in addition to the
-- specification's 1 GiB payload / 200,000 entities / 64 nesting bounds.
data DecodeLimits = DecodeLimits
  { maxPayloadBytes :: !Word64, maxContainerItems :: !Word64
  , maxNodes :: !Word64, maxDepth :: !Word64, maxTextBytes :: !Word64
  } deriving (Eq, Show)

defaultDecodeLimits :: DecodeLimits
defaultDecodeLimits = DecodeLimits (1024*1024*1024) 200000 4000000 64 (1024*1024)

failure :: String -> Either CodecError a
failure = Left . CodecError

-- Encoder checks the same bounds as the parser before returning a payload.
-- Length accounting uses Integer so that a malicious in-memory tree cannot
-- overflow an Int/Word64 length accumulator.
encodeCanonical :: CBOR -> Either CodecError BS.ByteString
encodeCanonical term = do
  (_,size) <- measure 1 term
  when (size > toInteger (maxPayloadBytes limits)) (failure "CBOR payload exceeds byte limit")
  pure (BL.toStrict (B.toLazyByteString (emit term)))
  where
    limits = defaultDecodeLimits
    measure :: Word64 -> CBOR -> Either CodecError (Integer,Integer)
    measure depth value = do
      when (depth > maxDepth limits) (failure "CBOR nesting limit exceeded")
      result@(nodes,size) <- case value of
        CInteger n -> do
          unless (n >= negate (2^(64::Int)) && n < 2^(64::Int)) (failure "CBOR integer outside 64-bit profile")
          pure (1,headSize (if n >= 0 then n else -1-n))
        CBytes bytes -> pure (1,headSize (toInteger (BS.length bytes))+toInteger (BS.length bytes))
        CText txt -> do
          let bytes = TE.encodeUtf8 txt
              len = toInteger (BS.length bytes)
          when (len > toInteger (maxTextBytes limits)) (failure "CBOR text exceeds byte limit")
          pure (1,headSize len+len)
        CArray xs -> do
          n <- checkedCount xs
          stats <- mapM (measure (depth+1)) xs
          pure (1+sum (map fst stats),headSize n+sum (map snd stats))
        CMap xs -> do
          n <- checkedCount xs
          unless (strictlyAscending (map fst xs)) (failure "CBOR map tags must be unique and ascending")
          stats <- mapM (measure (depth+1) . snd) xs
          pure (1+n+sum (map fst stats),headSize n+sum [headSize(toInteger k) | (k,_)<-xs]+sum (map snd stats))
        CBool _ -> pure (1,1)
        CNull -> pure (1,1)
      when (nodes > toInteger (maxNodes limits)) (failure "CBOR node limit exceeded")
      when (size > toInteger (maxPayloadBytes limits)) (failure "CBOR payload exceeds byte limit")
      pure result
    checkedCount xs = go 0 xs
      where
        go !n [] = Right n
        go !n (_:rest)
          | n >= toInteger (maxContainerItems limits) = failure "CBOR container item limit exceeded"
          | otherwise = go (n+1) rest

headSize :: Integer -> Integer
headSize n | n < 24 = 1 | n <= 0xff = 2 | n <= 0xffff = 3
           | n <= 0xffffffff = 5 | otherwise = 9

emitHead :: Word8 -> Word64 -> B.Builder
emitHead major n
  | n < 24 = B.word8 (major .|. fromIntegral n)
  | n <= 0xff = B.word8 (major .|. 24) <> B.word8 (fromIntegral n)
  | n <= 0xffff = B.word8 (major .|. 25) <> B.word16BE (fromIntegral n)
  | n <= 0xffffffff = B.word8 (major .|. 26) <> B.word32BE (fromIntegral n)
  | otherwise = B.word8 (major .|. 27) <> B.word64BE n

emit :: CBOR -> B.Builder
emit term = case term of
  CInteger n | n >= 0 -> emitHead 0 (fromInteger n)
             | otherwise -> emitHead 0x20 (fromInteger (-1-n))
  CBytes bytes -> emitHead 0x40 (fromIntegral (BS.length bytes)) <> B.byteString bytes
  CText txt -> let bytes = TE.encodeUtf8 txt in emitHead 0x60 (fromIntegral (BS.length bytes)) <> B.byteString bytes
  CArray xs -> emitHead 0x80 (fromIntegral (length xs)) <> foldMap emit xs
  CMap xs -> emitHead 0xa0 (fromIntegral (length xs)) <> foldMap (\(k,v)->emitHead 0 k <> emit v) xs
  CBool False -> B.word8 0xf4
  CBool True -> B.word8 0xf5
  CNull -> B.word8 0xf6

strictlyAscending :: Ord a => [a] -> Bool
strictlyAscending xs = and (zipWith (<) xs (drop 1 xs))

decodeCanonical :: BS.ByteString -> Either CodecError CBOR
decodeCanonical = decodeCanonicalWith defaultDecodeLimits

decodeCanonicalWith :: DecodeLimits -> BS.ByteString -> Either CodecError CBOR
decodeCanonicalWith limits bytes = do
  when (toInteger (BS.length bytes) > toInteger (maxPayloadBytes limits)) (failure "CBOR payload exceeds byte limit")
  (term,rest,_) <- parseTerm limits 1 (maxNodes limits) bytes
  unless (BS.null rest) (failure "CBOR trailing bytes")
  pure term

-- Only counters and bounded ByteString indices use machine Int. Authoritative
-- game arithmetic is never encoded in a machine-dependent Int.
parseTerm :: DecodeLimits -> Word64 -> Word64 -> BS.ByteString -> Either CodecError (CBOR,BS.ByteString,Word64)
parseTerm limits depth budget bytes = do
  when (depth > maxDepth limits) (failure "CBOR nesting limit exceeded")
  when (budget == 0) (failure "CBOR node limit exceeded")
  (major,n,rest) <- parseHead bytes
  let remaining = budget-1
      result x input = Right (x,input,remaining)
      takePayload bound = do
        when (n > bound) (failure "CBOR declared byte length exceeds limit")
        when (toInteger n > toInteger (BS.length rest)) (failure "CBOR truncated byte/text payload")
        pure (BS.splitAt (fromIntegral n) rest)
      checkContainer multiplier = do
        when (n > maxContainerItems limits) (failure "CBOR declared container length exceeds limit")
        when (toInteger n*multiplier > toInteger remaining) (failure "CBOR declared container exceeds remaining node budget")
        when (toInteger n*multiplier > toInteger (BS.length rest)) (failure "CBOR truncated container")
  case major of
    0 -> result (CInteger (toInteger n)) rest
    1 -> result (CInteger (-1-toInteger n)) rest
    2 -> do
      (payload,after) <- takePayload (maxPayloadBytes limits)
      result (CBytes payload) after
    3 -> do
      (payload,after) <- takePayload (maxTextBytes limits)
      txt <- either (const (failure "CBOR invalid UTF-8")) Right (TE.decodeUtf8' payload)
      result (CText txt) after
    4 -> do
      checkContainer 1
      (xs,after,left) <- arrayItems n remaining rest []
      pure (CArray xs,after,left)
    5 -> do
      checkContainer 2
      (xs,after,left) <- mapItems n remaining rest Nothing []
      pure (CMap xs,after,left)
    7 | n == 20 -> result (CBool False) rest
      | n == 21 -> result (CBool True) rest
      | n == 22 -> result CNull rest
    _ -> failure "CBOR unsupported major type, float, tag or simple value"
  where
    arrayItems 0 !left input acc = Right (reverse acc,input,left)
    arrayItems count !left input acc = do
      (x,after,left') <- parseTerm limits (depth+1) left input
      arrayItems (count-1) left' after (x:acc)
    mapItems 0 !left input _ acc = Right (reverse acc,input,left)
    mapItems count !left input previous acc = do
      when (left == 0) (failure "CBOR map key exceeds node budget")
      (major,key,afterKey) <- parseHead input
      unless (major == 0) (failure "CBOR map key is not an unsigned field tag")
      case previous of
        Just old -> unless (key > old) (failure "CBOR duplicate or noncanonical map tag order")
        Nothing -> pure ()
      (value,after,left') <- parseTerm limits (depth+1) (left-1) afterKey
      mapItems (count-1) left' after (Just key) ((key,value):acc)

parseHead :: BS.ByteString -> Either CodecError (Word8,Word64,BS.ByteString)
parseHead input = case BS.uncons input of
  Nothing -> failure "CBOR unexpected end of input"
  Just (first,rest) ->
    let major = first `shiftR` 5
        additional = first .&. 31
        extended count minimumValue = do
          when (BS.length rest < count) (failure "CBOR truncated integer/length")
          let (raw,after) = BS.splitAt count rest
              value = BS.foldl' (\acc x -> acc*256+fromIntegral x) 0 raw
          when (value < minimumValue) (failure "CBOR non-shortest integer/length")
          -- Major 7's additional 24..27 are unsupported simple/float types,
          -- even if their bit payload happens to resemble false/true/null.
          when (major == 7) (failure "CBOR floating point or extended simple value forbidden")
          pure (major,value,after)
    in case additional of
      n | n < 24 -> Right (major,fromIntegral n,rest)
      24 -> extended 1 24
      25 -> extended 2 256
      26 -> extended 4 65536
      27 -> extended 8 4294967296
      _ -> failure "CBOR indefinite length or reserved additional information"
