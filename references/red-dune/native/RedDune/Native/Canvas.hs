module RedDune.Native.Canvas
  ( Drawing,
    drawFrame,
    Color (..),
    Vector2 (..),
    Rectangle (..),
    renderColor,
    submitOverlay,
    clearBackground,
    beginScissorMode,
    endScissorMode,
    drawTriangle,
    drawRectangle,
    drawRectangleRounded,
    drawRectangleGradientV,
    drawLine,
    drawLineEx,
    drawLineBezier,
    drawCircleV,
    drawEllipse,
    drawEllipseLines,
  )
where

import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Reader (ReaderT, ask, runReaderT)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Maybe (listToMaybe)
import Data.Word (Word8)
import GameIO.Graphics qualified as GPU

data Color = Color !Word8 !Word8 !Word8 !Word8 deriving (Eq, Show)

data Vector2 = Vector2 !Float !Float deriving (Eq, Show)

data Rectangle = Rectangle !Float !Float !Float !Float deriving (Eq, Show)

data Canvas = Canvas !GPU.Color ![GPU.ClipRect] ![[GPU.Vertex]] ![GPU.OverlayBatch]

type Drawing = ReaderT (IORef Canvas) IO

drawFrame :: Drawing a -> IO (a, GPU.Frame)
drawFrame drawing = do
  state <- newIORef (Canvas (GPU.Color 0 0 0 1) [] [] [])
  result <- runReaderT drawing state
  Canvas background clips pending completed <- readIORef state
  pure (result, GPU.Frame background [] (reverse (finish clips pending completed)))

update :: (Canvas -> Canvas) -> Drawing ()
update change = ask >>= liftIO . flip modifyIORef' change

renderColor :: Color -> GPU.Color
renderColor (Color r g b a) = GPU.Color (unit r) (unit g) (unit b) (unit a)
  where
    unit value = fromIntegral value / 255

clearBackground :: Color -> Drawing ()
clearBackground color = update (\(Canvas _ clip pending batches) -> Canvas (renderColor color) clip pending batches)

finish :: [GPU.ClipRect] -> [[GPU.Vertex]] -> [GPU.OverlayBatch] -> [GPU.OverlayBatch]
finish _ [] previous = previous
finish clips pending previous = withClip clips Nothing (concat (reverse pending)) : previous

withClip :: [GPU.ClipRect] -> Maybe GPU.Texture -> [GPU.Vertex] -> GPU.OverlayBatch
withClip (clip : _) = GPU.ClippedOverlay clip
withClip [] = GPU.OverlayBatch

submitOverlay :: GPU.OverlayBatch -> Drawing ()
submitOverlay incoming = update $ \(Canvas background clips pending completed) ->
  let placed = case incoming of
        GPU.OverlayBatch texture vertices -> withClip clips texture vertices
        GPU.ClippedOverlay clip texture vertices ->
          GPU.ClippedOverlay (intersectClip clips clip) texture vertices
        GPU.OverlayBatchWith clip material inputs vertices ->
          GPU.OverlayBatchWith (maybe (listToMaybe clips) (Just . intersectClip clips) clip) material inputs vertices
   in Canvas background clips [] (placed : finish clips pending completed)

beginScissorMode :: Int -> Int -> Int -> Int -> Drawing ()
beginScissorMode x y width height = update $ \(Canvas background clips pending completed) ->
  let next = intersectClip clips (GPU.ClipRect x y width height)
   in Canvas background (next : clips) [] (finish clips pending completed)

endScissorMode :: Drawing ()
endScissorMode = update $ \(Canvas background clips pending completed) ->
  Canvas background (drop 1 clips) [] (finish clips pending completed)

intersectClip :: [GPU.ClipRect] -> GPU.ClipRect -> GPU.ClipRect
intersectClip [] clip = clip
intersectClip (GPU.ClipRect a b w h : _) (GPU.ClipRect x y width height) =
  let left = max a x
      top = max b y
   in GPU.ClipRect left top (max 0 (min (a + w) (x + width) - left)) (max 0 (min (b + h) (y + height) - top))

vertex :: Color -> Vector2 -> GPU.Vertex
vertex color (Vector2 x y) = GPU.Vertex x y 0 0 0 (renderColor color)

shapes :: [GPU.Vertex] -> Drawing ()
shapes vertices = update $ \(Canvas background clip pending completed) ->
  Canvas background clip (vertices : pending) completed

drawTriangle :: Vector2 -> Vector2 -> Vector2 -> Color -> Drawing ()
drawTriangle a b c color = shapes (map (vertex color) [a, b, c])

drawRectangle :: Int -> Int -> Int -> Int -> Color -> Drawing ()
drawRectangle x y w h color = drawRectangleGradientV x y w h color color

drawRectangleGradientV :: Int -> Int -> Int -> Int -> Color -> Color -> Drawing ()
drawRectangleGradientV x y width height top bottom =
  let l = fromIntegral x
      t = fromIntegral y
      r = l + fromIntegral width
      b = t + fromIntegral height
      tl = vertex top (Vector2 l t)
      tr = vertex top (Vector2 r t)
      br = vertex bottom (Vector2 r b)
      bl = vertex bottom (Vector2 l b)
   in shapes [tl, tr, br, tl, br, bl]

drawRectangleRounded :: Rectangle -> Float -> Int -> Color -> Drawing ()
drawRectangleRounded (Rectangle x y width height) amount segments color =
  let radius = max 0 (min 1 amount) * min width height * 0.5
      corners =
        [ (x + width - radius, y + radius, -pi / 2),
          (x + width - radius, y + height - radius, 0),
          (x + radius, y + height - radius, pi / 2),
          (x + radius, y + radius, pi)
        ]
      rim = concatMap (\(cx, cy, a) -> arc (max 1 segments) cx cy radius radius a (a + pi / 2)) corners
   in fillPolygon (Vector2 (x + width * 0.5) (y + height * 0.5)) rim color

drawLine :: Int -> Int -> Int -> Int -> Color -> Drawing ()
drawLine x y a b = drawLineEx (Vector2 (fromIntegral x) (fromIntegral y)) (Vector2 (fromIntegral a) (fromIntegral b)) 1

drawLineEx :: Vector2 -> Vector2 -> Float -> Color -> Drawing ()
drawLineEx first lastPoint thickness color = shapes (lineVertices first lastPoint thickness color)

lineVertices :: Vector2 -> Vector2 -> Float -> Color -> [GPU.Vertex]
lineVertices (Vector2 ax ay) (Vector2 bx by) thickness color
  | len <= 0 || thickness <= 0 = []
  | otherwise =
      let u = Vector2 (ax + nx) (ay + ny)
          v = Vector2 (bx + nx) (by + ny)
          w = Vector2 (bx - nx) (by - ny)
          z = Vector2 (ax - nx) (ay - ny)
       in map (vertex color) [u, v, w, u, w, z]
  where
    dx = bx - ax
    dy = by - ay
    len = sqrt (dx * dx + dy * dy)
    nx = negate dy * thickness / (2 * len)
    ny = dx * thickness / (2 * len)

drawLineBezier :: Vector2 -> Vector2 -> Float -> Color -> Drawing ()
drawLineBezier (Vector2 ax ay) (Vector2 bx by) thickness color =
  let curve step =
        let t = fromIntegral step / 24
            smooth = if t < 0.5 then 4 * t * t * t else let d = 1 - t in 1 - 4 * d * d * d
         in Vector2 (ax + (bx - ax) * t) (ay + (by - ay) * smooth)
      points = map curve [0 .. 24 :: Int]
   in shapes (concatMap (\(a, b) -> lineVertices a b thickness color) (zip points (drop 1 points)))

drawCircleV :: Vector2 -> Float -> Color -> Drawing ()
drawCircleV centre@(Vector2 x y) radius = fillPolygon centre (ellipse x y radius radius)

drawEllipse :: Int -> Int -> Float -> Float -> Color -> Drawing ()
drawEllipse x y rx ry = fillPolygon (Vector2 cx cy) (ellipse cx cy rx ry)
  where
    (cx, cy) = (fromIntegral x, fromIntegral y)

drawEllipseLines :: Int -> Int -> Float -> Float -> Color -> Drawing ()
drawEllipseLines x y rx ry color =
  let rim = ellipse (fromIntegral x) (fromIntegral y) rx ry
   in shapes (concatMap (\(a, b) -> lineVertices a b 1 color) (pairs rim))

ellipse :: Float -> Float -> Float -> Float -> [Vector2]
ellipse x y rx ry = take 36 (arc 36 x y rx ry 0 (2 * pi))

arc :: Int -> Float -> Float -> Float -> Float -> Float -> Float -> [Vector2]
arc count x y rx ry start end =
  [ let angle = start + (end - start) * fromIntegral i / fromIntegral count
     in Vector2 (x + rx * cos angle) (y + ry * sin angle)
  | i <- [0 .. count]
  ]

fillPolygon :: Vector2 -> [Vector2] -> Color -> Drawing ()
fillPolygon centre rim color = shapes (concatMap (\(a, b) -> map (vertex color) [centre, a, b]) (pairs rim))

pairs :: [a] -> [(a, a)]
pairs values = zip values (drop 1 values ++ take 1 values)
