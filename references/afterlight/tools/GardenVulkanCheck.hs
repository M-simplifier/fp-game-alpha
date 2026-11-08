module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Monad (forM_, replicateM, replicateM_, unless, when)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as C8
import Data.List (sort)
import qualified Data.Set as Set
import qualified GameIO.Graphics as GPU
import GameIO.Platform
import Garden.Photo
import Garden.Render.Native
import Garden.Render.Settings
import Garden.View
import Garden.World (initialWorld)
import GHC.Clock (getMonotonicTimeNSec)
import System.Directory (createDirectoryIfMissing)
import System.Environment (getArgs)
import System.Mem (performMajorGC)
import Text.Read (readMaybe)

main :: IO ()
main = do
  arguments <- getArgs
  case arguments of
    ["--emit-shaders", output] -> createDirectoryIfMissing True output >> writeNativeShaderBinaries output
    ["--capture", output] -> capture output 0 Quick
    ["--bench", output, frames] | Just n <- readMaybe frames, n > 0 -> capture output n Quick
    ["--matched", output, frames] | Just n <- readMaybe frames, n > 0 -> capture output n Matched
    ["--default-size", output, frames] | Just n <- readMaybe frames, n > 0 -> capture output n DefaultSize
    _ -> fail "Usage: afterlight-gameio-render-check --capture DIR | --bench DIR N | --matched DIR N | --default-size DIR N | --emit-shaders DIR"

data Suite = Quick | Matched | DefaultSize

capture :: FilePath -> Int -> Suite -> IO ()
capture output sampleCount suite = do
  createDirectoryIfMissing True output
  withWindowVisibility False (WindowConfig "Afterlight Vulkan renderer check" 640 360) $ \window ->
    withNativeScene window $ \native -> do
      putStrLn ("adapter " ++ nativeSceneAdapterName native)
      let view = (project initialWorld) {sceneTarget = NoTarget}
      started <- getMonotonicTimeNSec
      warmNativeScene native view
      uploaded <- getMonotonicTimeNSec
      putStrLn ("initial chunk generation and upload seconds " ++ show (seconds (uploaded - started)))
      let photo = (beginPhoto (sceneEye view) (sceneForward view)) {photoGrid = False, photoFov = 100, photoRoll = 0.45}
      let cases = case suite of
            Quick ->
              [ ("day-light", (640, 360), preset LightQuality, view, Nothing)
              , ("day-balanced", (640, 360), preset BalancedQuality, view, Nothing)
              , ("day-full", (640, 360), preset FullQuality, view, Nothing)
              , ("night", (640, 360), preset FullQuality, view {sceneVeil = 0.94}, Nothing)
              , ("photo-wide-odd", (701, 393), preset BalancedQuality, view, Just photo)
              , ("day-restored-light", (640, 360), preset LightQuality, view, Nothing)
              ]
            Matched ->
              [("day-" ++ show quality, (1280, 720), preset quality, view, Nothing)
                | quality <- [FullQuality, BalancedQuality, LightQuality]]
              ++ [ ("night", (1280, 720), preset FullQuality, view {sceneVeil = 0.94}, Nothing)
                 , ("wide-odd", (1367, 769), preset FullQuality, view, Just photo)
                 , ("restored-high", (1280, 720), preset FullQuality, view, Nothing)
                 ]
            DefaultSize ->
              [("desktop-" ++ show quality, (1600, 900), preset quality, view, Nothing)
                | quality <- [FullQuality, BalancedQuality, LightQuality]]
      forM_ cases $ \(label, (w,h), settings, scene, portrait) -> do
        resizeWindow window w h
        _ <- pollWindowEvents window
        pixels <- readPresented window native settings portrait scene
        unless ((GPU.pixelWidth pixels, GPU.pixelHeight pixels) == (w,h)) (fail ("wrong capture extent " ++ label))
        let colors = sampleColors pixels
        unless (colors >= 32) (fail ("insufficient real scene variation " ++ label ++ ": " ++ show colors))
        writePPM (output ++ "/" ++ label ++ ".ppm") pixels
        putStrLn ("render-check " ++ label ++ " sampled colors " ++ show colors)
        when (sampleCount > 0) $ do
          replicateM_ 12 (renderPresented window native settings portrait scene)
          performMajorGC
        samples <- replicateM sampleCount $ do
          start <- getMonotonicTimeNSec
          renderPresented window native settings portrait scene
          end <- getMonotonicTimeNSec
          metric <- nativeSceneMetrics native
          pure (seconds (end - start) * 1000, metric)
        let wall = map fst samples
        unless (null wall) $
          putStrLn (label ++ " CPU and presentation wall ms p50/p95 " ++ show (percentile 0.5 wall, percentile 0.95 wall))
        report label [sample | (_, Just sample) <- samples]

readPresented :: Window -> NativeScene -> RenderSettings -> Maybe Photo -> SceneView -> IO GPU.FramePixels
readPresented window native settings portrait scene = loop (120 :: Int)
  where
    loop 0 = fail "No Afterlight image was presented"
    loop remaining = do
      _ <- pollWindowEvents window
      result <- readNativeScene native settings portrait scene 0 []
      case result of
        (GPU.FramePresented, Just pixels) -> pure pixels
        _ -> threadDelay 2000 >> loop (remaining - 1)

renderPresented :: Window -> NativeScene -> RenderSettings -> Maybe Photo -> SceneView -> IO ()
renderPresented window native settings portrait scene = loop (120 :: Int)
  where
    loop 0 = fail "No Afterlight image was presented"
    loop remaining = do
      _ <- pollWindowEvents window
      status <- drawNativeScene native settings portrait scene 0 []
      case status of
        GPU.FramePresented -> pure ()
        _ -> threadDelay 2000 >> loop (remaining - 1)

sampleColors :: GPU.FramePixels -> Int
sampleColors image = Set.size $ Set.fromList
  [BS.take 3 (BS.drop offset rgba) | y <- [0, 12 .. GPU.pixelHeight image - 1]
    , x <- [0, 12 .. GPU.pixelWidth image - 1], let offset = (y * GPU.pixelWidth image + x) * 4]
  where
    rgba = GPU.pixelRGBA8 image

report :: String -> [GPU.FrameMetrics] -> IO ()
report _ [] = pure ()
report label samples = do
  let ms value = seconds value * 1000
  let values field = map (ms . field) samples
  let gpu = [x / 1000000 | sample <- samples, Just x <- [GPU.frameGPUNSec sample]]
  forM_ [ ("pack", values GPU.framePrepareNSec)
        , ("prior fence", values GPU.frameFenceWaitNSec)
        , ("encode", values GPU.frameEncodeNSec)
        , ("submit", values GPU.frameSubmitNSec)
        , ("present call", values GPU.framePresentCallNSec)
        , ("GPU", gpu)
        ] $ \(metric, measured) ->
    putStrLn (label ++ " " ++ metric ++ " ms p50/p95 " ++ show (percentile 0.5 measured, percentile 0.95 measured))

percentile :: Double -> [Double] -> Maybe Double
percentile fraction measurements =
  case drop (min (count - 1) (floor (fromIntegral count * fraction))) (sort measurements) of
    value : _ -> Just value
    [] -> Nothing
  where
    count = length measurements

seconds :: Integral n => n -> Double
seconds elapsed = fromIntegral elapsed / 1000000000

writePPM :: FilePath -> GPU.FramePixels -> IO ()
writePPM path image = BS.writeFile path (header <> BS.pack (dropAlpha (BS.unpack (GPU.pixelRGBA8 image))))
  where
    header = C8.pack ("P6\n" ++ show (GPU.pixelWidth image) ++ " " ++ show (GPU.pixelHeight image) ++ "\n255\n")
    dropAlpha (r:g:b:_:rest) = r:g:b:dropAlpha rest
    dropAlpha _ = []
