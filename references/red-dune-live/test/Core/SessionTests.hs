module Core.SessionTests (sessionTests) where

import Colony.Session
import Colony.Types (Epoch (..))
import Control.Monad (unless)
import Data.ByteString qualified as BS
import Data.Set qualified as S

must :: (Show e) => Either e a -> IO a
must = either (fail . show) pure

sessionTests :: IO ()
sessionTests = do
  factoryA <- newAuthorityFactoryWith (pure (BS.replicate 16 1))
  factoryB <- newAuthorityFactoryWith (pure (BS.replicate 16 2))
  a <- newSession factoryA S.empty >>= must
  b <- newSession factoryB S.empty >>= must
  let authorityA = "01010101-0101-4101-8101-010101010101"
      authorityB = "02020202-0202-4202-8202-020202020202"
  unless
    ( (sessionAuthority a, sessionEpoch a) == (authorityA, Epoch authorityA 1)
        && (sessionAuthority b, sessionEpoch b) == (authorityB, Epoch authorityB 1)
    )
    $ fail "issuer queries disagree with the independently specified UUID/epoch"
  a1 <- issueRequest a >>= must
  b1 <- issueRequest b >>= must
  a2 <- issueRequest a >>= must
  unless ([a1, b1, a2] == [RequestToken (Epoch authorityA 1) 1, RequestToken (Epoch authorityB 1) 1, RequestToken (Epoch authorityA 1) 2]) $
    fail "independent issuers duplicated a token, shared a counter, or changed epoch"
  repeated <- newSession factoryA S.empty
  unless (case repeated of Left AuthorityCollision -> True; _ -> False) $
    fail "factory reused an already-issued authority"
  knownFactory <- newAuthorityFactoryWith (pure (BS.replicate 16 2))
  excluded <- newSession knownFactory (S.singleton authorityB)
  unless (case excluded of Left AuthorityCollision -> True; _ -> False) $
    fail "known authority was not excluded before allocating another issuer"
  admitted <- newSession knownFactory S.empty >>= must
  firstAfterRefusal <- issueRequest admitted >>= must
  unless (firstAfterRefusal == RequestToken (Epoch authorityB 1) 1) $
    fail "refusing a known authority consumed an issuer or its request counter"
  overflowFactory <- newAuthorityFactoryWith (pure (BS.replicate 16 3))
  overflow <- newSessionStartingAt overflowFactory S.empty maxBound >>= must
  first <- issueRequest overflow
  second <- issueRequest overflow
  unless (first == Left RequestSerialExhausted && second == first) $
    fail "exhausted request counter wrapped or changed after refusal"
  putStrLn "Session: immutable UUID/epoch belong to one counter; independent tokens and terminal exhaustion"
