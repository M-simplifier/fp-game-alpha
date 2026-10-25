{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE UndecidableInstances #-}

-- | Versioned product/sum wire representation. Constructor ordinals and field
-- ordinals are part of this schema; source reorder requires a codec version.
module Colony.Codec.Value (ValueCodec (..), encodeValue, decodeValue) where

import Colony.Codec.CBOR
import Control.Monad (unless)
import Data.ByteString qualified as BS
import Data.Char (ord)
import Data.Map.Strict qualified as M
import Data.Proxy (Proxy (..))
import Data.Set qualified as S
import Data.Text qualified as T
import Data.Word (Word64)
import GHC.Generics

class ValueCodec a where
  toCBOR :: a -> Either CodecError CBOR
  fromCBOR :: CBOR -> Either CodecError a
  default toCBOR :: (Generic a, GConstructors (Rep a)) => a -> Either CodecError CBOR
  toCBOR value = do
    (constructor, fields) <- gEncode (from value)
    pure (CMap [(0, CInteger (toInteger constructor)), (1, CMap (zip [0 ..] fields))])
  default fromCBOR :: (Generic a, GConstructors (Rep a)) => CBOR -> Either CodecError a
  fromCBOR (CMap [(0, CInteger tag), (1, CMap fields)]) = do
    unless (tag >= 0 && tag <= toInteger (maxBound :: Word64)) (bad "Invalid constructor tag")
    unless (map fst fields == take (length fields) [0 ..]) (bad "Unknown or missing mandatory field tag")
    to <$> gDecode (fromInteger tag) (map snd fields)
  fromCBOR _ = bad "Expected tagged record with constructor and field map"

bad :: String -> Either CodecError a
bad = Left . CodecError

encodeValue :: (ValueCodec a) => a -> Either CodecError BS.ByteString
encodeValue value = toCBOR value >>= encodeCanonical

decodeValue :: (ValueCodec a) => BS.ByteString -> Either CodecError a
decodeValue bytes = decodeCanonical bytes >>= fromCBOR

class GConstructors f where
  constructorCount :: proxy f -> Word64
  gEncode :: f p -> Either CodecError (Word64, [CBOR])
  gDecode :: Word64 -> [CBOR] -> Either CodecError (f p)

instance (GConstructors f) => GConstructors (M1 D meta f) where
  constructorCount _ = constructorCount (Proxy :: Proxy f)
  gEncode (M1 x) = gEncode x
  gDecode tag fields = M1 <$> gDecode tag fields

instance (GConstructors a, GConstructors b) => GConstructors (a :+: b) where
  constructorCount _ = constructorCount (Proxy :: Proxy a) + constructorCount (Proxy :: Proxy b)
  gEncode (L1 x) = gEncode x
  gEncode (R1 x) = do
    (tag, fields) <- gEncode x
    pure (constructorCount (Proxy :: Proxy a) + tag, fields)
  gDecode tag fields
    | tag < count = L1 <$> gDecode tag fields
    | otherwise = R1 <$> gDecode (tag - count) fields
    where
      count = constructorCount (Proxy :: Proxy a)

instance (GFields f) => GConstructors (M1 C meta f) where
  constructorCount _ = 1
  gEncode (M1 x) = (\fields -> (0, fields)) <$> gFields x
  gDecode tag fields = do
    unless (tag == 0) (bad "Unknown mandatory constructor tag")
    (value, rest) <- gReadFields fields
    unless (null rest) (bad "Unknown mandatory field tag")
    pure (M1 value)

class GFields f where
  gFields :: f p -> Either CodecError [CBOR]
  gReadFields :: [CBOR] -> Either CodecError (f p, [CBOR])

instance GFields U1 where
  gFields U1 = Right []
  gReadFields xs = Right (U1, xs)

instance (GFields a, GFields b) => GFields (a :*: b) where
  gFields (a :*: b) = (++) <$> gFields a <*> gFields b
  gReadFields xs = do
    (a, rest) <- gReadFields xs
    (b, after) <- gReadFields rest
    pure (a :*: b, after)

instance (GFields f) => GFields (M1 S meta f) where
  gFields (M1 x) = gFields x
  gReadFields xs = do
    (value, rest) <- gReadFields xs
    pure (M1 value, rest)

instance (ValueCodec a) => GFields (K1 index a) where
  gFields (K1 value) = (: []) <$> toCBOR value
  gReadFields [] = bad "Missing mandatory field tag"
  gReadFields (x : xs) = do
    value <- fromCBOR x
    pure (K1 value, xs)

instance ValueCodec Word64 where
  toCBOR = Right . CInteger . toInteger
  fromCBOR (CInteger n) | n >= 0 && n <= toInteger (maxBound :: Word64) = Right (fromInteger n)
  fromCBOR _ = bad "Expected unsigned 64-bit integer"

instance ValueCodec Integer where
  toCBOR n
    | n >= negate (2 ^ (64 :: Int)) && n < 2 ^ (64 :: Int) = Right (CInteger n)
    | otherwise = bad "Integer outside signed/unsigned 64-bit CBOR profile"
  fromCBOR (CInteger n) = Right n
  fromCBOR _ = bad "Expected integer"

instance ValueCodec Bool where
  toCBOR = Right . CBool
  fromCBOR (CBool b) = Right b
  fromCBOR _ = bad "Expected Boolean"

instance ValueCodec BS.ByteString where
  toCBOR = Right . CBytes
  fromCBOR (CBytes bytes) = Right bytes
  fromCBOR _ = bad "Expected byte string"

instance {-# OVERLAPPING #-} ValueCodec String where
  toCBOR value = do
    unless (all (\ch -> ord ch < 0xd800 || ord ch > 0xdfff) value) (bad "String contains invalid Unicode surrogate")
    pure (CText (T.pack value))
  fromCBOR (CText txt) = Right (T.unpack txt)
  fromCBOR _ = bad "Expected UTF-8 text"

instance {-# OVERLAPPABLE #-} (ValueCodec a) => ValueCodec [a] where
  toCBOR values = CArray <$> mapM toCBOR values
  fromCBOR (CArray values) = mapM fromCBOR values
  fromCBOR _ = bad "Expected ordered array"

instance (ValueCodec a) => ValueCodec (Maybe a)

instance (ValueCodec a, ValueCodec b) => ValueCodec (a, b)

-- An ID collection is a stable-ID ascending array of key/value arrays, never
-- a CBOR map (whose keys in this profile are reserved for unsigned field tags).
instance (Ord k, ValueCodec k, ValueCodec a) => ValueCodec (M.Map k a) where
  toCBOR values = CArray <$> mapM pair (M.toAscList values)
    where
      pair (key, value) = CArray <$> sequence [toCBOR key, toCBOR value]
  fromCBOR (CArray values) = do
    pairs <- mapM pair values
    let keys = map fst pairs
    unless (and (zipWith (<) keys (drop 1 keys))) (bad "Collection IDs are duplicated or not in stable ascending order")
    pure (M.fromDistinctAscList pairs)
    where
      pair (CArray [key, value]) = (,) <$> fromCBOR key <*> fromCBOR value
      pair _ = bad "Expected collection key/value pair"
  fromCBOR _ = bad "Expected stable-ID collection array"

instance (Ord a, ValueCodec a) => ValueCodec (S.Set a) where
  toCBOR values = CArray <$> mapM toCBOR (S.toAscList values)
  fromCBOR (CArray values) = do
    xs <- mapM fromCBOR values
    unless (and (zipWith (<) xs (drop 1 xs))) (bad "Set IDs are duplicated or not in stable ascending order")
    pure (S.fromDistinctAscList xs)
  fromCBOR _ = bad "Expected stable-ID set array"
