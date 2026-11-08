{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}

-- The Windows material programs use the same equations and thresholds as the
-- existing Afterlight shader assets. Vulkan framebuffer UV starts at top left,
-- and projection depth already lies in [0,1].
module Garden.Render.NativeShaders
  ( worldVertex
  , worldFragment
  , skyFragment
  , effectsFragment
  , bloomFragment
  , postFragment
  ) where

import Data.Word (Word32)
import GameIO.Graphics.Plan (Mat4, Vec2, Vec3, Vec4(..))
import GameIO.Graphics.Shader

type Scalar local stage = Expr local stage Float
type Vector2E local stage = Expr local stage Vec2
type Vector3E local stage = Expr local stage Vec3
type Vector4E local stage = Expr local stage Vec4
type Fragment = 'FragmentStage

newtype Build local stage result a = Build ((a -> Expr local stage result) -> Expr local stage result)

instance Functor (Build local stage result) where
  fmap f (Build run) = Build (\use -> run (use . f))

instance Applicative (Build local stage result) where
  pure a = Build (\use -> use a)
  Build apply <*> Build argument = Build (\use -> apply (\f -> argument (use . f)))

instance Monad (Build local stage result) where
  Build run >>= next = Build (\use -> run (\a -> let Build action = next a in action use))

share :: Expr local stage a -> Build local stage result (Expr local stage a)
share expr = Build (letExpr expr)

build :: Build local stage result (Expr local stage result) -> Expr local stage result
build (Build run) = run id

worldVertex :: VertexShader
worldVertex = WorldVertexShader
  (Transform (Homogeneous VertexPosition))
  VertexUV VertexColor
  (rgb (MatrixVector (matrix 4) (Homogeneous VertexPosition)))
  (Normalize Vector3 (rgb (MatrixVector (matrix 8) (rgba VertexNormal 0))))

worldFragment :: FragmentShader
worldFragment = FragmentShader $ build $ do
  position <- share InterpolatedPosition
  normal <- share (Normalize Vector3 InterpolatedNormal)
  eyeRay <- share (Normalize Vector3 (sub3 eye position))
  base <- share (pow3 (max3 (rgb InterpolatedColor) (v3 0 0 0)) (splat3 2.2))
  grain <- share (UnsignedFloat (UnsignedBinary AndBits (grainHash (scale3 position 18)) (UnsignedLiteral 1023)) ./. 1023)
  albedo <- share (scale3 base (0.95 .+. 0.10 .*. grain))
  let surfaceClass = Component Y2 InterpolatedUV
  let surfaceEmission = Component X2 InterpolatedUV
  let material n = 1 .-. smooth 0.01 0.1 (absolute (surfaceClass .-. n))
  metal <- share (material 1)
  water <- share (material 2)
  leaf <- share (material 3)
  ao <- share (clamp (Component W4 InterpolatedColor) 0 1)
  nl <- share (maxF 0 (Dot Vector3 normal sunDirection))
  lit <- share (shadowVisibility position normal nl)
  let wrap = 0.25 .+. 0.75 .*. maxF 0 (Component Y3 normal)
  let skyAmbient = scale3 skyRadiance ((0.65 .+. wrap .*. 0.65) .*. ao)
  let groundAmbient = scale3 (v3 0.12 0.15 0.085) (maxF 0 (negateF (Component Y3 normal)) .*. (1 .-. night) .*. ao)
  let sunlight = scale3 sunRadiance (nl .*. lit .*. (1 .-. metal .*. 0.22))
  diffuse <- share (mul3 albedo (add3 (add3 skyAmbient groundAmbient) sunlight))
  halfVector <- share (Normalize Vector3 (add3 eyeRay sunDirection))
  let specularPower = mix 34 150 (metal .*. 0.65 .+. water .*. 0.35)
  let f0 = mix3 (v3 0.035 0.035 0.035) albedo (metal .*. 0.8)
  let fresnel = add3 f0 (scale3 (sub3 (v3 1 1 1) f0) (pow (1 .-. maxF 0 (Dot Vector3 eyeRay halfVector)) 5))
  let specular = scale3 (mul3 sunRadiance fresnel) (pow (maxF 0 (Dot Vector3 normal halfVector)) specularPower .*. lit .*. nl .*. 1.5)
  let subsurface = scale3 (mul3 albedo sunRadiance)
        (pow (maxF 0 (negateF (Dot Vector3 normal sunDirection))) 2 .*. leaf .*. 0.065 .*. lit)
  let ripples = 0.5 .+. 0.5 .*. sine (Component X3 position .*. 8 .+. time .*. 1.2
        .+. sine (Component Z3 position .*. 5 .-. time))
  let waterColor = If Float3 (both (greater water 0.1) (greater (Component Y3 normal) 0.5))
        (add3
          (scale3 skyRadiance (pow (1 .-. maxF 0 (Dot Vector3 normal eyeRay)) 3 .*. 0.45))
          (scale3 sunRadiance (pow ripples 24 .*. 0.015 .*. lit))) (v3 0 0 0)
  let lamps = foldl add3 (v3 0 0 0) [localLight slot position normal albedo | slot <- [20..27]]
  let emissive = scale3 albedo (surfaceEmission .*. (2.5 .+. night .*. 3.5))
  let fog = 1 .-. exponential (negateF (pow (Length Vector3 (sub3 position eye) .*. 0.0026) 1.35))
  let haze = mix3 (v3 0.42 0.59 0.66) (v3 0.023 0.045 0.092) night
  let litColor = foldl add3 diffuse [specular, subsurface, waterColor, lamps, emissive]
  pure (rgba (max3 (mix3 litColor haze fog) (v3 0 0 0)) 1)

localLight :: Word32 -> Vector3E local Fragment -> Vector3E local Fragment -> Vector3E local Fragment -> Vector3E local Fragment
localLight slot position normal albedo = build $ do
  lamp <- share (u slot)
  pure $ If Float3 (greater (Component W4 lamp) 0)
    (build $ do
      delta <- share (sub3 (rgb lamp) position)
      r2 <- share (maxF 0.04 (Dot Vector3 delta delta))
      let falloff = pow (maxF 0 (1 .-. r2 ./. 100)) 2 ./. (1 .+. r2 .*. 0.42)
      let facing = maxF 0 (Dot Vector3 normal (scale3 delta (inverseSqrt r2)))
      pure $ scale3 (mul3 albedo (v3 1.65 1.20 0.53))
        (falloff .*. (0.22 .+. 0.78 .*. facing) .*. (0.6 .+. night .*. 1.4)))
    (v3 0 0 0)

shadowVisibility :: Vector3E local Fragment -> Vector3E local Fragment -> Scalar local Fragment -> Scalar local Fragment
shadowVisibility position normal nl =
  If Float1 (greater (Component X4 (u 28)) 0)
    (build $ do
      receiver <- share (add3 position (scale3 normal 0.025))
      near <- share (lightProjection 12 receiver)
      far <- share (lightProjection 16 receiver)
      bias <- share (0.00006 .+. 0.00012 .*. (1 .-. nl))
      farLight <- share (If Float1 (within 0.003 0.997 far)
        (shadowAt Texture2 (Component Z4 (u 28)) far (bias .*. 2)) 1)
      let x = Component X3 near
      let y = Component Y3 near
      let z = Component Z3 near
      edge <- share (minF (minF x (1 .-. x)) (minF y (1 .-. y)))
      pure $ If Float1 (both (greater edge 0.003) (both (greater z 0) (less z 1)))
        (mix farLight (shadowAt Texture1 (Component Y4 (u 28)) near bias) (smooth 0.003 0.045 edge)) farLight)
    1

shadowAt :: TextureSlot -> Scalar local Fragment -> Vector3E local Fragment -> Scalar local Fragment -> Scalar local Fragment
shadowAt slot texel projected bias =
  foldl (.+.) 0 [sample x y | x <- [-1, 0, 1], y <- [-1, 0, 1]] ./. 9
  where
    threshold = Component Z3 projected .-. bias
    sample x y = step threshold (Component X4 (SampleAt slot (add2 (xy3 projected)
      (scale2 (v2 x y) texel))))

lightProjection :: Word32 -> Vector3E local Fragment -> Vector3E local Fragment
lightProjection index world =
  letExpr (MatrixVector (matrix index) (rgba world 1)) $ \clip ->
    letExpr (rgb (div4 clip (splat4 (Component W4 clip)))) $ \ndc ->
      MakeVec3 (Component X3 ndc .*. 0.5 .+. 0.5) (Component Y3 ndc .*. 0.5 .+. 0.5) (Component Z3 ndc)

skyFragment :: LoopLimit -> FragmentShader
skyFragment limit = FragmentShader $ build $ do
  let size = xy4 (u 4)
  let aspect = Component Z4 (u 4)
  let lens = Component W4 (u 4)
  let pixel = xy4 FragmentCoordinates
  let glPixel = MakeVec2 (Component X2 pixel) (Component Y2 size .-. Component Y2 pixel)
  let q = sub2 (scale2 (div2 glPixel size) 2) (v2 1 1)
  ray <- share $ Normalize Vector3 $ add3 (rgb (u 5))
    (scale3 (add3 (scale3 (rgb (u 6)) (Component X2 q .*. aspect)) (scale3 (rgb (u 7)) (Component Y2 q))) lens)
  let rayY = Component Y3 ray
  let elevation = maxF 0 rayY
  mu <- share (Dot Vector3 ray sunDirection)
  let lowSun = 1 .-. smooth 0.12 0.5 (Component Y3 sunDirection)
  let day = mix3 (v3 0.43 0.67 0.85) (v3 0.045 0.20 0.45) (pow elevation 0.47)
  let warmDay = mix3 day (v3 0.9 0.46 0.22) (lowSun .*. pow (1 .-. elevation) 4 .*. 0.65)
  let nightSky = mix3 (v3 0.032 0.055 0.13) (v3 0.003 0.009 0.029) (pow elevation 0.35)
  let halo = scale3 sunRadiance (pow (maxF 0 mu) 24 .*. 0.014 .+. pow (maxF 0 mu) 240 .*. 0.03)
  let sun = 1 .-. smooth 0.005 0.007 (Length Vector3 (sub3 ray sunDirection))
  clear <- share (foldl add3 (mix3 warmDay nightSky night) [halo, scale3 sunRadiance (sun .*. 4)])
  let steps = Component W4 (u 5)
  clouded <- share $ If Float3 (both (greater rayY 0.025) (greater steps 0))
    (letExpr (marchClouds limit ray glPixel mu steps) $ \acc ->
      mix3 clear (add3 (scale3 clear (Component W4 acc)) (rgb acc)) (smooth 0.025 0.10 rayY))
    clear
  let angle = atan2F (Component Z3 ray) (Component X3 ray)
  let sc = mul2 (MakeVec2 angle (arcSine rayY)) (v2 380 280)
  let cell = floor2 sc
  let inside = sub2 (fract2 sc) (v2 0.5 0.5)
  let star = step 0.996 (hash3 (append2 cell 17)) .*. (1 .-. smooth 0.01 0.13 (Length Vector2 inside))
        .*. smooth 0.02 0.22 rayY
  let ribbon = letExpr ((rayY .-. 0.45 .-. 0.09 .*.
        sine (angle .*. 3 .+. time .*. 0.015)) .*. 20) $ \height ->
          exponential (negateF (height .*. height))
  pure $ rgba (foldl add3 clouded [scale3 (v3 1.8 2 2.5) (star .*. night), scale3 (v3 0.015 0.08 0.07) (ribbon .*. night)]) 1

marchClouds :: LoopLimit -> Vector3E local Fragment -> Vector2E local Fragment -> Scalar local Fragment -> Scalar local Fragment -> Vector4E local Fragment
marchClouds limit ray pixel mu steps = build $ do
  jitter <- share (hash3 (append2 pixel 21))
  let rayY = Component Y3 ray
  let entry = 1.2 ./. rayY
  let stepSize = (0.068 .*. 20 ./. steps) ./. rayY
  let initial = Constant4 (Vec4 0 0 0 1)
  pure $ foldCount Float4 limit (CountFromFloat steps) initial $ \index acc -> build $ do
    t <- share (entry .+. (UnsignedFloat index .+. jitter) .*. stepSize)
    let shifted = add3 (scale3 ray (t .*. 1.2)) (MakeVec3 (time .*. 0.006) 0 (time .*. 0.002))
    position <- share (MakeVec3 (Component X3 shifted) (t .*. rayY .-. 1.2) (Component Z3 shifted))
    d <- share (density position)
    pure $ If Float4 (less d 0.001) acc $ build $ do
      extinction <- share (1 .-. exponential (negateF (d .*. (0.70 .*. 20 ./. steps))))
      shade <- share $ exponential $
        negateF (density (add3 position (scale3 sunDirection 0.20)) .*. 3.5
          .+. density (add3 position (scale3 sunDirection 0.45)) .*. 1.8)
      let lighting = add3
            (scale3 (add3 (v3 0.12 0.20 0.34) (scale3 sunRadiance (0.62 .*. pow shade 1.4))) (1 .-. night .*. 0.94))
            (scale3 sunRadiance (0.04 .*. pow (maxF 0 mu) 8 .*. shade))
      let transmission = Component W4 acc
      pure $ rgba (add3 (rgb acc) (scale3 lighting (transmission .*. extinction))) (transmission .*. (1 .-. extinction))

density :: Vector3E local Fragment -> Scalar local Fragment
density point = build $ do
  cell <- share (floor2 (scale2 (MakeVec2 (Component X3 point) (Component Z3 point)) 0.40))
  let cloud = foldl maxF (-4) [puff point (add2 cell (v2 x z)) | x <- [-1, 0, 1], z <- [-1, 0, 1]]
  let detail = (noise (scale3 point 5.7) .-. 0.5) .*. 0.27 .+.
        (noise (scale3 point 12.3) .-. 0.5) .*. 0.10
  let height = Component Y3 point
  pure $ maxF 0 (cloud .+. detail) .*. 3.8 .*. smooth 0.02 0.17 height .*. (1 .-. smooth 0.85 1.2 height)

puff :: Vector3E local Fragment -> Vector2E local Fragment -> Scalar local Fragment
puff point cell = build $ do
  seed <- share (hash3 (append2 cell 42))
  pure $ If Float1 (less seed 0.72) (-4) $ build $ do
    let offset z = 0.25 .+. 0.5 .*. hash3 (append2 cell z)
    let center = scale2 (add2 cell (MakeVec2 (offset 3) (offset 9))) (1 ./. 0.40)
    displacement <- share $ MakeVec3
      ((Component X3 point .-. Component X2 center) .*. 0.80)
      ((Component Y3 point .-. 0.48) .*. 2.3)
      ((Component Z3 point .-. Component Y2 center) .*. 0.85)
    pure $ foldl1 maxF
      [0.65 .+. seed .*. 0.35 .-. Length Vector3 displacement
      , 0.61 .-. Length Vector3 (add3 displacement (v3 0.65 0.12 0.1))
      , 0.56 .-. Length Vector3 (sub3 displacement (v3 0.58 0.08 0.23))]

noise :: Vector3E local Fragment -> Scalar local Fragment
noise point = build $ do
  cell <- share (FloatUnary Float3 FloorF point)
  fractional <- share (FloatUnary Float3 Fract point)
  let smoothed = mul3 (mul3 fractional fractional) (sub3 (v3 3 3 3) (scale3 fractional 2))
  f <- share smoothed
  let at x y z = hash3 (add3 cell (v3 x y z))
  let row y z = mix (at 0 y z) (at 1 y z) (Component X3 f)
  let plane z = mix (row 0 z) (row 1 z) (Component Y3 f)
  pure $ mix (plane 0) (plane 1) (Component Z3 f)

grainHash :: Vector3E local Fragment -> Expr local Fragment Word32
grainHash position = build $ do
  let channel at factor = UnsignedBinary MultiplyU
        (SignedBits (floorF (Component at position))) (UnsignedLiteral factor)
  hash <- share (UnsignedBinary Xor
    (UnsignedBinary Xor (channel X3 1597334677) (channel Y3 3812015801)) (channel Z3 2798796415))
  pure (UnsignedBinary Xor hash (UnsignedBinary RightShift hash (UnsignedLiteral 16)))

hash3 :: Vector3E local Fragment -> Scalar local Fragment
hash3 point = build $ do
  h <- share (UnsignedBinary MultiplyU (grainHash point) (UnsignedLiteral 2246822519))
  let shifted = UnsignedBinary Xor h (UnsignedBinary RightShift h (UnsignedLiteral 13))
  pure $ UnsignedFloat (UnsignedBinary AndBits shifted (UnsignedLiteral 0x00ffffff)) ./. 16777216

effectsFragment :: LoopLimit -> LoopLimit -> FragmentShader
effectsFragment aoLimit scatterLimit = FragmentShader $ build $ do
  let uv = div2 (xy4 FragmentCoordinates) (xy4 (u 4))
  depth <- share (depthAt Texture0 uv)
  let homogeneous = MatrixVector (matrix 5) (append2Depth (sub2 (scale2 uv 2) (v2 1 1)) (minF depth 0.99999))
  position <- share (letExpr homogeneous (\clip -> scale3 (rgb clip) (1 ./. Component W4 clip)))
  delta <- share (sub3 position eye)
  distance <- share (Length Vector3 delta)
  ray <- share (scale3 delta (1 ./. maxF 0.001 distance))
  let sampleCount = Component X4 (u 17)
  ao <- share $ If Float1
    (both (less depth 0.99998) (both (less distance 95) (greater sampleCount 0)))
    (ambientOcclusion aoLimit sampleCount uv) 1
  let lengthStep = minF distance 155 ./. 12
  let jitter = fract (52.9829189 .*. fract (Dot Vector2 (xy4 FragmentCoordinates) (v2 0.06711056 0.00583715)))
  let scatter = If Float1 (greater (Component Y4 (u 17)) 0)
        (foldCount Float1 scatterLimit (UnsignedLiteral 12) 0 $ \i total -> build $ do
          t <- share ((UnsignedFloat i .+. jitter) .*. lengthStep)
          p <- share (add3 eye (scale3 ray t))
          let densityAt = 0.00040 .*. exponential (negateF (maxF 0 (Component Y3 p .-. 7) .*. 0.040))
          pure $ total .+. lightAt p .*. densityAt .*. lengthStep .*. exponential (negateF (t .*. 0.0035))) 0
  let phase = 0.25 .+. 0.35 .*. pow (maxF 0 (Dot Vector3 ray sunDirection)) 6
  pure $ rgba (scale3 sunRadiance (scatter .*. phase .*. (1 .-. night .*. 0.65))) ao

ambientOcclusion :: LoopLimit -> Scalar local Fragment -> Vector2E local Fragment -> Scalar local Fragment
ambientOcclusion limit count uv = build $ do
  let dimensions = xy4 (u 18)
  let aspect = Component W4 (u 18)
  let snapped at = div2 (add2 (floor2 (mul2 at dimensions)) (v2 0.5 0.5)) dimensions
  let center = snapped uv
  let pixel = div2 (v2 1 1) dimensions
  let xStep = MakeVec2 (Component X2 pixel) 0
  let yStep = MakeVec2 0 (Component Y2 pixel)
  eyePoint <- share (viewPosition center)
  xr <- share (sub3 (viewPosition (add2 center xStep)) eyePoint)
  xl <- share (sub3 eyePoint (viewPosition (sub2 center xStep)))
  -- The second texture axis is reversed relative to the original GL view.
  yr <- share (sub3 eyePoint (viewPosition (sub2 center yStep)))
  yl <- share (sub3 (viewPosition (add2 center yStep)) eyePoint)
  let closest a b = If Float3 (less (Length Vector3 a) (Length Vector3 b)) a b
  rough <- share (Cross (closest xr xl) (closest yr yl))
  let normal0 = scale3 rough (inverseSqrt (maxF (Dot Vector3 rough rough) 1e-12))
  normal <- share $ If Float3 (less (Dot Vector3 normal0 (scale3 eyePoint (-1))) 0)
    (scale3 normal0 (-1)) normal0
  let radius = clamp (0.72 ./. maxF 1 (negateF (Component Z3 eyePoint))) 0.0005 0.09
  let occlusion = foldCount Float1 limit (CountFromFloat count) 0 $ \i total -> build $ do
        let index = UnsignedFloat i
        let angle = index .*. 2.399963
        let radial = root ((index .+. 0.5) ./. count)
        let offset = scale2 (MakeVec2 (cosine angle ./. aspect) (negateF (sine angle))) (radius .*. radial)
        let at = snapped (clamp2 (add2 center offset) (v2 0.001 0.001) (v2 0.999 0.999))
        delta <- share (sub3 (viewPosition at) eyePoint)
        distance <- share (Length Vector3 delta)
        pure $ total .+. maxF 0 (Dot Vector3 normal delta .-. 0.035) ./. maxF 0.04 distance
          .*. (1 .-. smooth 0.35 1.75 distance)
  pure $ clamp (1 .-. occlusion .*. (3.04 ./. count)) 0.48 1

viewPosition :: Vector2E local Fragment -> Vector3E local Fragment
viewPosition uv = build $ do
  let clip = u 19
  let near = Component X4 clip
  let far = Component Y4 clip
  let lens = Component Z4 (u 18)
  let aspect = Component W4 (u 18)
  let d = depthAt Texture0 uv
  let z = near .*. far ./. (far .-. d .*. (far .-. near))
  let x = (Component X2 uv .*. 2 .-. 1) .*. aspect .*. lens
  let y = (1 .-. Component Y2 uv .*. 2) .*. lens
  pure $ scale3 (MakeVec3 x y (-1)) z

lightAt :: Vector3E local Fragment -> Scalar local Fragment
lightAt position = build $ do
  near <- share (lightProjection 9 position)
  far <- share (lightProjection 13 position)
  let test v = both (between 0.01 0.99 (Component X3 v)) (both (between 0.01 0.99 (Component Y3 v))
        (less (Component Z3 v) 1))
  pure $ If Float1 (test near) (step (Component Z3 near .-. 0.00025) (depthAt Texture1 (xy3 near))) $
    If Float1 (test far) (step (Component Z3 far .-. 0.0003) (depthAt Texture2 (xy3 far))) 1

bloomFragment :: FragmentShader
bloomFragment = FragmentShader $ build $ do
  let uv = InterpolatedUV
  let direction = xy4 (u 0)
  let sample at = letExpr (rgb (SampleTexture at)) $ \color ->
        If Float3 (greater (Component Z4 (u 0)) 0) (build $ do
          brightness <- share (maxF (Component X3 color) (maxF (Component Y3 color) (Component Z3 color)))
          let threshold = If Float1 (greater (Component W4 (u 0)) 0) 1 0.7
          knee <- share (clamp ((brightness .-. threshold .+. 0.3) ./. 0.6) 0 1)
          pure $ scale3 color (maxF (brightness .-. threshold) (knee .*. knee .*. 0.3) ./. maxF brightness 0.0001))
          color
  let pair distance weight = scale3
        (add3 (sample (add2 uv (scale2 direction distance))) (sample (sub2 uv (scale2 direction distance)))) weight
  pure $ rgba (foldl add3 (scale3 (sample uv) 0.227027)
    [pair 1.384615 0.316216, pair 3.230769 0.070270]) 1

postFragment :: FragmentShader
postFragment = FragmentShader $ build $ do
  let uv = InterpolatedUV
  let texel = xy4 (u 0)
  let exposure = Component Z4 (u 0)
  let grade = Component W4 (u 0)
  let vignette = Component X4 (u 1)
  aa <- share (antialias uv texel)
  effects <- share $ If Float3 (greater (Component Y4 (u 1)) 0)
    (letExpr (upsampleEffects uv (xy4 (u 2))) $ \effect ->
      add3 (scale3 aa (Component W4 effect)) (rgb effect)) aa
  let bloom = If Float3 (greater (Component Z4 (u 1)) 0)
        (scale3 (rgb (SampleAt Texture2 uv)) (0.13 .*. Component W4 (u 1))) (v3 0 0 0)
  exposureColor <- share (scale3 (add3 effects bloom) (exponential2 exposure))
  let curve color = letExpr color $ \x -> clamp
        ((x .*. (2.51 .*. x .+. 0.03)) ./. (x .*. (2.43 .*. x .+. 0.59) .+. 0.14)) 0 1
  let srgb x = letExpr (curve x) $ \linear ->
        mix (linear .*. 12.92) (1.055 .*. pow linear (1 ./. 2.4) .-. 0.055) (step 0.0031308 linear)
  gamma <- share (MakeVec3 (srgb (Component X3 exposureColor)) (srgb (Component Y3 exposureColor))
    (srgb (Component Z3 exposureColor)))
  let film = If Float3 (greater grade 2.5)
        (scale3 (v3 0.94 0.98 1.03) (Dot Vector3 gamma (v3 0.2126 0.7152 0.0722))) $
        If Float3 (greater grade 1.5) (add3 (mul3 gamma (v3 0.77 0.95 1.18)) (v3 0.015 0.008 0.025)) $
        If Float3 (greater grade 0.5) (add3 (mul3 gamma (v3 1.14 1.02 0.83)) (v3 0.016 0.004 0)) gamma
  let p = sub2 (scale2 uv 2) (v2 1 1)
  pure $ rgba (scale3 film (1 .-. vignette .*. pow (Dot Vector2 p p .*. 0.5) 1.3)) 1

antialias :: Vector2E local Fragment -> Vector2E local Fragment -> Vector3E local Fragment
antialias uv pixel = build $ do
  let sample at = rgb (SampleTexture at)
  let luma = v3 0.299 0.587 0.114
  let corner x y = Dot Vector3 (sample (add2 uv (mul2 (v2 x y) pixel))) luma
  a <- share (corner (-1) (-1))
  b <- share (corner 1 (-1))
  d <- share (corner (-1) 1)
  e <- share (corner 1 1)
  center <- share (sample uv)
  m <- share (Dot Vector3 center luma)
  lo <- share (minF m (minF (minF a b) (minF d e)))
  hi <- share (maxF m (maxF (maxF a b) (maxF d e)))
  pure $ If Float3 (less (hi .-. lo) (maxF 0.035 (hi .*. 0.125))) center $ build $ do
    let dx = negateF ((a .+. b) .-. (d .+. e))
    let dy = (a .+. d) .-. (b .+. e)
    let reduce = maxF ((a .+. b .+. d .+. e) .*. 0.03125) 0.0078125
    let scale = 1 ./. (minF (absolute dx) (absolute dy) .+. reduce)
    direction <- share $ mul2 (clamp2 (scale2 (MakeVec2 dx dy) scale) (v2 (-6) (-6)) (v2 6 6)) pixel
    let at amount = sample (add2 uv (scale2 direction amount))
    narrow <- share $ scale3 (add3 (at (-1 ./. 6)) (at (1 ./. 6))) 0.5
    wide <- share $ add3 (scale3 narrow 0.5) (scale3 (add3 (at (-0.5)) (at 0.5)) 0.25)
    let w = Dot Vector3 wide luma
    pure $ If Float3 (BoolBinary EitherTrue (less w lo) (greater w hi)) narrow wide

upsampleEffects :: Vector2E local Fragment -> Vector2E local Fragment -> Vector4E local Fragment
upsampleEffects uv pixel = build $ do
  let size = div2 (v2 1 1) pixel
  let base = mul2 (add2 (floor2 (sub2 (mul2 uv size) (v2 0.5 0.5))) (v2 0.5 0.5)) pixel
  let lo = scale2 pixel 0.5
  let hi = sub2 (v2 1 1) lo
  center <- share (depthAt Texture3 uv)
  let sample x y = do
        at <- share (clamp2 (add2 base (mul2 (v2 x y) pixel)) lo hi)
        weight <- share (exponential (negateF (absolute (depthAt Texture3 at .-. center) .*. 24000)) .+. 0.0001)
        pure (ScaleVector Vector4 (SampleAt Texture1 at) weight, weight)
  samples <- traverse (uncurry sample) [(0, 0), (0, 1), (1, 0), (1, 1)]
  pure $ div4 (foldl (FloatBinary Float4 AddF) (Constant4 (Vec4 0 0 0 0)) (map fst samples))
    (splat4 (foldl (.+.) 0 (map snd samples)))

infixl 6 .+., .-.
infixl 7 .*., ./.

(.+.), (.-.), (.*.), (./.), minF, maxF, pow, step, atan2F :: Scalar local s -> Scalar local s -> Scalar local s
(.+.) = FloatBinary Float1 AddF
(.-.) = FloatBinary Float1 SubtractF
(.*.) = FloatBinary Float1 MultiplyF
(./.) = FloatBinary Float1 DivideF
minF = FloatBinary Float1 Minimum
maxF = FloatBinary Float1 Maximum
pow = FloatBinary Float1 Power
step = FloatBinary Float1 Step
atan2F = FloatBinary Float1 Atan2

negateF, absolute, sine, cosine, arcSine, exponential, exponential2, root, inverseSqrt, floorF, fract :: Scalar local s -> Scalar local s
negateF = FloatUnary Float1 NegateF
absolute = FloatUnary Float1 Absolute
sine = FloatUnary Float1 Sin
cosine = FloatUnary Float1 Cos
arcSine = FloatUnary Float1 Asin
exponential = FloatUnary Float1 Exp
exponential2 = FloatUnary Float1 Exp2
root = FloatUnary Float1 Sqrt
inverseSqrt = FloatUnary Float1 InverseSqrt
floorF = FloatUnary Float1 FloorF
fract = FloatUnary Float1 Fract

mix, smooth, clamp :: Scalar local s -> Scalar local s -> Scalar local s -> Scalar local s
mix = FloatTernary Float1 Mix
smooth = FloatTernary Float1 Smoothstep
clamp = FloatTernary Float1 Clamp

less, greater :: Scalar local s -> Scalar local s -> Expr local s Bool
less = Compare Less
greater = Compare Greater

both :: Expr local s Bool -> Expr local s Bool -> Expr local s Bool
both = BoolBinary Both

between :: Scalar local s -> Scalar local s -> Scalar local s -> Expr local s Bool
between lo hi x = both (greater x lo) (less x hi)

within :: Scalar local s -> Scalar local s -> Vector3E local s -> Expr local s Bool
within lo hi v = both (between lo hi (Component X3 v))
  (both (between lo hi (Component Y3 v)) (between lo hi (Component Z3 v)))

v2 :: Float -> Float -> Vector2E local s
v2 x y = MakeVec2 (FloatLiteral x) (FloatLiteral y)

v3 :: Float -> Float -> Float -> Vector3E local s
v3 x y z = MakeVec3 (FloatLiteral x) (FloatLiteral y) (FloatLiteral z)

add2, sub2, mul2, div2 :: Vector2E local s -> Vector2E local s -> Vector2E local s
add2 = FloatBinary Float2 AddF
sub2 = FloatBinary Float2 SubtractF
mul2 = FloatBinary Float2 MultiplyF
div2 = FloatBinary Float2 DivideF

floor2, fract2 :: Vector2E local s -> Vector2E local s
floor2 = FloatUnary Float2 FloorF
fract2 = FloatUnary Float2 Fract

clamp2 :: Vector2E local s -> Vector2E local s -> Vector2E local s -> Vector2E local s
clamp2 = FloatTernary Float2 Clamp

scale2 :: Vector2E local s -> Scalar local s -> Vector2E local s
scale2 = ScaleVector Vector2

add3, sub3, mul3, max3, pow3 :: Vector3E local s -> Vector3E local s -> Vector3E local s
add3 = FloatBinary Float3 AddF
sub3 = FloatBinary Float3 SubtractF
mul3 = FloatBinary Float3 MultiplyF
max3 = FloatBinary Float3 Maximum
pow3 = FloatBinary Float3 Power

mix3 :: Vector3E local s -> Vector3E local s -> Scalar local s -> Vector3E local s
mix3 lhs rhs amount = FloatTernary Float3 Mix lhs rhs (splat3 amount)

scale3 :: Vector3E local s -> Scalar local s -> Vector3E local s
scale3 = ScaleVector Vector3

div4 :: Vector4E local s -> Vector4E local s -> Vector4E local s
div4 = FloatBinary Float4 DivideF

splat3 :: Scalar local s -> Vector3E local s
splat3 x = MakeVec3 x x x

splat4 :: Scalar local s -> Vector4E local s
splat4 x = MakeVec4 x x x x

xy3 :: Vector3E local s -> Vector2E local s
xy3 v = letExpr v $ \bound -> MakeVec2 (Component X3 bound) (Component Y3 bound)

xy4 :: Vector4E local s -> Vector2E local s
xy4 v = letExpr v $ \bound -> MakeVec2 (Component X4 bound) (Component Y4 bound)

rgb :: Vector4E local s -> Vector3E local s
rgb v = letExpr v $ \bound -> MakeVec3 (Component X4 bound) (Component Y4 bound) (Component Z4 bound)

rgba :: Vector3E local s -> Scalar local s -> Vector4E local s
rgba v alpha = letExpr v $ \bound -> MakeVec4 (Component X3 bound) (Component Y3 bound) (Component Z3 bound) alpha

append2 :: Vector2E local s -> Scalar local s -> Vector3E local s
append2 v z = MakeVec3 (Component X2 v) (Component Y2 v) z

append2Depth :: Vector2E local s -> Scalar local s -> Vector4E local s
append2Depth v d = MakeVec4 (Component X2 v) (Component Y2 v) d 1

depthAt :: TextureSlot -> Vector2E local Fragment -> Scalar local Fragment
depthAt slot = Component X4 . SampleAt slot

u :: Word32 -> Vector4E local s
u index = maybe (Constant4 (Vec4 0 0 0 0)) Uniform (uniformSlot index)

matrix :: Word32 -> Expr local s Mat4
matrix start = MakeMat4 (u start) (u (start+1)) (u (start+2)) (u (start+3))

sunDirection, sunRadiance, skyRadiance, eye :: Vector3E local s
sunDirection = rgb (u 0)
sunRadiance = rgb (u 1)
skyRadiance = rgb (u 2)
eye = rgb (u 3)

night, time :: Scalar local s
night = Component W4 (u 0)
time = Component W4 (u 1)
