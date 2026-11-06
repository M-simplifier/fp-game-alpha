module PureFall.Host.Audio
  ( Audio,
    withAudio,
    playCues,
    updateAudio,
    audioReport,
    generateAudio,
  )
where

import Control.Exception (bracket_)
import Control.Monad (forM, forM_, when)
import Data.ByteString.Builder (Builder, byteString, int16LE, toLazyByteString, word16LE, word32LE)
import Data.ByteString.Char8 qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (nub)
import PureFall.Core (Cue (..))
import Raylib.Core.Audio
import Raylib.Types (Music, Sound)
import Raylib.Util (WindowResources, managed)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath ((</>))

data Audio = Audio Bool [(String, Sound)] (Maybe Music) (IORef (Int, Int))

withAudio :: WindowResources -> FilePath -> (Audio -> IO a) -> IO a
withAudio resources root action = bracket_ initAudioDevice (closeAudioDevice (Just resources)) $ do
  ready <- isAudioDeviceReady
  counters <- newIORef (0, 0)
  if not ready
    then action (Audio False [] Nothing counters)
    else do
      renderAudio False root
      loaded <- forM voices $ \(name, _, _) -> do
        sound <- managed resources (loadSound (root </> name ++ ".wav"))
        valid <- isSoundValid sound
        pure [(name, sound) | valid]
      music <- managed resources (loadMusicStream (root </> "quiet-rhythm.wav"))
      musicValid <- isMusicValid music
      when musicValid (setMusicVolume music 0.22)
      action (Audio True (concat loaded) (if musicValid then Just music else Nothing) counters)

generateAudio :: FilePath -> IO ()
generateAudio = renderAudio True

renderAudio :: Bool -> FilePath -> IO ()
renderAudio overwrite root = do
  createDirectoryIfMissing True root
  forM_ (voices ++ [("quiet-rhythm", 10, rhythm)]) $ \(name, duration, signal) -> do
    let path = root </> name ++ ".wav"
    exists <- doesFileExist path
    when (overwrite || not exists) (BL.writeFile path (toLazyByteString (wave duration signal)))

playCues :: Audio -> [Cue] -> IO ()
playCues (Audio _ sounds _ counters) cues =
  forM_ (nub (map voice cues)) $ \name -> case lookup name sounds of
    Nothing -> pure ()
    Just sound -> playSound sound >> modifyIORef' counters (\(plays, streams) -> (plays + 1, streams))
  where
    voice cue = case cue of
      Moved -> "move"
      Turned -> "rotate"
      Dropped _ -> "drop"
      HeldCue -> "hold"
      Locked _ -> "lock"
      Cleared _ -> "clear"
      Finished _ -> "finish"
      PausedCue -> "pause"

updateAudio :: Audio -> Int -> Bool -> Bool -> IO ()
updateAudio (Audio ready _ backing counters) volume musicEnabled paused = when ready $ do
  setMasterVolume (fromIntegral volume / 100)
  forM_ backing $ \music -> do
    running <- isMusicStreamPlaying music
    if musicEnabled
      then do
        when (not running) (playMusicStream music >> modifyIORef' counters (\(plays, streams) -> (plays, streams + 1)))
        setMusicVolume music (if paused then 0.07 else 0.22)
        updateMusicStream music
      else when running (stopMusicStream music)

audioReport :: Audio -> IO String
audioReport (Audio ready sounds _ counters) = do
  (plays, streams) <- readIORef counters
  pure
    ( "audio_device_ready="
        ++ show ready
        ++ "\naudio_valid_cues="
        ++ show (length sounds)
        ++ "\naudio_play_calls="
        ++ show plays
        ++ "\nbacking_start_calls="
        ++ show streams
        ++ "\n"
    )

sampleRate :: Int
sampleRate = 22050

wave :: Double -> (Double -> Double) -> Builder
wave duration signal =
  let count = round (duration * fromIntegral sampleRate); bytes = count * 2
   in byteString (BS.pack "RIFF")
        <> word32LE (fromIntegral (36 + bytes))
        <> byteString (BS.pack "WAVEfmt ")
        <> word32LE 16
        <> word16LE 1
        <> word16LE 1
        <> word32LE (fromIntegral sampleRate)
        <> word32LE (fromIntegral (sampleRate * 2))
        <> word16LE 2
        <> word16LE 16
        <> byteString (BS.pack "data")
        <> word32LE (fromIntegral bytes)
        <> mconcat [int16LE (round (32767 * max (-0.9) (min 0.9 (signal (fromIntegral n / fromIntegral sampleRate))))) | n <- [0 .. count - 1 :: Int]]

tone :: Double -> Double -> Double
tone frequency time = sin (2 * pi * frequency * time)

envelope :: Double -> Double -> Double
envelope duration time = min 1 (time / 0.004) * max 0 (1 - time / duration) ** 2

voices :: [(String, Double, Double -> Double)]
voices =
  [ ("move", 0.055, \t -> 0.2 * envelope 0.055 t * tone 520 t),
    ("rotate", 0.11, \t -> 0.22 * envelope 0.11 t * (tone (640 + 900 * t) t + 0.2 * tone 1280 t)),
    ("drop", 0.17, \t -> 0.34 * envelope 0.17 t * tone (190 - 530 * t) t),
    ("hold", 0.15, \t -> 0.22 * envelope 0.15 t * (tone 440 t + 0.45 * tone 660 t)),
    ("lock", 0.13, \t -> 0.35 * envelope 0.13 t * (tone 110 t + 0.25 * tone 893 t)),
    ( "clear",
      0.68,
      \t ->
        sum
          [ if t >= delay then 0.19 * envelope (0.68 - delay) (t - delay) * tone frequency (t - delay) else 0
          | (delay, frequency) <- [(0, 523.25), (0.065, 659.25), (0.13, 783.99), (0.195, 1046.5)]
          ]
    ),
    ("finish", 0.9, \t -> 0.15 * envelope 0.9 t * (tone 261.63 t + tone 329.63 t + tone 392 t)),
    ("pause", 0.08, \t -> 0.14 * envelope 0.08 t * tone 330 t)
  ]

rhythm :: Double -> Double
rhythm time = 0.38 * (pad + bass + kick + hat)
  where
    beat = 0.625
    beatPosition = time - beat * fromIntegral (floor (time / beat) :: Int)
    bar = floor (time / (beat * 4)) `mod` 4 :: Int
    root = case bar of 0 -> 130.8128; 1 -> 155.5635; 2 -> 174.6141; _ -> 116.5409
    barPosition = time - (beat * 4) * fromIntegral (floor (time / (beat * 4)) :: Int)
    padGate = sin (pi * barPosition / (beat * 4)) ** 0.5
    pulseAttack = min 1 (beatPosition / 0.008)
    pad = 0.035 * padGate * (tone root time + 0.52 * tone (root * 2 ** (3 / 12)) time + 0.46 * tone (root * 1.5) time + 0.32 * tone (root * 2 ** (14 / 12)) time)
    bass = 0.16 * pulseAttack * exp (-7 * beatPosition) * tone (root / 2) beatPosition
    kick = 0.14 * pulseAttack * exp (-35 * beatPosition) * tone (50 + 60 * exp (-25 * beatPosition)) beatPosition
    halfPosition = time - (beat / 2) * fromIntegral (floor (time / (beat / 2)) :: Int)
    note :: Int
    note = case floor (time / beat) `mod` 8 :: Int of 0 -> 0; 1 -> 7; 2 -> 14; 3 -> 10; 4 -> 3; 5 -> 7; 6 -> 14; _ -> 7
    motif = 0.04 * pulseAttack * exp (-5 * beatPosition) * tone (root * 2 ** (fromIntegral note / 12)) beatPosition
    hat = 0.025 * min 1 (halfPosition / 0.002) * exp (-90 * halfPosition) * (tone 6473 halfPosition + tone 9103 halfPosition) + motif
