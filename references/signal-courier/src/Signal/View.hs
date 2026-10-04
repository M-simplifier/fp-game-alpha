module Signal.View (render) where

import Signal.Game

render :: Session -> String
render session =
  "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 600 380\" role=\"img\" aria-label=\"Signal Courier night city\">"
    ++ "<rect width=\"600\" height=\"380\" fill=\"#10192c\"/><circle cx=\"490\" cy=\"75\" r=\"25\" fill=\"#f0ddb0\"/>"
    ++ concat [rect x (110 + (x `mod` 57)) 58 200 "#192b44" | x <- [0, 65 .. 590]]
    ++ "<g transform=\"translate("
    ++ show (-camera)
    ++ " 0)\">"
    ++ concat [rect (leftEdge p) (surface p) (rightEdge p - leftEdge p) 12 "#739099" | r <- rooms defaultLevel, p <- platforms r]
    ++ concat [rect (beaconX r - 5) 254 10 46 (if i < parcelsDelivered v then "#8ff0c2" else "#e9b759") ++ rect (beaconX r - 14) 245 28 18 "#fff0af" | (i, r) <- zip [0 ..] (rooms defaultLevel)]
    ++ concat ["<circle cx=\"" ++ show (i * 600 + 430) ++ "\" cy=\"177\" r=\"6\" fill=\"#c7b1ff\"/>" | i <- [0 .. 2], i `notElem` collectedStamps v]
    ++ rect (courierX v - 7) (courierY v - 23) 14 23 "#77d9d0"
    ++ rect (courierX v + 7) (courierY v - 17) 9 11 "#ffe39c"
    ++ "</g>"
    ++ text 20 28 "Signal Courier"
    ++ text 20 49 (roomTitle ++ " | beacons " ++ show (parcelsDelivered v) ++ "/3 | stamps " ++ show (length (collectedStamps v)) ++ "/3")
    ++ text 20 70 ("Shift " ++ show ((10800 - elapsedTicks v) `div` 60) ++ "s | falls " ++ show (fallCount v))
    ++ text 20 360 message
    ++ "</svg>"
  where
    v = view session
    camera = min 1200 ((courierX v `div` 600) * 600)
    roomTitle = case drop (camera `div` 600) (rooms defaultLevel) of r : _ -> roomName r; [] -> "Night city"
    message = case status v of
      Complete -> "All lanterns delivered! Restart for the rooftop stamps."
      Exhausted -> "Shift ended. Retry from the latest beacon."
      Delivering -> "Carry the lantern east. Jump canals; rooftops hold optional stamps."

rect :: Int -> Int -> Int -> Int -> String -> String
rect x y w h color = "<rect x=\"" ++ show x ++ "\" y=\"" ++ show y ++ "\" width=\"" ++ show w ++ "\" height=\"" ++ show h ++ "\" fill=\"" ++ color ++ "\"/>"

text :: Int -> Int -> String -> String
text x y value = "<text x=\"" ++ show x ++ "\" y=\"" ++ show y ++ "\" font-family=\"sans-serif\" font-size=\"13\" fill=\"#f0e9d8\">" ++ value ++ "</text>"
