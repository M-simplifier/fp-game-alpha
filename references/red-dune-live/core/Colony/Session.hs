{-# LANGUAGE CPP #-}
{-# LANGUAGE ForeignFunctionInterface #-}

-- Concrete shell identity/request issuer. This is IO/session state, never
-- gameplay RNG or data restored from a checkpoint. UUID freshness remains an
-- explicit probabilistic OS-entropy assumption; counters never silently wrap.
module Colony.Session
  ( AuthorityFactory,
    Session,
    SessionError (..),
    RequestToken (..),
    newAuthorityFactory,
    newAuthorityFactoryWith,
    newSession,
    newSessionStartingAt,
    issueRequest,
    sessionAuthority,
    sessionEpoch,
    requestSerial,
    tokenText,
    uuidV4FromBytes,
    validUUIDv4,
    worldAuthorities,
    activateWorldSession,
    bindPreparedSession,
    bindRecordedSession,
  )
where

import Colony.Codec (canonicalWorldBytes)
import Colony.Types (Epoch (..))
import Colony.World
import Control.Concurrent.MVar (MVar, modifyMVar, newMVar)
import Control.Exception (IOException, try)
import Control.Monad (unless)
import Data.Bits ((.&.), (.|.))
import Data.ByteString qualified as BS
import Data.Char (toLower)
import Data.Map.Strict qualified as M
import Data.Set qualified as S
import Data.Word (Word64, Word8)
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Ptr (Ptr, castPtr)
#ifdef mingw32_HOST_OS
import Data.Int (Int32)
import Data.Word (Word32)
import Foreign.Ptr (nullPtr)

#if defined(i386_HOST_ARCH)
foreign import stdcall safe "BCryptGenRandom" os_random :: Ptr () -> Ptr Word8 -> Word32 -> Word32 -> IO Int32
#else
foreign import ccall safe "BCryptGenRandom" os_random :: Ptr () -> Ptr Word8 -> Word32 -> Word32 -> IO Int32
#endif
#else
import Foreign.C.Error (throwErrnoIfMinus1Retry)
import Foreign.C.Types (CSize (..), CUInt (..))
import Foreign.Ptr (plusPtr)
import System.Posix.Types (CSsize (..))

foreign import ccall safe "getrandom" os_getrandom :: Ptr Word8 -> CSize -> CUInt -> IO CSsize
#endif

data SessionError
  = EntropyUnavailable String
  | AuthorityCollision
  | InvalidSerialStart
  | RequestSerialExhausted
  | InvalidSessionSource String
  | InvalidSessionBranch
  deriving (Eq, Show)

data AuthorityFactory = AuthorityFactory (IO BS.ByteString) (MVar (S.Set String))

data Session = Session {sessionAuthority :: !String, sessionEpoch :: !Epoch, serialCell :: !(MVar Word64)}

data RequestToken = RequestToken !Epoch !Word64 deriving (Eq, Ord, Show)

requestSerial :: RequestToken -> Word64
requestSerial (RequestToken _ serial) = serial

tokenText :: RequestToken -> String
tokenText (RequestToken (Epoch authority counter) serial) = authority ++ ":" ++ show counter ++ ":" ++ show serial

osEntropy16 :: IO BS.ByteString
osEntropy16 = allocaBytes 16 $ \pointer -> do
#ifdef mingw32_HOST_OS
  status <- os_random nullPtr pointer 16 2
  unless (status == 0) (ioError (userError "Windows system entropy unavailable"))
#else
  let go offset
        | offset == 16 = pure ()
        | otherwise = do
            count <- throwErrnoIfMinus1Retry "getrandom" (os_getrandom (pointer `plusPtr` offset) (fromIntegral (16 - offset)) 0)
            if count <= 0 || toInteger count > toInteger (16 - offset) then ioError (userError "getrandom short/invalid progress") else go (offset + fromIntegral count)
  go 0
#endif
  BS.packCStringLen (castPtr pointer, 16)

newAuthorityFactory :: IO AuthorityFactory
newAuthorityFactory = newAuthorityFactoryWith osEntropy16

newAuthorityFactoryWith :: IO BS.ByteString -> IO AuthorityFactory
newAuthorityFactoryWith source = AuthorityFactory source <$> newMVar S.empty

uuidV4FromBytes :: BS.ByteString -> Either SessionError String
uuidV4FromBytes bytes = do
  unless (BS.length bytes == 16) (Left (EntropyUnavailable "UUID entropy must contain exactly16 bytes"))
  let changed = BS.zipWith (\index byte -> if index == 6 then (byte .&. 15) .|. 64 else if index == 8 then (byte .&. 63) .|. 128 else byte) (BS.pack [0 .. 15]) bytes
      hex = concatMap (\byte -> [digits !! fromIntegral (byte `div` 16), digits !! fromIntegral (byte `mod` 16)]) changed
      digits = "0123456789abcdef"
  pure (take 8 hex ++ "-" ++ take 4 (drop 8 hex) ++ "-" ++ take 4 (drop 12 hex) ++ "-" ++ take 4 (drop 16 hex) ++ "-" ++ drop 20 hex)

validUUIDv4 :: String -> Bool
validUUIDv4 text = length text == 36 && text !! 14 == '4' && text !! 19 `elem` "89ab" && all valid (zip [0 :: Integer ..] text)
  where
    valid (index, char) = if index `elem` [8, 13, 18, 23] then char == '-' else char `elem` "0123456789abcdef"

newSession :: AuthorityFactory -> S.Set String -> IO (Either SessionError Session)
newSession factory known = newSessionStartingAt factory known 1

-- A non-default starting number is useful for an executable overflow fixture.
-- It still allocates a fresh authority; an existing Session has no reset API.
newSessionStartingAt :: AuthorityFactory -> S.Set String -> Word64 -> IO (Either SessionError Session)
newSessionStartingAt _ _ 0 = pure (Left InvalidSerialStart)
newSessionStartingAt (AuthorityFactory entropy usedCell) known first = modifyMVar usedCell $ \used -> do
  found <- findFresh (16 :: Integer) (S.union used (S.map (map toLower) known))
  case found of
    Left failure -> pure (used, Left failure)
    Right authority -> do
      counter <- newMVar first
      pure (S.insert authority used, Right (Session authority (Epoch authority 1) counter))
  where
    findFresh 0 _ = pure (Left AuthorityCollision)
    findFresh remaining seen = do
      result <- try entropy :: IO (Either IOException BS.ByteString)
      case result of
        Left err -> pure (Left (EntropyUnavailable (show err)))
        Right bytes -> case uuidV4FromBytes bytes of
          Left failure -> pure (Left failure)
          Right authority
            | S.member authority seen -> findFresh (remaining - 1) seen
            | otherwise -> pure (Right authority)

issueRequest :: Session -> IO (Either SessionError RequestToken)
issueRequest session = modifyMVar (serialCell session) $ \serial ->
  if serial == maxBound
    then pure (serial, Left RequestSerialExhausted)
    else pure (serial + 1, Right (RequestToken (sessionEpoch session) serial))

worldAuthorities :: World -> S.Set String
worldAuthorities world = S.fromList (worldAuthority world : [authority | Participant _ (Epoch authority _) <- M.elems (worldParticipants world)] ++ [authority | ((_, Epoch authority _), _) <- M.toList (worldHighWater world)])

-- An interactive activation is distinct from exact archive decode/replay.
-- Preserve gameplay quantities/RNG/progress/history; rotate only session/branch
-- identity and pause an Active world. An Abandoned world is never resurrected.
activateWorldSession :: Session -> Word64 -> World -> Either SessionError World
activateWorldSession session branch original = do
  _ <- either (Left . InvalidSessionSource . show) Right (canonicalWorldBytes original)
  bindPreparedSession session (branchId original) (original {branchId = branch})

-- Prepared migrations already carry a newly allocated branch. The original
-- source branch is explicit so no intermediate branch is silently accepted.
bindPreparedSession :: Session -> Word64 -> World -> Either SessionError World
bindPreparedSession session = bindRecordedSession (sessionAuthority session)

-- Pure reconstruction for an archived, explicit activation record only. This
-- returns a World, never a Session issuer, so it cannot reset/reuse tickets.
bindRecordedSession :: String -> Word64 -> World -> Either SessionError World
bindRecordedSession authority sourceBranch prepared = do
  _ <- either (Left . InvalidSessionSource . show) Right (canonicalWorldBytes prepared)
  unless (sourceBranch > 0 && branchId prepared > 0 && branchId prepared /= sourceBranch) (Left InvalidSessionBranch)
  unless (validUUIDv4 (authority) && not (S.member (authority) (S.map (map toLower) (worldAuthorities prepared)))) (Left AuthorityCollision)
  unless (maybe False ((== OwnerRole) . participantRole) (M.lookup 1 (worldParticipants prepared))) (Left (InvalidSessionSource "Local activation requires saved controller1 Owner role"))
  case worldMode prepared of { Faulted _ -> Left (InvalidSessionSource "Faulted worlds are not activatable"); _ -> Right () }
  let participants = M.map (\participant -> participant {participantEpoch = Epoch authority 1}) (worldParticipants prepared)
      newKeys = M.fromList [((controller, Epoch authority 1), 0) | controller <- M.keys participants]
      target =
        prepared
          { worldAuthority = authority,
            worldParticipants = participants,
            worldHighWater = M.union newKeys (worldHighWater prepared),
            worldMode = if worldMode prepared == Active then Paused else worldMode prepared
          }
  _ <- either (Left . InvalidSessionSource . show) Right (canonicalWorldBytes target)
  pure target
