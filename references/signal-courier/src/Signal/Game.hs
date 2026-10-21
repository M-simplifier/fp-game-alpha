{-# LANGUAGE TypeFamilies #-}

module Signal.Game
  ( Courier (..),
    Rider (..),
    Command (..),
    Direction (..),
    Phase (..),
    Event (..),
    Session,
    Level,
    Room (..),
    Platform (..),
    PlayerView (..),
    defaultLevel,
    rooms,
    initial,
    advance,
    view,
    winningTrace,
    invariant,
    decodeCommand,
  )
where

import Data.List qualified as List
import Game.Arena hiding (view)
import Game.Transition

data Direction = Still | West | East deriving (Eq, Show)

data Command = Tick Direction Bool | Retry | Restart deriving (Eq, Show)

data Phase = Delivering | Complete | Exhausted deriving (Eq, Show)

data Event = Delivered Int | Fell | Finished | Retried deriving (Eq, Show)

data Platform = Platform {leftEdge :: Int, rightEdge :: Int, surface :: Int} deriving (Eq, Show)

data Room = Room {roomName :: String, platforms :: [Platform], beaconX :: Int} deriving (Eq, Show)

-- Closed authored level: no public unchecked constructor or Read instance.
newtype Level = Level [Room] deriving (Eq, Show)

rooms :: Level -> [Room]
rooms (Level rs) = rs

defaultLevel :: Level
defaultLevel = Level [makeRoom 0 "Canal steps", makeRoom 600 "Rooftop post", makeRoom 1200 "Last light"]
  where
    makeRoom offset name =
      Room
        name
        [ Platform offset (offset + 220) 300,
          Platform (offset + 270) (offset + 600) 300,
          Platform (offset + 100) (offset + 180) 252,
          Platform (offset + 280) (offset + 380) 238,
          Platform (offset + 390) (offset + 470) 194
        ]
        (offset + 540)

data Session = Session
  { positionX :: !Int,
    positionY :: !Int,
    velocityY :: !Int,
    grounded :: !Bool,
    delivered :: !Int,
    ticks :: !Int,
    falls :: !Int,
    stamps :: ![Int],
    phase :: !Phase
  }
  deriving (Eq, Show)

data PlayerView = PlayerView
  { courierX :: Int,
    courierY :: Int,
    onGround :: Bool,
    parcelsDelivered :: Int,
    elapsedTicks :: Int,
    fallCount :: Int,
    collectedStamps :: [Int],
    status :: Phase
  }
  deriving (Eq, Show)

view :: Session -> PlayerView
view s =
  PlayerView
    { courierX = positionX s,
      courierY = positionY s,
      onGround = grounded s,
      parcelsDelivered = delivered s,
      elapsedTicks = ticks s,
      fallCount = falls s,
      collectedStamps = stamps s,
      status = phase s
    }

initial :: Session
initial = Session 40 300 0 True 0 0 0 [] Delivering

checkpointX :: Int -> Int
checkpointX count = if count == 0 then 40 else (count - 1) * 600 + 540

retry :: Session -> Session
retry s = s {positionX = checkpointX (delivered s), positionY = 300, velocityY = 0, grounded = True, ticks = 0, phase = Delivering}

advance :: Command -> Session -> (Session, [Event])
advance Restart _ = (initial, [])
advance Retry s = if phase s == Complete then (s, []) else (retry s, [Retried])
advance (Tick direction jump) s
  | phase s /= Delivering = (s, [])
  | otherwise = runTick direction jump s

runTick :: Direction -> Bool -> Session -> (Session, [Event])
runTick direction jump previous =
  let (moved, rawY) = resolveMotion direction jump previous
   in finishTick $
        if rawY > 380
          then recordFall previous
          else deliverAtBeacon previous (collectStamps previous moved)

-- Return the post-movement state alongside rawY, which determines falling
-- before any landing surface clamps the player's height.
resolveMotion :: Direction -> Bool -> Session -> (Session, Int)
resolveMotion direction jump previous =
  let x = max 8 (min 1792 (positionX previous + horizontalStep direction))
      vy = if jump && grounded previous then -12 else min 14 (velocityY previous + 1)
      rawY = positionY previous + vy
      landings =
        [ surface platform
        | room <- rooms defaultLevel,
          platform <- platforms room,
          x >= leftEdge platform,
          x <= rightEdge platform,
          vy >= 0,
          positionY previous <= surface platform,
          rawY >= surface platform
        ]
      landed = not (null landings)
      y = List.foldl' min rawY landings
      moved =
        previous
          { positionX = x,
            positionY = y,
            velocityY = if landed then 0 else vy,
            grounded = landed,
            ticks = ticks previous + 1
          }
   in (moved, rawY)

horizontalStep :: Direction -> Int
horizontalStep Still = 0
horizontalStep West = -4
horizontalStep East = 4

collectStamps :: Session -> Session -> Session
collectStamps previous moved =
  moved {stamps = filter (\index -> index `elem` stamps previous || index `elem` touched) [0 .. 2]}
  where
    touched =
      [ index
      | index <- [0 .. 2],
        abs (positionX moved - (index * 600 + 430)) <= 14,
        abs (positionY moved - 194) <= 18
      ]

recordFall :: Session -> (Session, [Event])
recordFall previous =
  ( (retry previous)
      { ticks = ticks previous + 1,
        falls = min 9999 (falls previous + 1)
      },
    [Fell]
  )

deliverAtBeacon :: Session -> Session -> (Session, [Event])
deliverAtBeacon previous moved
  | abs (positionX moved - target) <= 12 && abs (positionY moved - 300) <= 8 =
      let count = delivered previous + 1
          won = count == 3
       in ( moved {delivered = count, phase = if won then Complete else Delivering},
            [Delivered count] ++ [Finished | won]
          )
  | otherwise = (moved, [])
  where
    target = delivered previous * 600 + 540

-- Execute the last playable tick first; a delivery on the deadline wins.
finishTick :: (Session, [Event]) -> (Session, [Event])
finishTick (next, events)
  | ticks next >= 10800 && phase next == Delivering = (next {phase = Exhausted}, events)
  | otherwise = (next, events)

invariant :: Session -> Bool
invariant s =
  positionX s >= 8
    && positionX s <= 1792
    && positionY s >= 0
    && positionY s <= 380
    && velocityY s >= -12
    && velocityY s <= 14
    && delivered s >= 0
    && delivered s <= 3
    && ticks s >= 0
    && ticks s <= 10800
    && falls s >= 0
    && falls s <= 9999
    && all (`elem` [0 .. 2]) (stamps s)
    && (phase s /= Complete || delivered s == 3)

-- Constructive default-level witness; each command is executed by advance.
winningTrace :: [Command]
winningTrace =
  concat
    [ replicate 37 (Tick East False),
      [Tick East True],
      replicate 149 (Tick East False),
      [Tick East True],
      replicate 149 (Tick East False),
      [Tick East True],
      replicate 100 (Tick East False)
    ]

data Courier = Courier deriving (Eq, Show)

data Rider = Rider deriving (Eq, Show)

instance Machine Courier where
  type State Courier = Session
  type Input Courier = Command
  type Output Courier = [Event]
  machine _ = Step advance

instance Arena Courier where
  type Agent Courier = Rider
  type Action Courier = Command
  type Context Courier = ()
  type View Courier = PlayerView
  type Rejection Courier = String
  observe _ _ = view
  admit _ () choices _ = case submissions choices of
    [(Rider, command)] -> Right command
    _ -> Left "Exactly one courier input is required"

decodeCommand :: Int -> Maybe Command
decodeCommand code = case code of
  0 -> Just (Tick Still False)
  1 -> Just (Tick West False)
  2 -> Just (Tick East False)
  3 -> Just (Tick Still True)
  4 -> Just (Tick West True)
  5 -> Just (Tick East True)
  6 -> Just Retry
  7 -> Just Restart
  _ -> Nothing
