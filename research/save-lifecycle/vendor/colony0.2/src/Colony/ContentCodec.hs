{-# OPTIONS_GHC -Wno-orphans #-}
module Colony.ContentCodec(contentIdentity) where
import Colony.Content
import Colony.Units
import Colony.Codec.Value
import Colony.Codec.SHA256(sha256)
import qualified Data.ByteString as BS

instance ValueCodec Resource
instance ValueCodec ResourceDef
instance ValueCodec Recipe
instance ValueCodec Building
instance ValueCodec NaturalSource
instance ValueCodec Tech
instance ValueCodec Campaign
instance ValueCodec Content

-- Shared by recipe-start snapshots and checkpoint headers. This is a digest of
-- the same canonical validated content bytes, not a filename or mutable label.
contentIdentity :: Content -> Either String BS.ByteString
contentIdentity content=do
  validateContent content
  bytes<-either(Left . show)Right(encodeValue content)
  pure(sha256 bytes)
