{-# LANGUAGE DeriveGeneric #-}
-- A recorded archive activation is distinct from the deterministic NativeInput
-- segments on either side. It needs the exact referenced source bytes to replay.
module Colony.SessionTrace
  ( ActivationRecord(..), makeActivationRecord, encodeActivationRecord
  , decodeActivationRecord, replayActivation ) where
import Colony.CheckpointLibrary
import Colony.Codec
import Colony.Codec.Value
import Colony.Session
import Colony.World
import Control.Monad(unless)
import qualified Data.ByteString as BS
import qualified Data.Set as S
import Data.Char(toLower)
import Data.Word(Word64)
import GHC.Generics(Generic)

data ActivationRecord=ActivationRecord
  { activationVersion :: !Word64, activationAction :: !String
  , activationLiveHash :: !BS.ByteString, activationSourceHash :: !BS.ByteString
  , activationTargetBranch :: !Word64, activationAuthority :: !String
  , activationTargetHash :: !BS.ByteString }
  deriving(Eq,Show,Generic)
instance ValueCodec ActivationRecord

ensure :: Bool -> String -> Either CodecError()
ensure condition=unless condition . Left . CodecError
mapError :: Show e=>Either e a->Either CodecError a
mapError=either(Left . CodecError . show)Right

validate :: ActivationRecord -> Either CodecError()
validate record=do
  ensure(activationVersion record==1) "Unknown activation record version"
  ensure(parseAction(activationAction record)/=Nothing) "Unknown activation action"
  ensure(all((==32).BS.length)[activationLiveHash record,activationSourceHash record,activationTargetHash record]) "Activation hash length"
  ensure(activationTargetBranch record>0) "Activation target branch zero"
  ensure(validUUIDv4(activationAuthority record)) "Activation authority must be canonical UUIDv4"

makeActivationRecord :: RestoreAction -> BS.ByteString -> BS.ByteString -> World -> Either CodecError ActivationRecord
makeActivationRecord action source liveHash target=do
  targetHash<-canonicalStateHash target
  let record=ActivationRecord 1(actionId action)liveHash(sha256 source)(branchId target)(worldAuthority target)targetHash
  validate record
  pure record
encodeActivationRecord :: ActivationRecord -> Either CodecError BS.ByteString
encodeActivationRecord record=validate record>>encodeValue record
decodeActivationRecord :: BS.ByteString -> Either CodecError ActivationRecord
decodeActivationRecord bytes=do
  record<-decodeValue bytes
  validate record
  pure record

replayActivation :: ActivationRecord -> World -> BS.ByteString -> Either CodecError World
replayActivation record live source=do
  validate record
  liveHash<-canonicalStateHash live
  ensure(liveHash==activationLiveHash record) "Activation live-source hash differs"
  ensure(sha256 source==activationSourceHash record) "Activation selected-checkpoint hash differs"
  ensure(not(S.member(activationAuthority record)(S.map(map toLower)(worldAuthorities live)))) "Activation authority reuses the current or historical live session"
  action<-maybe(Left(CodecError "Unknown action"))Right(parseAction(activationAction record))
  selected<-mapError(prepareCheckpoint action(activationTargetBranch record)source)
  ensure(worldId(preparedWorld selected)/=worldId live||branchId live/=activationTargetBranch record) "Activation must replace the current world/branch identity"
  target<-mapError(bindRecordedSession(activationAuthority record)(preparedSourceBranch selected)(preparedWorld selected))
  actualHash<-canonicalStateHash target
  ensure(actualHash==activationTargetHash record) "Activation target hash differs"
  pure target
