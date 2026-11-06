module PureFall.Host.Save
  ( RestoredHost,
    HostSaveError (..),
    hostCheckpoint,
    restoreHostCheckpoint,
    restoredSession,
    restoredStudyIndex,
    restoredMoves,
    restoredMoveDebt,
    pathStepMicros,
  )
where

import PureFall.Core
import PureFall.Session
import PureFall.Time
import Text.Read (readMaybe)

data RestoredHost = RestoredHost Session Int [Command] FrameMicros deriving (Eq, Show)

data HostSaveError
  = HostSaveSyntax
  | HostSaveVersion
  | HostSessionError SessionError
  | HostStudyIndex
  | HostMoveDebt
  | HostMovePhase
  | HostMoveCommands
  | HostMoveContradiction
  | HostReplayState
  deriving (Eq, Show)

data HostEnvelope = HostEnvelope Int String Int [Command] Integer deriving (Read, Show)

pathStepMicros :: FrameMicros
pathStepMicros = frameMicros 80000

restoredSession :: RestoredHost -> Session
restoredSession (RestoredHost session _ _ _) = session

restoredStudyIndex :: RestoredHost -> Int
restoredStudyIndex (RestoredHost _ index _ _) = index

restoredMoves :: RestoredHost -> [Command]
restoredMoves (RestoredHost _ _ commands _) = commands

restoredMoveDebt :: RestoredHost -> FrameMicros
restoredMoveDebt (RestoredHost _ _ _ debt) = debt

hostCheckpoint :: Session -> Int -> [Command] -> FrameMicros -> Either HostSaveError String
hostCheckpoint session selected commands debt = do
  let savedSession = sessionCheckpoint session
      count = studyCount (sessionGame session)
      index = if count == 0 then 0 else selected `mod` count
      micros = if null commands then 0 else frameMicroCount debt
  _ <- either (Left . HostSessionError) Right (restoreSession savedSession)
  _ <- validateHost session index commands micros
  pure (show (HostEnvelope 1 savedSession index commands micros))

restoreHostCheckpoint :: String -> Either HostSaveError RestoredHost
restoreHostCheckpoint encoded
  | length encoded > 32000000 = Left HostSaveSyntax
  | otherwise = case readMaybe encoded of
      Nothing -> Left HostSaveSyntax
      Just (HostEnvelope version saved index commands debt)
        | version /= 1 -> Left HostSaveVersion
        | otherwise -> do
            session <- either (Left . HostSessionError) Right (restoreSession saved)
            validateHost session index commands debt

studyCount :: Game -> Int
studyCount game = if phase game == Studying then length (reachable game) else 0

validateHost :: Session -> Int -> [Command] -> Integer -> Either HostSaveError RestoredHost
validateHost session index commands debt
  | replayAvailable session = Left HostReplayState
  | index < 0 || (count == 0 && index /= 0) || (count > 0 && index >= count) = Left HostStudyIndex
  | debt < 0 || debt >= frameMicroCount pathStepMicros || (null commands && debt /= 0) = Left HostMoveDebt
  | not (null commands) && phase game /= Studying = Left HostMovePhase
  | length commands > 1024 = Left HostMoveCommands
  | not (validMoves game commands) = Left HostMoveContradiction
  | otherwise = Right (RestoredHost session index commands (frameMicros debt))
  where
    game = sessionGame session
    count = studyCount game

validMoves :: Game -> [Command] -> Bool
validMoves _ [] = True
validMoves game commands = case reverse commands of
  HardDrop : reversedPrefix -> checkPrefix game (reverse reversedPrefix)
  _ -> False
  where
    checkPrefix current [] =
      let (finished, cues) = admittedStep (TickInput [HardDrop] (Held Neutral False)) current
       in piecesLocked finished == piecesLocked current + 1 && any locked cues
    checkPrefix current (command : rest)
      | command `notElem` [MoveLeft, MoveRight, MoveDown, Clockwise, Counterclockwise] = False
      | otherwise =
          let (next, cues) = admittedStep (TickInput [command] (Held Neutral False)) current
              performed = if command `elem` [Clockwise, Counterclockwise] then Turned `elem` cues else Moved `elem` cues
           in performed && piecesLocked next == piecesLocked current && phase next == Studying && checkPrefix next rest
    locked cue = case cue of Locked _ -> True; _ -> False
