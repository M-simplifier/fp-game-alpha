module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Exception (bracket)
import Control.Monad (unless, when)
import Data.Map.Strict qualified as M
import GHC.Clock (getMonotonicTimeNSec)
import GameIO.Audio qualified as Audio
import Garden.Audio
import Garden.Types (Cue (..))
import System.Environment (getArgs)

main :: IO ()
main = do
  fullLoop <- (== ["--full-loop"]) <$> getArgs
  ensureAudio
  day <- Audio.loadWav "assets/garden-audio/day.wav"
  night <- Audio.loadWav "assets/garden-audio/night.wav"
  check "Generated WAV files are 48 seconds of 44.1 kHz stereo" (all expectedAmbience [day, night])
  started <- getMonotonicTimeNSec
  bracket loadAudioAssets shutdownAudio $ \assets -> do
    loaded <- getMonotonicTimeNSec
    putStrLn ("Afterlight audio acquisition ns " ++ show (loaded - started))
    updateAudio assets 0.25 False
    threadDelay 420000
    active <- snapshot assets
    let frame = Audio.voiceSourceFrame
        near x y = abs (x - y) < 1e-6
    check "Both day and night ambience have begun" (frame (snapshotDay active) > 0 && frame (snapshotNight active) > 0)
    check
      "Day and night use the square-root veil mix"
      ( near (Audio.voiceGain (snapshotDay active)) (0.55 * sqrt 0.75)
          && near (Audio.voiceGain (snapshotNight active)) (0.55 * sqrt 0.25)
      )
    updateAudio assets 0.81 True
    let events = [Offering, Wings, Jump, Return]
    check
      "Wings and Return suppress Offering without reordering the other cues"
      (selectedCues events == [Wings, Jump, Return])
    playCues assets events
    threadDelay 220000
    paused <- snapshot assets
    check
      "Pause/photo quiets both ambience voices while their source clocks advance"
      ( near (Audio.voiceGain (snapshotDay paused)) (0.10 * sqrt 0.19)
          && near (Audio.voiceGain (snapshotNight paused)) (0.10 * sqrt 0.81)
          && frame (snapshotDay paused) > frame (snapshotDay active)
          && frame (snapshotNight paused) > frame (snapshotNight active)
      )
    check
      "The real audio path played Wings, Jump and Return without Offering"
      (M.keysSet (snapshotCues paused) == M.keysSet (M.fromList [(Wings, ()), (Jump, ()), (Return, ())]))
    playCues assets [Wings]
    threadDelay 50000
    restarted <- snapshot assets
    check
      "A repeated cue restarts its existing voice"
      ( case (M.lookup Wings (snapshotCues paused), M.lookup Wings (snapshotCues restarted)) of
          (Just old, Just new) -> frame new < frame old
          _ -> False
      )
    print restarted
    when fullLoop (checkWrap assets)

expectedAmbience :: Audio.PCM -> Bool
expectedAmbience pcm =
  Audio.pcmSampleRate pcm == 44100
    && Audio.pcmChannels pcm == Audio.Stereo
    && Audio.pcmFrames pcm == 48 * 44100

snapshot :: AudioAssets -> IO AudioSnapshot
snapshot assets = audioSnapshot assets >>= maybe (fail "Afterlight audio worker is unavailable") pure

checkWrap :: AudioAssets -> IO ()
checkWrap assets = do
  started <- getMonotonicTimeNSec
  let wrap !previousDay !previousNight !dayWrapped !nightWrapped = do
        threadDelay 250000
        observed <- snapshot assets
        let day = Audio.voiceSourceFrame (snapshotDay observed)
            night = Audio.voiceSourceFrame (snapshotNight observed)
            sawDayWrap = dayWrapped || day < previousDay
            sawNightWrap = nightWrapped || night < previousNight
        now <- getMonotonicTimeNSec
        check "Day and night source frames stay within a 48-second loop" (day < 48 * 44100 && night < 48 * 44100)
        check "A 48-second source loop wrapped before the observation deadline" (now - started < 52000000000)
        if sawDayWrap && sawNightWrap
          then do
            check
              "Both voices are still playing after the wrap"
              (all ((== Audio.VoicePlaying) . Audio.voiceStatus) [snapshotDay observed, snapshotNight observed])
            print observed
          else wrap day night sawDayWrap sawNightWrap
  wrap 0 0 False False

check :: String -> Bool -> IO ()
check detail passed = unless passed (fail detail)
