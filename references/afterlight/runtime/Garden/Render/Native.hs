{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NamedFieldPuns #-}

-- | The Windows host for the existing SceneView and RenderPlan.
module Garden.Render.Native
  ( NativeScene
  , withNativeScene
  , warmNativeScene
  , NativeChunkLoading
  , beginNativeChunkLoading
  , nativeChunkLoadingProgress
  , stepNativeChunkLoading
  , drawNativeScene
  , readNativeScene
  , nativeSceneMetrics
  , nativeSceneAdapterName
  , nativeSceneRenderer
  , writeNativeShaderBinaries
  ) where

import Control.Exception (bracketOnError, finally, mask, mask_, onException, throwIO, try)
import Control.Monad (forM_, unless, when)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Lazy as Lazy
import Data.IORef
import Data.List (sortOn)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified GameIO.Graphics as GPU
import GameIO.Graphics.Shader
import GameIO.Platform (Window, windowFramebufferSize)
import qualified Garden.Mesh as Mesh
import Garden.Photo
import Garden.Render.Chunk
import Garden.Render.Invalidation (changedSince)
import Garden.Render.NativeShaders
import Garden.Render.Settings
import Garden.Types hiding (eye, forward)
import Garden.View
import GHC.Clock (getMonotonicTimeNSec)
import System.Directory (doesFileExist)

data Programs = Programs
  { opaqueProgram :: !GPU.Material
  , skyProgram :: !GPU.Material
  , effectsProgram :: !GPU.Material
  , bloomProgram :: !GPU.Material
  , postProgram :: !GPU.Material
  , particleProgram :: !GPU.Material
  , burstProgram :: !GPU.Material
  }

data Targets = Targets
  { targetPlan :: !RenderPlan
  , targetScene :: !GPU.RenderTarget
  , targetSky :: !GPU.RenderTarget
  , targetShadow :: !(Maybe (GPU.RenderTarget, GPU.RenderTarget))
  , targetEffects :: !(Maybe GPU.RenderTarget)
  , targetBloom :: !(Maybe (GPU.RenderTarget, GPU.RenderTarget))
  }

data PreparedChunks = PreparedChunks !Int !(Map.Map Chunk [GPU.Mesh]) ![V3]

data NativeChunkLoading = NativeChunkLoading !NativeScene !SceneView !Int
  !(IORef (Int, [(Chunk, [(Cell, Material)])]))

data NativeScene = NativeScene
  { sceneWindow :: !Window
  , sceneRenderer :: !GPU.Renderer
  , scenePrograms :: !Programs
  , sceneNativeChunks :: !(IORef PreparedChunks)
  , sceneLoadingClaim :: !(IORef Bool)
  , sceneNativeTargets :: !(IORef (Maybe Targets))
  , sceneTargetFormat :: !GPU.TargetFormat
  , sceneKinMeshes :: !(Map.Map Gem [GPU.Mesh])
  , sceneEnemyMeshes :: !(Map.Map Threat [GPU.Mesh])
  , sceneRelicMesh :: ![GPU.Mesh]
  , sceneParticleMesh :: !GPU.Mesh
  }

withNativeScene :: Window -> (NativeScene -> IO a) -> IO a
withNativeScene window use = GPU.withRenderer window $ \renderer ->
  acquireScene window renderer >>= use

acquireScene :: Window -> GPU.Renderer -> IO NativeScene
acquireScene window renderer = do
  (sky, effects, flat) <- shaderLimits
  let world = GPU.createMaterial renderer . GPU.MaterialConfig GPU.WorldDepth worldVertex
  let screen = GPU.createMaterial renderer . GPU.MaterialConfig GPU.OverlayReplace defaultVertexShader
  let particle = GPU.createMaterial renderer . (\mode -> GPU.MaterialConfig mode defaultVertexShader flat)
  programs <- Programs <$> world worldFragment <*> screen sky <*> screen effects <*> screen bloomFragment
    <*> screen postFragment <*> particle GPU.WorldAdditive <*> particle GPU.WorldAlpha
  kin <- traverse (prepareGeometry renderer . Mesh.kinSculpture) (Map.fromList [(key, key) | key <- [Jade, Rose, Azure, Honey]])
  enemies <- traverse (prepareGeometry renderer . Mesh.enemySculpture) (Map.fromList [(key, key) | key <- [Wanderer .. SkyMoth]])
  relic <- prepareGeometry renderer Mesh.relicGeometry
  cube <- either (fail . show) (GPU.createMesh renderer) particleCube
  targetFormat <- selectTargetFormat renderer
  NativeScene window renderer programs <$> newIORef (PreparedChunks (-1) Map.empty []) <*> newIORef False
    <*> newIORef Nothing <*> pure targetFormat <*> pure kin <*> pure enemies <*> pure relic <*> pure cube

shaderLimits :: IO (FragmentShader, FragmentShader, FragmentShader)
shaderLimits = case (loopLimit 24, loopLimit 16, loopLimit 12, uniformSlot 0) of
  (Just clouds, Just ao, Just scatter, Just tint) -> pure
    (skyFragment clouds, effectsFragment ao scatter, FragmentShader (Multiply InterpolatedColor (Uniform tint)))
  _ -> fail "Afterlight shader limits exceed the native shader contract"

writeNativeShaderBinaries :: FilePath -> IO ()
writeNativeShaderBinaries directory = do
  (sky, effects, flat) <- shaderLimits
  let write name shader = do
        let path = directory ++ "/" ++ name
        let binary = Lazy.toStrict (Builder.toLazyByteString (foldMap Builder.word32LE shader))
        present <- doesFileExist path
        same <- if present then (== binary) <$> BS.readFile path else pure False
        unless same (BS.writeFile path binary)
  write "voxel.vert.spv" (compileVertexShader worldVertex)
  forM_ [("voxel", worldFragment), ("sky", sky), ("effects", effects), ("bloom", bloomFragment), ("post", postFragment), ("flat", flat)] $
    \(name, shader) -> write (name ++ ".frag.spv") (compileFragmentShader shader)

selectTargetFormat :: GPU.Renderer -> IO GPU.TargetFormat
selectTargetFormat renderer = do
  target <- try (GPU.createRenderTarget renderer GPU.RGBA16Float 4 4)
  case target of
    Right value -> GPU.destroyRenderTarget renderer value >> pure GPU.RGBA16Float
    Left (GPU.TargetFormatUnavailable GPU.RGBA16Float) -> do
      putStrLn "garden renderer: RGBA16F unavailable; linear RGBA8 fallback"
      pure GPU.RGBA8
    Left failure -> throwIO failure

nativeSceneMetrics :: NativeScene -> IO (Maybe GPU.FrameMetrics)
nativeSceneMetrics = GPU.rendererLastMetrics . sceneRenderer

nativeSceneAdapterName :: NativeScene -> String
nativeSceneAdapterName = GPU.rendererAdapterName . sceneRenderer

-- The renderer is borrowed within the withNativeScene scope on its window thread.
nativeSceneRenderer :: NativeScene -> GPU.Renderer
nativeSceneRenderer = sceneRenderer

warmNativeScene :: NativeScene -> SceneView -> IO ()
warmNativeScene = syncChunks

beginNativeChunkLoading :: NativeScene -> SceneView -> IO NativeChunkLoading
beginNativeChunkLoading native view = mask_ $ do
  PreparedChunks revision already _ <- readIORef (sceneNativeChunks native)
  unless (revision == -1 && Map.null already) $
    fail "Initial Afterlight chunk loading requires a fresh renderer"
  busy <- atomicModifyIORef' (sceneLoadingClaim native) (\current -> (True, current))
  when busy (fail "Afterlight initial chunk loading is already active")
  let groups = Map.toList (groupCells (sceneCells view))
  (NativeChunkLoading native view (length groups) <$> newIORef (0, groups))
    `onException` writeIORef (sceneLoadingClaim native) False

nativeChunkLoadingProgress :: NativeChunkLoading -> IO (Int, Int)
nativeChunkLoadingProgress (NativeChunkLoading _ _ total pending) = do
  (loaded, _) <- readIORef pending
  pure (loaded, total)

stepNativeChunkLoading :: Double -> NativeChunkLoading -> IO Bool
stepNativeChunkLoading budget (NativeChunkLoading native view _ pending) = mask_ $ do
  began <- getMonotonicTimeNSec
  let secondsSince now = fromIntegral (now - began) / 1000000000
  let cells = sceneCells view
  let advance = do
        (done, remaining) <- readIORef pending
        case remaining of
          [] -> do
            modifyIORef' (sceneNativeChunks native) (\(PreparedChunks _ chunks _) ->
              PreparedChunks (sceneRevision view) chunks (lightsFor cells))
            writeIORef (sceneLoadingClaim native) False
            pure True
          (key, contents) : rest -> do
            meshes <- prepareGeometry (sceneRenderer native)
              (Mesh.terrainGeometry cells contents <> Mesh.ornamentGeometry cells contents)
            modifyIORef' (sceneNativeChunks native) (\(PreparedChunks revision chunks lights) ->
              PreparedChunks revision (Map.insert key meshes chunks) lights)
            writeIORef pending (done + 1, rest)
            now <- getMonotonicTimeNSec
            if null rest || secondsSince now < max 0.001 budget then advance else pure False
  advance

drawNativeScene :: NativeScene -> RenderSettings -> Maybe Photo -> SceneView -> Float -> [GPU.OverlayBatch] -> IO GPU.FrameStatus
drawNativeScene native settings portrait view pulse ui = do
  frame <- prepareFrame native settings portrait view pulse ui
  maybe (pure GPU.FrameMinimized) (uncurry (GPU.renderPasses (sceneRenderer native))) frame

readNativeScene :: NativeScene -> RenderSettings -> Maybe Photo -> SceneView -> Float -> [GPU.OverlayBatch]
                -> IO (GPU.FrameStatus, Maybe GPU.FramePixels)
readNativeScene native settings portrait view pulse ui = do
  frame <- prepareFrame native settings portrait view pulse ui
  maybe (pure (GPU.FrameMinimized, Nothing)) (uncurry (GPU.renderPassesReadback (sceneRenderer native))) frame

prepareFrame :: NativeScene -> RenderSettings -> Maybe Photo -> SceneView -> Float -> [GPU.OverlayBatch]
             -> IO (Maybe ([GPU.RenderPass], GPU.Frame))
prepareFrame native settings portrait view pulse ui = do
  screen@(width, height) <- windowFramebufferSize (sceneWindow native)
  if width == 0 || height == 0
    then pure Nothing
    else do
      syncChunks native view
      let chosen = settings { bloom = bloom settings && maybe True photoBloom portrait }
      let plan = renderPlan screen chosen
      targets <- ensureTargets native plan
      camera <- cameraFor portrait view (sceneSize plan)
      let lighting = lightFor view
      let shadowsFor sizes = do
            near <- shadowCamera (lightSun lighting) (viewEye camera) (viewForward camera) 112 (fst sizes)
            far <- shadowCamera (lightSun lighting) (viewEye camera) (viewForward camera) 360 (snd sizes)
            pure (near, far)
      shadowViews <- traverse shadowsFor (shadowSize plan)
      chunks@(PreparedChunks _ _ lamps) <- readIORef (sceneNativeChunks native)
      let programs = scenePrograms native
      let casters = sceneActors native view
      let terrain accepts = [mesh | (key, meshes) <- visibleMeshes chunks, accepts key, mesh <- meshes]
      let visibleTerrain = terrain (visibleChunk (viewEye camera) (viewForward camera) (viewRight camera) (viewUp camera)
            (viewLens camera) (viewAspect camera))
      let shadowPass target (ShadowView matrix accepts) =
            let solid = [GPU.WorldMeshes group Nothing matrix | Just group <- [NonEmpty.nonEmpty (terrain accepts)]]
                actors = [GPU.WorldDraw mesh Nothing (GPU.multiplyMat4 matrix model) | Object mesh model _ <- casters]
            in GPU.RenderPass target (GPU.Frame white (solid ++ actors) [])
      let shadowPasses = case (targetShadow targets, shadowViews) of
            (Just (near, far), Just (nearView, farView)) -> [shadowPass near nearView, shadowPass far farView]
            _ -> []
      let shadowInputs = case targetShadow targets of
            Just (near, far) -> [(Texture1, GPU.renderTargetDepth near), (Texture2, GPU.renderTargetDepth far)]
            Nothing -> []
      let shadowMatrices = case shadowViews of
            Just (ShadowView near _, ShadowView far _) -> GPU.mat4Columns near ++ GPU.mat4Columns far
            Nothing -> GPU.mat4Columns GPU.identityMat4 ++ GPU.mat4Columns GPU.identityMat4
      let shadowsOn = if null shadowInputs then 0 else 1
      let texels = case shadowSize plan of
            Just (near, far) -> GPU.Vec4 shadowsOn (1 / fromIntegral near) (1 / fromIntegral far) 0
            Nothing -> GPU.Vec4 0 0 0 0
      let common = commonParameters lighting camera view
      let lampParameters = take 8 ([vec4 lamp 1 | lamp <- sortOn (distance (sceneEye view)) lamps] ++ repeat zero4)
      let lightingInputs model normal = GPU.ShaderInputs shadowInputs
            (common ++ GPU.mat4Columns model ++ GPU.mat4Columns normal ++ shadowMatrices ++ lampParameters ++ [texels])
      let worldDraw (Object mesh model normal) = GPU.WorldDrawWith mesh (opaqueProgram programs)
            (lightingInputs model normal)
            (GPU.multiplyMat4 (viewProjection camera) model)
      let terrainDraw = [GPU.WorldMeshesWith group (opaqueProgram programs)
            (lightingInputs GPU.identityMat4 GPU.identityMat4) (viewProjection camera)
            | Just group <- [NonEmpty.nonEmpty visibleTerrain]]
      let skyParams = common ++
            [size4 (skySize plan) (viewAspect camera) (viewLens camera)
            , vec4 (viewForward camera) (fromIntegral (cloudSteps plan))
            , vec4 (viewRight camera) 0, vec4 (viewUp camera) 0]
      let skyPass = GPU.RenderPass (targetSky targets) $ GPU.Frame black []
            [screenMaterial (skyProgram programs) [] skyParams (skySize plan)]
      let skyBackground = GPU.OverlayBatch (Just (GPU.renderTargetTexture (targetSky targets))) (screenQuad (sceneSize plan))
      let worldPass = GPU.RenderPass (targetScene targets) $
            GPU.FrameWithBackground black [skyBackground]
              (terrainDraw ++ map worldDraw casters ++ sceneParticles native camera view) []
      let effectPasses = case (targetEffects targets, effectsSize plan) of
            (Just target, Just size) ->
              let parameters = common ++ [size4 size 0 0] ++ GPU.mat4Columns (viewInverse camera) ++ shadowMatrices
                    ++ [ GPU.Vec4 (fromIntegral (occlusionSamples plan)) shadowsOn 0 0
                       , size4 (sceneSize plan) (viewLens camera) (viewAspect camera)
                       , GPU.Vec4 0.1 520 0 0]
                  textures = (Texture0, GPU.renderTargetDepth (targetScene targets)) : shadowInputs
              in [GPU.RenderPass target (GPU.Frame white [] [screenMaterial (effectsProgram programs) textures parameters size])]
            _ -> []
      let bloomPasses = case (targetBloom targets, bloomSize plan) of
            (Just (first, second), Just size@(w, h)) ->
              let hdr = if sceneTargetFormat native == GPU.RGBA16Float then 1 else 0
                  blur source target parameters = GPU.RenderPass target $ GPU.Frame black []
                    [screenMaterial (bloomProgram programs) [(Texture0, GPU.renderTargetTexture source)] [parameters] size]
              in [blur (targetScene targets) first (GPU.Vec4 (1 / fromIntegral w) 0 1 hdr)
                 ,blur first second (GPU.Vec4 0 (1 / fromIntegral h) 0 hdr)]
            _ -> []
      let textures = [(Texture0, GPU.renderTargetTexture (targetScene targets))
                     ,(Texture3, GPU.renderTargetDepth (targetScene targets))]
            ++ [(Texture1, GPU.renderTargetTexture target) | Just target <- [targetEffects targets]]
            ++ [(Texture2, GPU.renderTargetTexture target) | Just (_, target) <- [targetBloom targets]]
      let hasEffects = maybe 0 (const 1) (targetEffects targets)
      let hasBloom = maybe 0 (const 1) (targetBloom targets)
      let exposure = maybe 0 photoExposure portrait
      let grade = maybe 0 (fromIntegral . fromEnum . photoGrade) portrait
      let photoGlow = if maybe True photoBloom portrait then 1 else 0
      let vignette = if maybe True photoVignette portrait then 0.10 else 0
      let postParams = [inverseSize (sceneSize plan) exposure grade
                       ,GPU.Vec4 vignette hasEffects hasBloom photoGlow
                       ,inverseSize (maybe (1, 1) id (effectsSize plan)) 0 0]
      let final = GPU.Frame black [] (screenMaterial (postProgram programs) textures postParams screen :
            flashes screen view pulse ++ ui)
      pure (Just (shadowPasses ++ [skyPass, worldPass] ++ effectPasses ++ bloomPasses, final))

screenMaterial :: GPU.Material -> [(TextureSlot, GPU.Texture)] -> [GPU.Vec4] -> (Int, Int) -> GPU.OverlayBatch
screenMaterial program textures params size =
  GPU.OverlayBatchWith Nothing program (GPU.ShaderInputs textures params) (screenQuad size)

ensureTargets :: NativeScene -> RenderPlan -> IO Targets
ensureTargets native plan = mask_ $ do
  previous <- readIORef (sceneNativeTargets native)
  case previous of
    Just existing | targetPlan existing == plan -> pure existing
    _ -> do
      cleanup <- newIORef []
      let renderer = sceneRenderer native
      let release = GPU.destroyRenderTarget renderer
      let own format (w, h) = do
            target <- GPU.createRenderTarget renderer format w h
            modifyIORef' cleanup (release target :)
            pure target
      let sceneFormat = sceneTargetFormat native
      let make = Targets plan <$> own sceneFormat (sceneSize plan) <*> own sceneFormat (skySize plan)
            <*> traverse (\(near, far) -> (,) <$> own GPU.RGBA8 (near, near) <*> own GPU.RGBA8 (far, far)) (shadowSize plan)
            <*> traverse (own GPU.RGBA8) (effectsSize plan)
            <*> traverse (\size -> (,) <$> own sceneFormat size <*> own sceneFormat size) (bloomSize plan)
      replacement <- make `onException` (readIORef cleanup >>= releaseAll)
      writeIORef (sceneNativeTargets native) (Just replacement)
      forM_ previous $ \old -> releaseAll $ map release
        ([targetScene old, targetSky old] ++ paired (targetShadow old) ++ maybe [] pure (targetEffects old) ++ paired (targetBloom old))
      pure replacement
  where
    paired = maybe [] (\(first, second) -> [first, second])

syncChunks :: NativeScene -> SceneView -> IO ()
syncChunks native view = mask $ \restore -> do
  loading <- readIORef (sceneLoadingClaim native)
  when loading (fail "Complete Afterlight initial chunk loading before rendering")
  PreparedChunks revision old _ <- readIORef (sceneNativeChunks native)
  if revision == sceneRevision view
    then pure ()
    else do
      let cells = sceneCells view
      let grouped = groupCells cells
      let rebuild = revision < 0 || sceneRevision view < revision
      let changed = if rebuild then Map.keys (Map.union grouped (Map.map (const []) old))
            else Set.toList (changedSince revision (sceneEdits view))
      let entries key = if rebuild then Map.findWithDefault [] key grouped else
            [(cell, material) | cell <- chunkCells key, Just material <- [Map.lookup cell cells]]
      let prepare key = do
            let contents = entries key
            meshes <- prepareGeometry renderer (Mesh.terrainGeometry cells contents <> Mesh.ornamentGeometry cells contents)
            pure (key, meshes)
      fresh <- restore (acquireMany prepare (releaseMeshes . snd) changed)
      let current = Map.filter (not . null) (Map.union (Map.fromList fresh) old)
      writeIORef (sceneNativeChunks native) (PreparedChunks (sceneRevision view) current (lightsFor cells))
      releaseMeshes (concatMap (\key -> Map.findWithDefault [] key old) changed)
  where
    renderer = sceneRenderer native
    releaseMeshes = releaseAll . map (GPU.destroyMesh renderer)

groupCells :: Map.Map Cell Material -> Map.Map Chunk [(Cell, Material)]
groupCells cells = Map.fromListWith (<>)
  [(chunkOf cell, [(cell, material)]) | (cell, material) <- Map.toList cells]

lightsFor :: Map.Map Cell Material -> [V3]
lightsFor cells = Map.elems $ Map.fromList
  [((x `div` 3, y `div` 3, z `div` 3), center cell)
  | (cell@(Cell x y z), Luminous) <- Map.toList cells]

visibleMeshes :: PreparedChunks -> [(Chunk, [GPU.Mesh])]
visibleMeshes (PreparedChunks _ chunks _) = Map.toList chunks

prepareGeometry :: GPU.Renderer -> Mesh.Geometry -> IO [GPU.Mesh]
prepareGeometry renderer = acquireMany prepare (GPU.destroyMesh renderer) . groups
  where
    groups [] = []
    groups values = let (first, rest) = splitAt 24000 values in first : groups rest
    prepare geometry = do
      let convert (Mesh.Vertex position normal color emission ambient material) =
            GPU.VertexWithNormal (vec3 position) (GPU.Vec2 emission material) (paletteColor color ambient) (vec3 normal)
      mesh <- either (fail . show) pure (GPU.meshData (map convert geometry) [0 .. fromIntegral (length geometry) - 1])
      GPU.createMesh renderer mesh

acquireMany :: (a -> IO b) -> (b -> IO ()) -> [a] -> IO [b]
acquireMany _ _ [] = pure []
acquireMany acquire release (first : rest) =
  bracketOnError (acquire first) release $ \value ->
    (value :) <$> acquireMany acquire release rest

releaseAll :: [IO ()] -> IO ()
releaseAll = foldr finally (pure ())

data Object = Object !GPU.Mesh !GPU.Mat4 !GPU.Mat4

sceneActors :: NativeScene -> SceneView -> [Object]
sceneActors native view = relic ++ kin ++ enemies
  where
    time = sceneTime view
    relic = objects (sceneRelicMesh native) (V3 0 62 54) (rotateZ (sin (time * 0.04) * 12 * pi / 180)) 0.48
    kin = concat
      [objects (Map.findWithDefault [] gem (sceneKinMeshes native))
        (plus position (V3 0 (0.14 + 0.12 * sin (time * 1.15 + fromIntegral (fromEnum gem))) 0))
        (face position) 0.13
      | KinView position gem _ _ <- sceneKin view]
    enemies = concat
      [objects (Map.findWithDefault [] kind (sceneEnemyMeshes native))
        (plus position (V3 (if windup > 0 then sin (time * 40) * 0.08 else 0) 0 0)) (face position) 0.14
      | EnemyView position _ windup kind <- sceneEnemies view]
    face position = let V3 dx _ dz = minus (sceneEye view) position in GPU.rotateYMat4 (atan2 (-dx) (-dz))
    objects meshes position orientation size =
      let model = modelMatrix position orientation (V3 size size size)
      in [Object mesh model orientation | mesh <- meshes]

sceneParticles :: NativeScene -> CameraView -> SceneView -> [GPU.WorldDraw]
sceneParticles native camera view = kin ++ enemies ++ atmosphere ++ beacon ++ bursts ++ target
  where
    time = sceneTime view
    mesh = sceneParticleMesh native
    programs = scenePrograms native
    draw material position size tint = GPU.WorldDrawWith mesh material (GPU.ShaderInputs [] [color4 tint])
      (GPU.multiplyMat4 (viewProjection camera) (modelMatrix position GPU.identityMat4 size))
    additive = draw (particleProgram programs)
    alpha = draw (burstProgram programs)
    cube x = V3 x x x
    kin =
      [additive (plus pos (V3 (cos angle * radius) (1.4 + wave + sin (angle * 2) * 0.16) (sin angle * radius)))
        (cube (if bond > 0 then 0.065 else 0.035)) (paletteColor (Mesh.palette (Ore gem)) (if safe then 0.8 else 0.45))
      | KinView pos gem bond safe <- sceneKin view, i <- [0..11 :: Int]
      , let wave = 0.12 * sin (time * 1.15 + fromIntegral (fromEnum gem))
      , let angle = fromIntegral i * pi / 6 + time * 0.32
      , let radius = if safe then 1.4 else 0.85]
    enemies =
      [additive (plus pos (V3 (cos angle * radius) 0.1 (sin angle * radius))) (V3 0.22 0.045 0.22)
        (bytes 255 71 86 (round ((0.4 + 0.3 * sin (time * 24)) * 255)))
      | EnemyView pos _ windup kind <- sceneEnemies view, windup > 0, i <- [0..23 :: Int]
      , let angle = fromIntegral i * pi / 12
      , let radius = case kind of Wanderer -> 2.9; Custodian -> 3.9; Skitter -> 2.4; SkyMoth -> 3.1]
    atmosphere =
      [additive position (V3 s (s * 1.4) s) (bytes 173 241 212 (round (35 + 80 * (0.5 + 0.5 * sin (time + fi)))))
      | i <- [0..145 :: Int], let fi = fromIntegral i
      , let position = V3 (fromIntegral ((i * 71) `mod` 103) - 51 + sin (time * 0.18 + fi) * 0.7)
              (3 + fromIntegral (i `mod` 15) * 0.85)
              (fromIntegral ((i * 43) `mod` 122) - 40 + cos (time * 0.25 + fi) * 0.6)
      , distance (sceneEye view) position < 65
      , let s = 0.025 + fromIntegral (i `mod` 3) * 0.019]
    beacon =
      [additive (V3 (cos angle * radius) height (54 + sin angle * radius))
        (V3 0.12 0.46 0.12) (bytes 255 219 141 (if sceneFlight view then 225 else 80))
      | i <- [0..54 :: Int], let fi = fromIntegral i
      , let angle = fi * 2.399 + time * 0.06
      , let height = 48 + fi * 0.45 + sin (time * 0.2 + fi) * 0.2
      , let radius = 1.8 + fi * 0.04]
    bursts =
      [alpha (plus (burstOrigin burst) (V3 (cos angle * age * 2.4)
                (age * (1.0 + fromIntegral (i `mod` 4)) - 2.4 * age * age) (sin angle * age * 2.4)))
        (cube (max 0.01 (0.12 * (1 - age / 1.15)))) (burstColor (burstCue burst))
      | burst <- sceneBursts view, let age = time - fromIntegral (unTick (burstBorn burst)) / 60
      , age >= 0 && age < 1.15, i <- [0..16 :: Int], let angle = fromIntegral i * 2.399]
    burstColor cue = case cue of Wound -> bytes 255 83 103 210; Jewel -> bytes 119 251 209 240; _ -> bytes 255 223 147 230
    target = case sceneTarget view of
      TerrainTarget cell _ material _ ->
        let (width, tint) = case material of
              Ore gem -> (1.014, paletteColor (Mesh.palette (Ore gem)) 0.82)
              _ -> (1.012, bytes 232 224 167 150)
        in [alpha (plus (center cell) offset) dimensions tint | (offset, dimensions) <- wireEdges width]
      _ -> []

wireEdges :: Float -> [(V3, V3)]
wireEdges width =
  [(V3 0 a b, V3 width stroke stroke) | a <- edges, b <- edges] ++
  [(V3 a 0 b, V3 stroke width stroke) | a <- edges, b <- edges] ++
  [(V3 a b 0, V3 stroke stroke width) | a <- edges, b <- edges]
  where
    edges = [-width / 2, width / 2]
    stroke = 0.008

particleCube :: Either GPU.PlanError GPU.MeshData
particleCube = GPU.meshData
  [GPU.Vertex x y z 0 0 white | z <- [-0.5, 0.5], y <- [-0.5, 0.5], x <- [-0.5, 0.5]]
  [0,1,2,2,1,3, 4,6,5,5,6,7, 0,4,1,1,4,5, 2,3,6,6,3,7
  ,0,2,4,4,2,6, 1,5,3,3,5,7]

data CameraView = CameraView
  { viewEye :: !V3
  , viewForward :: !V3
  , viewRight :: !V3
  , viewUp :: !V3
  , viewLens :: !Float
  , viewAspect :: !Float
  , viewProjection :: !GPU.Mat4
  , viewInverse :: !GPU.Mat4
  }

cameraFor :: Maybe Photo -> SceneView -> (Int, Int) -> IO CameraView
cameraFor portrait scene (width, height) = do
  let position = sceneEye scene
  let forward = unit (sceneForward scene)
  let (right, up) = photoBasis (maybe 0 photoRoll portrait) forward
  let fov = maybe 68 photoFov portrait * pi / 180
  let aspect = fromIntegral width / fromIntegral height
  let lens = tan (fov / 2)
  view <- checked (GPU.lookAtMat4 (vec3 position) (vec3 (plus position forward)) (vec3 up))
  projection <- checked (GPU.perspectiveMat4 fov aspect 0.1 520)
  let viewInverseMatrix = GPU.mat4FromColumns (vec4 right 0) (vec4 up 0) (vec4 (scale (-1) forward) 0) (vec4 position 1)
  let invProjection = inversePerspective lens aspect 0.1 520
  pure (CameraView position forward right up lens aspect (GPU.multiplyMat4 projection view)
    (GPU.multiplyMat4 viewInverseMatrix invProjection))

inversePerspective :: Float -> Float -> Float -> Float -> GPU.Mat4
inversePerspective lens aspect near far = GPU.mat4FromColumns
  (GPU.Vec4 (lens * aspect) 0 0 0)
  (GPU.Vec4 0 (-lens) 0 0)
  (GPU.Vec4 0 0 0 (1 / shift))
  (GPU.Vec4 0 0 (-1) (depth / shift))
  where
    depth = far / (near - far)
    shift = near * depth

data ShadowView = ShadowView !GPU.Mat4 !(Chunk -> Bool)

shadowCamera :: V3 -> V3 -> V3 -> Float -> Int -> IO ShadowView
shadowCamera sun position eyeForward extent resolution = do
  let forward = scale (-1) sun
  let right = unit (cross3 forward (V3 0 1 0))
  let up = cross3 right forward
  let focus = plus position (scale 32 eyeForward)
  let pitch = extent / fromIntegral resolution
  let snap value = fromIntegral (round (value / pitch) :: Int) * pitch - value
  let snapped = plus focus (plus (scale (snap (dot focus right)) right) (scale (snap (dot focus up)) up))
  let eye = plus snapped (scale 300 sun)
  let visible key =
        let delta = minus (chunkCenter key) eye
            depth = dot delta forward
            bound = extent / 2 + chunkRadius
        in abs (dot delta right) <= bound && abs (dot delta up) <= bound &&
           depth >= 0.1 - chunkRadius && depth <= 700 + chunkRadius
  view <- checked (GPU.lookAtMat4 (vec3 eye) (vec3 snapped) (vec3 up))
  projection <- checked (GPU.orthographicMat4 extent 1 0.1 700)
  pure (ShadowView (GPU.multiplyMat4 projection view) visible)

data Lighting = Lighting
  { lightNight :: !Float
  , lightSun :: !V3
  , lightEnergy :: !V3
  , lightAmbient :: !V3
  }

lightFor :: SceneView -> Lighting
lightFor view = Lighting night sun energy ambient
  where
    ramp = max 0 (min 1 ((sceneVeil view - 0.35) / (0.94 - 0.35)))
    night = ramp * ramp * (3 - 2 * ramp)
    sunset = sin (night * pi)
    mix amount a b = plus (scale (1 - amount) a) (scale amount b)
    sun = unit (mix night (V3 (-0.55 - sunset * 0.25) (0.78 - sunset * 0.47) (0.32 + sunset * 0.1)) (V3 0.38 0.70 (-0.56)))
    energy = mix night (mix sunset (V3 3.4 3.10 2.45) (V3 3.5 1.62 0.63)) (V3 0.25 0.38 0.68)
    ambient = mix night (V3 0.26 0.38 0.48) (V3 0.03 0.05 0.09)

commonParameters :: Lighting -> CameraView -> SceneView -> [GPU.Vec4]
commonParameters lighting camera scene =
  [vec4 (lightSun lighting) (lightNight lighting), vec4 (lightEnergy lighting) (sceneTime scene)
  ,vec4 (lightAmbient lighting) 0, vec4 (viewEye camera) 0]

flashes :: (Int, Int) -> SceneView -> Float -> [GPU.OverlayBatch]
flashes size view pulse = pulsed ++ returns ++ wounds
  where
    pulsed = [gradient size (bytes 113 233 192 (round (pulse * 13))) (bytes 243 223 148 0) | pulse > 0.04]
    returns = [gradient size tint tint | burst <- sceneBursts view, burstCue burst == Return
      , let age = sceneTime view - fromIntegral (unTick (burstBorn burst)) / 60
      , let opacity = max 0 (1 - age / 1.3), opacity > 0
      , let tint = bytes 248 246 224 (round (255 * opacity * opacity))]
    wounds = [gradient size (bytes 190 34 65 (round (opacity * 110))) (bytes 190 34 65 0)
      | burst <- sceneBursts view, burstCue burst == Wound
      , let age = sceneTime view - fromIntegral (unTick (burstBorn burst)) / 60
      , let opacity = max 0 (1 - age / 0.42), opacity > 0]

gradient :: (Int, Int) -> GPU.Color -> GPU.Color -> GPU.OverlayBatch
gradient size top bottom = GPU.OverlayBatch Nothing (quad size top bottom)

screenQuad :: (Int, Int) -> [GPU.Vertex]
screenQuad size = quad size white white

quad :: (Int, Int) -> GPU.Color -> GPU.Color -> [GPU.Vertex]
quad (width, height) top bottom = [a,b,c,a,c,d]
  where
    w = fromIntegral width
    h = fromIntegral height
    a = GPU.Vertex 0 0 0 0 0 top
    b = GPU.Vertex w 0 0 1 0 top
    c = GPU.Vertex w h 0 1 1 bottom
    d = GPU.Vertex 0 h 0 0 1 bottom

paletteColor :: Mesh.RGB -> Float -> GPU.Color
paletteColor (Mesh.RGB red green blue) alpha = bytes (channel red) (channel green) (channel blue) (channel alpha)
  where channel = round . (* 255) . max 0 . min 1

bytes :: Int -> Int -> Int -> Int -> GPU.Color
bytes r g b a = GPU.Color (normal r) (normal g) (normal b) (normal a)
  where normal n = fromIntegral (max 0 (min 255 n)) / 255

white, black :: GPU.Color
white = GPU.Color 1 1 1 1
black = GPU.Color 0 0 0 1

color4 :: GPU.Color -> GPU.Vec4
color4 (GPU.Color r g b a) = GPU.Vec4 r g b a

vec3 :: V3 -> GPU.Vec3
vec3 (V3 x y z) = GPU.Vec3 x y z

vec4 :: V3 -> Float -> GPU.Vec4
vec4 (V3 x y z) = GPU.Vec4 x y z

zero4 :: GPU.Vec4
zero4 = GPU.Vec4 0 0 0 0

size4, inverseSize :: (Int, Int) -> Float -> Float -> GPU.Vec4
size4 (width, height) z w = GPU.Vec4 (fromIntegral width) (fromIntegral height) z w
inverseSize (width, height) z w = GPU.Vec4 (1 / fromIntegral width) (1 / fromIntegral height) z w

cross3 :: V3 -> V3 -> V3
cross3 (V3 x y z) (V3 a b c) = V3 (y*c - z*b) (z*a - x*c) (x*b - y*a)

modelMatrix :: V3 -> GPU.Mat4 -> V3 -> GPU.Mat4
modelMatrix position orientation size = GPU.multiplyMat4 (GPU.translateMat4 (vec3 position))
  (GPU.multiplyMat4 orientation (GPU.scaleMat4 (vec3 size)))

rotateZ :: Float -> GPU.Mat4
rotateZ angle = GPU.mat4FromColumns
  (GPU.Vec4 (cos angle) (sin angle) 0 0) (GPU.Vec4 (-sin angle) (cos angle) 0 0)
  (GPU.Vec4 0 0 1 0) (GPU.Vec4 0 0 0 1)

checked :: Show error => Either error a -> IO a
checked = either (fail . show) pure
