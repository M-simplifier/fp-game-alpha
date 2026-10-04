module Game (Config, Revision, World, Runtime, Direction (..), initialRuntime, admit, newSession, restart, move, render, observeInitial, activeWorld, stagedConfig, defaultBudget) where

import Text.Read (readMaybe)

newtype Revision = Revision Integer deriving (Eq, Ord, Show)

data Config = Config Revision Int deriving (Eq, Show)

data World = World Config Int Int deriving (Eq, Show)

data Runtime = Runtime Config World deriving (Eq, Show)

data Direction = Leftward | Rightward deriving (Eq, Show)

defaultBudget :: Int
defaultBudget = 8

initialRuntime :: Runtime
initialRuntime = let c = Config (Revision 0) defaultBudget in Runtime c (fresh c)

fresh :: Config -> World
fresh c@(Config _ budget) = World c 0 budget

activeWorld :: Runtime -> World
activeWorld (Runtime _ w) = w

stagedConfig :: Runtime -> Config
stagedConfig (Runtime c _) = c

-- Fixed bounded record, not a DSL. Private constructors enforce admission.
-- Parse Integer and validate BEFORE narrowing: readMaybe Int can wrap overflow.
decode :: String -> Either String Config
decode input
  | length (take 129 input) > 128 = Left "Config exceeds 128 characters"
  | otherwise = case words input of
      ["revision", rawRevision, "moveBudget", rawBudget]
        | digits rawRevision && digits rawBudget -> case (readMaybe rawRevision :: Maybe Integer, readMaybe rawBudget :: Maybe Integer) of
            (Just r, Just b) | r >= 1 && r <= 1000000000 && b >= 1 && b <= 30 -> Right (Config (Revision r) (fromInteger b))
            _ -> Left "revision must be 1..1000000000; moveBudget must be 1..30"
      _ -> Left "Expected: revision INTEGER moveBudget INTEGER"
  where
    digits s = not (null s) && all (\c -> c >= '0' && c <= '9') s

-- One pure result: no partial update, code evaluation, globals, or IO.
admit :: String -> Runtime -> Either String Runtime
admit input (Runtime old@(Config oldRevision _) world) = do
  candidate@(Config revision _) <- decode input
  if revision <= oldRevision
    then Left ("Stale revision; retained " ++ show old)
    else Right (Runtime candidate world)

-- New takes staged rules. Restart deliberately repeats this session's rules.
newSession :: Runtime -> Runtime
newSession (Runtime config _) = Runtime config (fresh config)

restart :: Runtime -> Runtime
restart (Runtime staged (World config _ _)) = Runtime staged (fresh config)

move :: Direction -> Runtime -> Runtime
move direction rt@(Runtime staged (World config position remaining))
  | position == 6 || remaining == 0 = rt
  | destination < 0 || destination > 6 = rt
  | otherwise = Runtime staged (World config destination (remaining - 1))
  where
    destination = position + case direction of Leftward -> -1; Rightward -> 1

render :: Runtime -> String
render (Runtime (Config (Revision nextRevision) nextBudget) (World (Config (Revision revision) budget) position remaining)) =
  "["
    ++ [if i == position then '@' else if i == 6 then 'G' else '.' | i <- [0 .. 6]]
    ++ "] "
    ++ status
    ++ " | moves="
    ++ show remaining
    ++ " session=r"
    ++ show revision
    ++ "/"
    ++ show budget
    ++ " staged=r"
    ++ show nextRevision
    ++ "/"
    ++ show nextBudget
  where
    status | position == 6 = "WON" | remaining == 0 = "OUT OF MOVES" | otherwise = "PLAYING"

observeInitial :: String
observeInitial = render (move Rightward (newSession initialRuntime))
