{-# LANGUAGE DeriveGeneric #-}

module Colony.RNG
  ( Rng (..),
    RngStreams (..),
    RngStream (..),
    DrawResult (..),
    PendingRandomDraw (..),
    initialRng,
    nextWord,
    drawBelow,
    drawFromStream,
    resumeRandomDraw,
    validateRng,
    validateRngStreams,
    drawBelowWith,
  )
where

import Control.DeepSeq (NFData)
import Data.Binary (Binary)
import Data.Bits (shiftL, shiftR, xor)
import Data.Word (Word64)
import GHC.Generics (Generic)

-- RDF-RNG-1. Only the xorshift and output multiplier explicitly wrap mod 2^64.
-- Draw count never wraps; exhaustion is a fault before the attempted draw.
data Rng = Rng
  { rngState :: !Word64,
    rngDrawCount :: !Word64
  }
  deriving (Eq, Show, Read, Generic)

instance NFData Rng

instance Binary Rng

data RngStreams = RngStreams
  { rngOriginalSeed :: !Word64,
    rngNormalizedSeed :: !Word64,
    rngSeedWasZero :: !Bool,
    weatherRng :: !Rng,
    immigrationRng :: !Rng,
    decorationRng :: !Rng
  }
  deriving (Eq, Show, Read, Generic)

instance NFData RngStreams

instance Binary RngStreams

data RngStream = WeatherStream | ImmigrationStream | MapDecorationStream
  deriving (Eq, Ord, Show, Read, Enum, Bounded, Generic)

instance NFData RngStream

instance Binary RngStream

-- Pending carries the same bound. Returned Rng already includes the consumed
-- rejection draws and must be persisted, never rewound on the next boundary.
data DrawResult = Drawn !Word64 | Pending !Word64
  deriving (Eq, Show, Read, Generic)

instance NFData DrawResult

instance Binary DrawResult

-- The simulation supplies a serializable domain continuation, rather than a
-- closure. Store this alongside RngStreams on Pending and remove it on Drawn.
data PendingRandomDraw continuation = PendingRandomDraw
  { pendingBound :: !Word64,
    pendingStream :: !RngStream,
    pendingContinuation :: !continuation
  }
  deriving (Eq, Show, Read, Generic)

instance (NFData continuation) => NFData (PendingRandomDraw continuation)

instance (Binary continuation) => Binary (PendingRandomDraw continuation)

initialRng :: Word64 -> RngStreams
initialRng original =
  RngStreams
    original
    seed
    (original == 0)
    (stream 0x9E3779B97F4A7C15)
    (stream 0xD1B54A32D192ED03)
    (stream 0x94D049BB133111EB)
  where
    seed = nonzero original
    stream salt = Rng (nonzero (seed `xor` salt)) 0
    nonzero 0 = 1
    nonzero x = x

validateRng :: Rng -> Either String ()
validateRng r
  | rngState r == 0 = Left "RngZeroState"
  | otherwise = Right ()

validateRngStreams :: RngStreams -> Either String ()
validateRngStreams streams = do
  let original = rngOriginalSeed streams
      normalized = if original == 0 then 1 else original
  if rngNormalizedSeed streams /= normalized || rngSeedWasZero streams /= (original == 0)
    then Left "RngSeedNormalizationMismatch"
    else mapM_ validateRng [weatherRng streams, immigrationRng streams, decorationRng streams]

nextWord :: Rng -> Either String (Word64, Rng)
nextWord r = do
  validateRng r
  if rngDrawCount r == maxBound
    then Left "RngDrawCountExhausted"
    else
      let x1 = rngState r `xor` (rngState r `shiftR` 12)
          x2 = x1 `xor` (x1 `shiftL` 25)
          x3 = x2 `xor` (x2 `shiftR` 27)
          output = x3 * 2685821657736338717
       in Right (output, Rng x3 (rngDrawCount r + 1))

drawBelow :: Word64 -> Rng -> Either String (DrawResult, Rng)
drawBelow = drawBelowWith nextWord

-- | Shared bounded rejection sampler; step injection makes the rare 32-draw
-- suspension and resumption paths deterministically testable. The production
-- entry point above always supplies RDF-RNG-1's nextWord.
drawBelowWith :: (state -> Either String (Word64, state)) -> Word64 -> state -> Either String (DrawResult, state)
drawBelowWith step n initial
  | n == 0 = Left "RngEmptyRange"
  | otherwise = go (32 :: Word64) initial
  where
    width = toInteger n
    modulus = 18446744073709551616 :: Integer
    limit = modulus - modulus `mod` width
    go 0 state = Right (Pending n, state)
    go budget state = do
      (output, next) <- step state
      if toInteger output < limit
        then Right (Drawn (fromInteger (toInteger output `mod` width)), next)
        else go (budget - 1) next

drawFromStream :: Word64 -> RngStream -> RngStreams -> Either String (DrawResult, RngStreams)
drawFromStream bound stream streams = do
  validateRngStreams streams
  case stream of
    WeatherStream -> do
      (result, rng) <- drawBelow bound (weatherRng streams)
      pure (result, streams {weatherRng = rng})
    ImmigrationStream -> do
      (result, rng) <- drawBelow bound (immigrationRng streams)
      pure (result, streams {immigrationRng = rng})
    MapDecorationStream -> do
      (result, rng) <- drawBelow bound (decorationRng streams)
      pure (result, streams {decorationRng = rng})

resumeRandomDraw :: PendingRandomDraw continuation -> RngStreams -> Either String (DrawResult, RngStreams)
resumeRandomDraw pending = drawFromStream (pendingBound pending) (pendingStream pending)
