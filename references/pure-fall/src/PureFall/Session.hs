module PureFall.Session
  ( Session,
    start,
    sessionGame,
    pendingEdges,
    debtUnits,
    sessionCues,
    traceInputs,
    advanceFrame,
    tickSession,
    rewindPiece,
    restartReplay,
    replayAvailable,
    replayNext,
    commitLanding,
    sessionCheckpoint,
    restoreSession,
    SessionError (..),
  )
where

import Game.Arena qualified as Arena
import PureFall.Core
import PureFall.Time
import Text.Read (readMaybe)

data Session = Session
  { internalGame :: Game,
    internalDebt :: Integer,
    internalPending :: [Command],
    internalHeld :: Held,
    internalHistory :: [(Game, Int)],
    internalTrace :: [TickInput],
    internalCues :: [Cue],
    internalInitial :: Game,
    internalReplay :: [TickInput],
    internalFocused :: Bool,
    internalPieceStart :: (Game, Int)
  }
  deriving (Eq, Show)

start :: Game -> Session
start game = Session game 0 [] (Held Neutral False) [] [] [] game [] True (game, 0)

sessionGame :: Session -> Game
sessionGame = internalGame

pendingEdges :: Session -> [Command]
pendingEdges = internalPending

debtUnits :: Session -> DebtUnits
debtUnits = debtUnitsFromCount . internalDebt

sessionCues :: Session -> [Cue]
sessionCues = internalCues

traceInputs :: Session -> [TickInput]
traceInputs = reverse . internalTrace

tickSession :: TickInput -> Session -> (Session, [Cue])
tickSession input session = case Arena.play PureFall () (Arena.singleton Player input) (internalGame session) of
  Left _ -> (session {internalCues = []}, [])
  Right (after, cues) ->
    let before = internalGame session
        completedPiece = piecesLocked after > piecesLocked before
        history = if completedPiece then take 100 (internalPieceStart session : internalHistory session) else internalHistory session
        nextTrace = input : internalTrace session
        pieceStart = if completedPiece then (after, length nextTrace) else internalPieceStart session
     in (session {internalGame = after, internalHistory = history, internalTrace = nextTrace, internalCues = cues, internalPieceStart = pieceStart}, cues)

-- Debt is measured in microseconds * 60; one semantic tick costs 1,000,000.
-- All owed ticks run. A zero-tick frame retains its ordered press edges.
advanceFrame :: FrameMicros -> [Command] -> Held -> Bool -> Session -> (Session, [Cue])
advanceFrame elapsed commands held focused session
  | not focused =
      let current = sessionGame session
          (next, cues) =
            if phase current `elem` [Falling, Studying]
              then tickSession (TickInput [Pause] (Held Neutral False)) session
              else (session, [])
       in (next {internalPending = [], internalHeld = Held Neutral False, internalFocused = False, internalCues = cues}, cues)
  | Pause `elem` commands || Study `elem` commands =
      let boundary = if Pause `elem` commands then Pause else Study
          (next, cues) = tickSession (TickInput [boundary] (Held Neutral False)) session
       in (next {internalPending = [], internalHeld = Held Neutral False, internalFocused = True}, cues)
  | phase (sessionGame session) == Studying =
      let (next, cues) = tickSession (TickInput commands (Held Neutral False)) session
       in (next {internalFocused = True, internalPending = []}, cues)
  | phase (sessionGame session) /= Falling = (session {internalPending = [], internalHeld = Held Neutral False, internalFocused = True, internalCues = []}, [])
  | otherwise =
      runOwed
        ( session
            { internalDebt = internalDebt session + frameMicroCount elapsed * 60,
              internalPending = internalPending session ++ commands,
              internalHeld = held,
              internalFocused = True
            }
        )
        []
  where
    runOwed state cues
      | internalDebt state < 1000000 = (state {internalCues = cues}, cues)
      | otherwise =
          let (edges, remainingEdges) = splitAt 32 (internalPending state)
              input = TickInput edges (internalHeld state)
              (next, more) = tickSession input state
              spent = next {internalDebt = internalDebt state - 1000000, internalPending = remainingEdges}
           in runOwed spent (cues ++ more)

rewindPiece :: Session -> Session
rewindPiece session = case internalHistory session of
  [] -> session
  (_, traceLength) : _ ->
    let truncated = drop (length (internalTrace session) - traceLength) (internalTrace session)
        rebuilt = foldl' (\current input -> fst (tickSession input current)) (start (internalInitial session)) (reverse truncated)
     in rebuilt {internalCues = [], internalFocused = internalFocused session}

restartReplay :: Session -> Session
restartReplay session = (start (internalInitial session)) {internalReplay = traceInputs session}

replayAvailable :: Session -> Bool
replayAvailable = not . null . internalReplay

replayNext :: Session -> (Session, [Cue])
replayNext session = case internalReplay session of
  [] -> (session, [])
  first : rest -> let (next, cues) = tickSession first session in (next {internalReplay = rest}, cues)

commitLanding :: Landing -> Session -> (Session, [Cue])
commitLanding entry session
  | entry `notElem` reachable (sessionGame session) || phase (sessionGame session) /= Studying = (session, [])
  | otherwise = foldl' go (session, []) (landingPath entry ++ [HardDrop])
  where
    go (current, cues) command = let (next, more) = tickSession (TickInput [command] (Held Neutral False)) current in (next, cues ++ more)

data SavedSession = SavedSession Int String Integer [Command] Held [(String, Int)] [TickInput] [Cue] String [TickInput] Bool (String, Int) deriving (Show, Read)

data SessionError = SessionSyntax | SessionVersion | SessionGameError SaveError | SessionTemporalError deriving (Eq, Show)

sessionCheckpoint :: Session -> String
sessionCheckpoint session =
  show
    ( SavedSession
        1
        (checkpoint (sessionGame session))
        (internalDebt session)
        (internalPending session)
        (internalHeld session)
        (map saveEntry (internalHistory session))
        (internalTrace session)
        (internalCues session)
        (checkpoint (internalInitial session))
        (internalReplay session)
        (internalFocused session)
        (saveEntry (internalPieceStart session))
    )
  where
    saveEntry (game, trace) = (checkpoint game, trace)

restoreSession :: String -> Either SessionError Session
restoreSession text
  | length text > 16000000 = Left SessionSyntax
  | otherwise = case readMaybe text of
      Nothing -> Left SessionSyntax
      Just (SavedSession version saved debt pending held history trace cues initial replay focused pieceStart)
        | version /= 1 -> Left SessionVersion
        | debt < 0 || debt >= 1000000 || length pending > 1024 || length history > 100 || length trace > 1000000 || length replay > 1000000 || any excessive (trace ++ replay) -> Left SessionTemporalError
        | otherwise -> do
            game <- restoreGame saved
            old <- traverse restoreEntry history
            first <- restoreGame initial
            piece <- restoreEntry pieceStart
            let (rebuilt, chunks) = rebuild first trace
            if sessionGame rebuilt /= game || internalHistory rebuilt /= old || internalPieceStart rebuilt /= piece || not (validCueSuffix cues chunks)
              then Left SessionTemporalError
              else pure (Session game debt pending held old trace cues first replay focused piece)
  where
    restoreGame = either (Left . SessionGameError) Right . restore
    restoreEntry (saved, inputs) = do game <- restoreGame saved; pure (game, inputs)
    rebuild initial = foldl' rebuildTick (start initial, []) . reverse
    rebuildTick (session, chunks) input = let (next, emitted) = tickSession input session in (next, emitted : chunks)
    excessive (TickInput commands _) = length commands > 32
    validCueSuffix [] _ = True
    validCueSuffix wanted chunks = collect [] chunks
      where
        collect _ [] = False
        collect accumulated (chunk : rest) =
          let combined = chunk ++ accumulated
           in combined == wanted || (length combined < length wanted && collect combined rest)
