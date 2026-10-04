"""Development acceptance fixtures: edit an existing game, never scaffold again.

These deliberately concrete edits exercise the published template's extension
points. They are not a migration engine for arbitrary user-modified games.
"""
from pathlib import Path


class Edits:
    def __init__(self, project):
        self.project = Path(project)
        self.files = {}

    def replace(self, name, before, after):
        text = self.files.get(name, (self.project / name).read_text(encoding='utf-8'))
        if text.count(before) != 1:
            raise ValueError(f'{name}: expected one fixture edit site, found {text.count(before)}')
        self.files[name] = text.replace(before, after)

    def write(self):
        # Every expected edit is validated before the first file is changed.
        for name, text in self.files.items():
            (self.project / name).write_text(text, encoding='utf-8', newline='\n')


def add_key(project):
    edit = Edits(project)
    model, internal = 'src/Game/Model.hs', 'src/Game/Model/Internal.hs'
    rules, view, save = 'src/Game/Rules.hs', 'src/Game/View.hs', 'src/Game/Save.hs'
    edit.replace(internal, 'data Progress =', 'data KeyStatus = KeyOnBoard | KeyCarried deriving (Eq, Show)\n\ndata Progress =')
    edit.replace(internal, '    worldProgress :: Progress', '    worldKey :: KeyStatus,\n    worldProgress :: Progress')
    edit.replace(model, '    initial,', '    hasKey,\n    keyCell,\n    initial,')
    edit.replace(model, ' | Won |', ' | PickedUpKey | ExitLocked | Won |')
    edit.replace(model, '  | FinishedAwayFromExit', '  | FinishedWithoutKey\n  | FinishedAwayFromExit')
    edit.replace(model, 'initial :: World', 'keyCell :: (Int, Int)\nkeyCell = (0, 1)\n\nhasKey :: World -> Bool\nhasKey world = worldKey world == KeyCarried\n\ninitial :: World')
    edit.replace(model, '(Turn 0) Exploring', '(Turn 0) KeyOnBoard Exploring')
    edit.replace(model, 'Integer -> Bool -> Either', 'Integer -> Bool -> Bool -> Either')
    edit.replace(model, 'restoreWorld column row turns won =', 'restoreWorld column row turns key won =')
    edit.replace(model, '      world = World', '      keyStatus = if key then KeyCarried else KeyOnBoard\n      world = World')
    edit.replace(model, '(Turn turns) progress', '(Turn turns) keyStatus progress')
    edit.replace(model, '        ++ [FinishedAwayFromExit', '        ++ [FinishedWithoutKey | isWon world && not (hasKey world)]\n        ++ [FinishedAwayFromExit')
    edit.replace(rules, 'coordinates (position next) == exitCell ->', 'coordinates (position next) == exitCell && hasKey next ->')
    edit.replace(rules, '              | otherwise -> (next, [ExitUnavailable])', '              | coordinates (position next) == exitCell -> (next, [ExitLocked])\n              | otherwise -> (next, [ExitUnavailable])')
    edit.replace(rules, 'in (world {Internal.worldPosition = nextPosition}, [Moved nextPosition])',
                 'in collectKey (world { Internal.worldPosition = nextPosition }) [Moved nextPosition]')
    edit.replace(rules, '-- | A deterministic playthrough', '''collectKey :: World -> [Event] -> (World, [Event])
collectKey world events
  | coordinates (position world) == keyCell && not (hasKey world) =
      (world { Internal.worldKey = Internal.KeyCarried }, events ++ [PickedUpKey])
  | otherwise = (world, events)

-- | A deterministic playthrough''')
    edit.replace(rules, '[Move East, Move East, Move South, UseExit]', '[Move South, Move East, Move East, UseExit]')
    edit.replace(view, 'else "Walk to E, then use exit."', 'else if hasKey world then "Key held. Walk to E, then use exit." else "Find K to unlock E."')
    edit.replace(view, '      | (column, row) == exitCell', '      | (column, row) == keyCell && not (hasKey world) = "K "\n      | (column, row) == exitCell')
    edit.replace(view, 'renderEvent Won =', 'renderEvent PickedUpKey = "Collected the key."\nrenderEvent ExitLocked = "The exit is locked. Find the key."\nrenderEvent Won =')
    edit.replace(save, ' | SavedProgress', ' | SavedKey | SavedProgress')
    edit.replace(save, '["FP-GAME-SAVE", "1", show column, show row, show (turnCount world), show (isWon world)]',
                 '["FP-GAME-SAVE", "2", show column, show row, show (turnCount world), show (hasKey world), show (isWon world)]')
    edit.replace(save, '["FP-GAME-SAVE", "1", column, row, turns, won]', '["FP-GAME-SAVE", "2", column, row, turns, key, won]')
    edit.replace(save, '        finished <-', '        held <- parse SavedKey key\n        finished <-')
    edit.replace(save, '(restoreWorld x y turn finished)', '(restoreWorld x y turn held finished)')
    edit.replace('test/Spec.hs', 'FP-GAME-SAVE 1 99 0 0 False', 'FP-GAME-SAVE 2 99 0 0 False False')
    edit.replace('test/Spec.hs', 'FP-GAME-SAVE 1 0 0 -1 False', 'FP-GAME-SAVE 2 0 0 -1 False False')
    edit.replace('test/Spec.hs', '  putStrLn "game-tests:', '''  let locked = walk [Move East, Move East, Move South]
      (blocked, blockedEvents) = advance UseExit locked
      (withKey, keyEvents) = advance (Move South) initial
  assert "exit remains locked without collectible" (not (isWon blocked) && blockedEvents == [ExitLocked])
  assert "key is visible before collection" ("K " `contains` render initial)
  assert "collection changes state, events and rendering" (hasKey withKey && PickedUpKey `elem` keyEvents && not ("K " `contains` render withKey))
  assert "key enables exit" (hasKey final && isWon final)
  assert "version 1 requires an explicit migration" (decodeWorld "FP-GAME-SAVE 1 0 0 0 False" == Left UnsupportedFormat)
  assert "invalid won-without-key is rejected" (isLeft (decodeWorld "FP-GAME-SAVE 2 2 1 4 False True"))
  putStrLn "game-tests:''')
    edit.replace('GAME-SPEC.md', 'This is your game workspace.', 'Implemented: collect K at (0,1) before using E. Save version 2 rejects v1 until an explicit migration is chosen.\n\nThis is your game workspace.')
    edit.write()


def add_stamina(project):
    edit = Edits(project)
    model, internal = 'src/Game/Model.hs', 'src/Game/Model/Internal.hs'
    rules, view, save = 'src/Game/Rules.hs', 'src/Game/View.hs', 'src/Game/Save.hs'
    edit.replace(internal, 'newtype Turn =', 'newtype Stamina = Stamina Int deriving (Eq, Show)\nnewtype Turn =')
    edit.replace(internal, '    worldKey ::', '    worldStamina :: Stamina,\n    worldKey ::')
    edit.replace(model, '    hasKey,', '    stamina,\n    maxStamina,\n    hasKey,')
    edit.replace(model, 'Move Direction | UseExit', 'Move Direction | Rest | UseExit')
    edit.replace(model, ' | PickedUpKey |', ' | Rested | Exhausted | PickedUpKey |')
    edit.replace(model, '  | NegativeTurn Integer', '  | NegativeTurn Integer\n  | StaminaOutOfRange Int')
    edit.replace(model, 'keyCell ::', 'maxStamina :: Int\nmaxStamina = 3\n\nstamina :: World -> Int\nstamina world = case worldStamina world of Stamina amount -> amount\n\nkeyCell ::')
    edit.replace(model, '(Turn 0) KeyOnBoard', '(Turn 0) (Stamina maxStamina) KeyOnBoard')
    edit.replace(model, 'Integer -> Bool -> Bool -> Either', 'Integer -> Int -> Bool -> Bool -> Either')
    edit.replace(model, 'restoreWorld column row turns key won =', 'restoreWorld column row turns energy key won =')
    edit.replace(model, '(Turn turns) keyStatus', '(Turn turns) (Stamina energy) keyStatus')
    edit.replace(model, '        ++ [FinishedWithoutKey', '        ++ [StaminaOutOfRange (stamina world) | stamina world < 0 || stamina world > maxStamina]\n        ++ [FinishedWithoutKey')
    edit.replace(rules, '            Move direction -> resolveMovement direction next', '''            Move direction
              | stamina next == 0 -> (next, [Exhausted])
              | otherwise -> resolveMovement direction next
            Rest -> (next { Internal.worldStamina = Internal.Stamina (min maxStamina (stamina next + 1)) }, [Rested])''')
    edit.replace(rules, 'world { Internal.worldPosition = nextPosition }', 'world { Internal.worldPosition = nextPosition, Internal.worldStamina = Internal.Stamina (stamina world - 1) }')
    edit.replace(view, '["Turn " ++ show (turnCount world),', '["Turn " ++ show (turnCount world), "Stamina " ++ show (stamina world),')
    edit.replace(view, 'renderEvent PickedUpKey =', 'renderEvent Rested = "Rested to recover stamina."\nrenderEvent Exhausted = "Too tired to move. Rest first."\nrenderEvent PickedUpKey =')
    edit.replace(save, ' | SavedKey', ' | SavedStamina | SavedKey')
    edit.replace(save, '"2", show column, show row, show (turnCount world),', '"3", show column, show row, show (turnCount world), show (stamina world),')
    edit.replace(save, '"2", column, row, turns, key, won', '"3", column, row, turns, energy, key, won')
    edit.replace(save, '        held <-', '        amount <- parse SavedStamina energy\n        held <-')
    edit.replace(save, '(restoreWorld x y turn held finished)', '(restoreWorld x y turn amount held finished)')
    edit.replace('app/Main.hs', 'west, exit, look', 'west, rest, exit, look')
    edit.replace('app/Main.hs', '  "exit" ->', '  "rest" -> Just Rest\n  "exit" ->')
    edit.replace('test/Spec.hs', 'FP-GAME-SAVE 2 99 0 0 False False', 'FP-GAME-SAVE 3 99 0 0 3 False False')
    edit.replace('test/Spec.hs', 'FP-GAME-SAVE 2 0 0 -1 False False', 'FP-GAME-SAVE 3 0 0 -1 3 False False')
    edit.replace('test/Spec.hs', 'FP-GAME-SAVE 2 2 1 4 False True', 'FP-GAME-SAVE 3 2 1 4 3 False True')
    edit.replace('test/Spec.hs', '  putStrLn "game-tests:', '''  let tired = walk [Move South, Move East, Move North]
      (stillTired, exhaustedEvents) = advance (Move East) tired
      recovered = fst (advance Rest stillTired)
      moved = fst (advance (Move East) recovered)
  assert "stamina blocks further movement" (stamina tired == 0 && position tired == position stillTired && exhaustedEvents == [Exhausted])
  assert "rest permits the next move" (stamina recovered == 1 && coordinates (position moved) == (2,0))
  assert "rest cannot overfill stamina" (stamina (fst (advance Rest initial)) == maxStamina)
  assert "second mechanic remains visible" ("Stamina 0" `contains` render tired)
  assert "save rejects out-of-range stamina" (isLeft (decodeWorld "FP-GAME-SAVE 3 0 0 0 99 False False"))
  assert "version 2 migration is deliberate" (decodeWorld "FP-GAME-SAVE 2 0 0 0 False False" == Left UnsupportedFormat)
  putStrLn "game-tests:''')
    edit.replace('GAME-SPEC.md', 'Implemented: collect K', 'Implemented next: movement spends bounded stamina (0..3); rest restores one. Save v3 requires a deliberate v2 migration.\n\nImplemented: collect K')
    edit.write()
