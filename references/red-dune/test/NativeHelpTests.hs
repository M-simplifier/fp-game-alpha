module Main where

import Control.Monad (forM_, unless)
import Data.ByteString.Char8 qualified as B
import Data.Set qualified as Set
import RedDune.Native.Help

check :: String -> Bool -> IO ()
check name passed = unless passed (ioError (userError name))

main :: IO ()
main = do
  let first = refreshHint (Just WellHint) (newHelpUi defaultPreferences)
      dismissed = updateHelp DismissHint first
      reopened = newHelpUi (helpPreferences first)
  check "first matching condition displays one hint" (activeHint first == Just WellHint)
  check "dismissed hint does not return on the same condition" (activeHint (refreshHint (Just WellHint) dismissed) == Nothing)
  check "displayed hint stays suppressed after restart" (activeHint (refreshHint (Just WellHint) reopened) == Nothing)
  check "new condition can show the next hint" (activeHint (refreshHint (Just FarmHint) dismissed) == Just FarmHint)
  check "condition disappearing clears the old hint" (activeHint (refreshHint Nothing first) == Nothing)
  forM_ allTopics $ \topic -> do
    let opened = updateHelp (OpenHelp topic) first
        switched = updateHelp (OpenHelp SavingAndResume) opened
        closed = updateHelp CloseHelp switched
    check "opening and switching chapters preserves guide preferences" (helpPreferences switched == helpPreferences first)
    check "help freezes the active hint even if the context changes" (refreshHint (Just KitchenHint) opened == opened)
    check "closing help returns the underlying hint unchanged" (closed == first)
    check "opening and closing frames suspend time" (helpHoldsClock first opened && helpHoldsClock opened closed)
    check "ordinary play does not suspend time" (not (helpHoldsClock first first))
    check "close is idempotent" (updateHelp CloseHelp closed == closed)
  let off = updateHelp (SetGuides False) first
  check "off suppresses every contextual hint" (all (\hint -> activeHint (refreshHint (Just hint) off) == Nothing) [minBound .. maxBound])
  check "all chapters remain accessible with guides off" (all (\topic -> helpTopic (updateHelp (OpenHelp topic) off) == Just topic) allTopics)
  check "repeating uses the current condition" (activeHint (refreshHint (Just PlacesHint) (updateHelp RepeatHints off)) == Just PlacesHint)
  let resumed = resumedHelpUi defaultPreferences
  check "resuming does not replay starter prompts" (all (\hint -> activeHint (refreshHint (Just hint) resumed) == Nothing) [WellHint, FarmHint, KitchenHint, FirstFoodHint])
  check "resuming keeps other contextual guidance" (activeHint (refreshHint (Just RoadHint) resumed) == Just RoadHint)
  check "resuming preserves the off preference" (not (guidesEnabled (helpPreferences (resumedHelpUi (helpPreferences off)))))
  check "repeating explicitly restores a starter prompt after resume" (activeHint (refreshHint (Just WellHint) (updateHelp RepeatHints resumed)) == Just WellHint)
  let fixed = B.pack "RED-DUNE-NATIVE-UI-PREFERENCES-1\nguides=off\nseen=well,road\n"
      expected = Preferences False (Set.fromList [WellHint, RoadHint])
  check "stable wire IDs" (decodePreferences fixed == Just expected && encodePreferences expected == fixed)
  forM_ [Preferences enabled (Set.fromList hints) | enabled <- [False, True], hints <- [[], [WellHint], [minBound .. maxBound]]] $ \preferences ->
    check "UI preferences round trip" (decodePreferences (encodePreferences preferences) == Just preferences)
  forM_ ["", "RED-DUNE-NATIVE-UI-PREFERENCES-2\nguides=on\nseen=\n", "RED-DUNE-NATIVE-UI-PREFERENCES-1\nguides=maybe\nseen=\n", "RED-DUNE-NATIVE-UI-PREFERENCES-1\nguides=on\nseen=well,well\n", "RED-DUNE-NATIVE-UI-PREFERENCES-1\nguides=on\nseen=unknown\n", "RED-DUNE-NATIVE-UI-PREFERENCES-1\nguides=on\nseen=\nextra\n", replicate 1025 'x'] $ \invalid ->
    check "malformed UI preference is rejected independently of world saves" (decodePreferences (B.pack invalid) == Nothing)
  putStrLn "Native HELP transitions and preference codec: PASS"
