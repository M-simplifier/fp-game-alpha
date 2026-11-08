{-# LANGUAGE CPP #-}

module Garden.Audio
  ( AudioAssets
  , ensureAudio
  , generateAudio
  , loadAudioAssets
  , updateAudio
  , playCues
  , selectedCues
  , shutdownAudio
#if defined(AFTERLIGHT_GAMEIO_AUDIO)
  , AudioSnapshot (..)
  , audioSnapshot
#endif
  ) where

import Control.Monad (forM_, unless)
import Data.ByteString.Builder (toLazyByteString)
import Data.ByteString.Lazy qualified as BL
import Data.Map.Strict qualified as M
import Garden.Soundscape
import Garden.Types (Cue (..))
#if defined(AFTERLIGHT_GAMEIO_AUDIO)
import Control.Concurrent (MVar, modifyMVar_, newMVar, readMVar)
import Control.Exception (mask, onException, throwIO, try)
import GameIO.Audio qualified as Audio
import System.Environment (getExecutablePath, lookupEnv)
import System.FilePath ((</>), takeDirectory)
#else
import Raylib.Core.Audio
import Raylib.Internal (WindowResources, managed)
import Raylib.Types.Core.Audio (Music, Sound)
#endif
import System.Directory (createDirectoryIfMissing, doesFileExist)

#if defined(AFTERLIGHT_GAMEIO_AUDIO)
data AudioAssets
  = AudioUnavailable
  | AudioAssets !Audio.Audio !Audio.Voice !Audio.Voice !(M.Map Cue CueSound) !Audio.VoiceOptions

data CueSound = CueSound !Audio.PreparedSound !(MVar (Maybe Audio.Voice))

data AudioSnapshot = AudioSnapshot
  { snapshotWorkerPid :: !Int
  , snapshotStats :: !Audio.AudioStats
  , snapshotDay :: !Audio.VoiceSnapshot
  , snapshotNight :: !Audio.VoiceSnapshot
  , snapshotCues :: !(M.Map Cue Audio.VoiceSnapshot)
  }
  deriving (Show)
#else
data AudioAssets = AudioAssets (Maybe Music) (Maybe Music) (M.Map Cue Sound)
#endif

root :: FilePath
root = "assets/garden-audio/"

cues :: [Cue]
cues = [Mine, Build, Jewel, Offering, Wound, Jump, Strike, Dusk, Wings, Return, Dash]

ensureAudio :: IO ()
ensureAudio = renderAudio True

generateAudio :: IO ()
generateAudio = renderAudio False

renderAudio :: Bool -> IO ()
renderAudio keepExisting = do
  createDirectoryIfMissing True root
  let write name duration signal = do
        exists <- doesFileExist (root <> name)
        unless (keepExisting && exists) (BL.writeFile (root <> name) (toLazyByteString (wave duration signal)))
  write "day.wav" 48 (ambience Sunlit)
  write "night.wav" 48 (ambience Veiled)
  forM_ cues $ \cue -> write (show cue <> ".wav") (cueLength cue) (cueSignal cue)

selectedCues :: [Cue] -> [Cue]
selectedCues events
  | any (`elem` events) [Wings, Return] = filter (/= Offering) events
  | otherwise = events

ambienceGains :: Float -> Bool -> (Float, Float)
ambienceGains veil paused =
  let level = if paused then 0.10 else 0.55
  in (level * sqrt (max 0 (1 - veil)), level * sqrt (max 0 veil))

#if defined(AFTERLIGHT_GAMEIO_AUDIO)
loadAudioAssets :: IO AudioAssets
loadAudioAssets = mask $ \restore -> do
  override <- lookupEnv "GAMEIO_AUDIO_WORKER"
  worker <- case override of
    Just path -> pure path
    Nothing -> (</> "gameio-audio-worker.exe") . takeDirectory <$> getExecutablePath
  opened <- try (restore (Audio.openIsolatedAudio worker Audio.defaultAudioConfig))
  case opened of
    Left issue -> do
      putStrLn ("Audio device unavailable; continuing silently. " ++ show (issue :: Audio.AudioError))
      pure AudioUnavailable
    Right audio -> restore (loadPrepared audio) `onException` Audio.closeAudio audio
  where
    loadPrepared audio = do
      let prepare name = Audio.loadWav (root <> name) >>= Audio.prepareSound audio
      day <- prepare "day.wav"
      night <- prepare "night.wav"
      sounds <- traverse (\cue -> CueSound <$> prepare (show cue <> ".wav") <*> newMVar Nothing)
        (M.fromList [(cue, cue) | cue <- cues])
      loop <- either throwIO pure (Audio.voiceOptions Audio.Loop 0 0)
      cueVolume <- either throwIO pure (Audio.voiceOptions Audio.PlayOnce 0.75 0)
      format <- Audio.readAudioFormat audio
      Audio.AudioFrame earliest <- Audio.readAudioFrame audio
      -- Both loops begin on the same audio frame after their PCM is in the worker.
      let start = Audio.AudioFrame (earliest + fromIntegral (Audio.audioSampleRate format `quot` 4))
      dayVoice <- Audio.playPreparedSoundAt day start loop
      nightVoice <- Audio.playPreparedSoundAt night start loop
      pure (AudioAssets audio dayVoice nightVoice sounds cueVolume)

updateAudio :: AudioAssets -> Float -> Bool -> IO ()
updateAudio AudioUnavailable _ _ = pure ()
updateAudio (AudioAssets _ day night _ _) veil paused = do
  let (dayGain, nightGain) = ambienceGains veil paused
  Audio.setVoiceGain day dayGain
  Audio.setVoiceGain night nightGain

playCues :: AudioAssets -> [Cue] -> IO ()
playCues AudioUnavailable _ = pure ()
playCues (AudioAssets _ _ _ sounds options) events =
  forM_ (selectedCues events) $ \cue ->
    forM_ (M.lookup cue sounds) $ \(CueSound sound active) ->
      modifyMVar_ active $ \previous -> do
        let start = Just <$> Audio.playPreparedSound sound options
        case previous of
          Nothing -> start
          Just voice -> do
            restarted <- try (Audio.seekVoice voice 0)
            case restarted of
              Right () -> pure previous
              Left Audio.VoiceInactive -> start
              Left issue -> throwIO issue

shutdownAudio :: AudioAssets -> IO ()
shutdownAudio AudioUnavailable = pure ()
shutdownAudio (AudioAssets audio _ _ _ _) = Audio.closeAudio audio

audioSnapshot :: AudioAssets -> IO (Maybe AudioSnapshot)
audioSnapshot AudioUnavailable = pure Nothing
audioSnapshot (AudioAssets audio day night cuesByKind _) = traverse snapshot (Audio.audioWorkerPid audio)
  where
    snapshot pid = AudioSnapshot pid <$> Audio.readAudioStats audio <*> Audio.readVoice day
      <*> Audio.readVoice night <*> (M.mapMaybe id <$> traverse cueSnapshot cuesByKind)
    cueSnapshot (CueSound _ current) = readMVar current >>= traverse Audio.readVoice
#else
loadAudioAssets :: WindowResources -> IO AudioAssets
loadAudioAssets window = do
  initAudioDevice
  ready <- isAudioDeviceReady
  if not ready
    then putStrLn "Audio device unavailable; continuing silently." >> pure (AudioAssets Nothing Nothing M.empty)
    else do
      day <- managed window (loadMusicStream (root <> "day.wav"))
      night <- managed window (loadMusicStream (root <> "night.wav"))
      forM_ [day, night] $ \music -> setMusicVolume music 0 >> playMusicStream music
      sounds <- traverse (\cue -> do sound <- managed window (loadSound (root <> show cue <> ".wav")); setSoundVolume sound 0.75; pure sound) (M.fromList [(c, c) | c <- cues])
      pure (AudioAssets (Just day) (Just night) sounds)

updateAudio :: AudioAssets -> Float -> Bool -> IO ()
updateAudio (AudioAssets day night _) veil paused = do
  let (dayGain, nightGain) = ambienceGains veil paused
      update volume music = setMusicVolume music volume >> updateMusicStream music
  mapM_ (update dayGain) day
  mapM_ (update nightGain) night

playCues :: AudioAssets -> [Cue] -> IO ()
playCues (AudioAssets _ _ sounds) events = mapM_ (mapM_ playSound . (`M.lookup` sounds)) (selectedCues events)

shutdownAudio :: WindowResources -> AudioAssets -> IO ()
shutdownAudio window (AudioAssets day night sounds) = do
  forM_ (M.elems sounds) (`unloadSound` window)
  forM_ [day, night] (mapM_ (`unloadMusicStream` window))
  closeAudioDevice (Just window)
#endif
