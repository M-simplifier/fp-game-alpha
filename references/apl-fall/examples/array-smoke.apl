⍝ This is an array-driven graphics/input example, with no Tetris rules.
∇ RunSmoke;input;rects;cells;x;y;phase;unused;held;pressed
 input←RLFrame 0 9⍴0
loop: →(input[0])/done
 cells←⍳192
 x←36+38×16|cells
 y←130+26×⌊cells÷16
 phase←input[2]
 rects←(192 1⍴0),[1](192 1⍴x),[1](192 1⍴y),[1](192 2⍴34 22),[1](192 1⍴⌊120+100×1○phase+cells÷16),[1](192 1⍴⌊150+70×2○phase+cells÷32),[1](192 2⍴230 255)
 unused←36 28 30 235 242 255 255 RLText 'GNU APL + raylib / live array smoke'
 unused←36 74 18 148 179 212 255 RLText '192 colored rectangles are formed in APL; arrows and space test input.'
 unused←36 490 20 218 228 248 255 RLText 'FRAME ',(⍕input[5]),'    TIME ',⍕input[2]
 unused←36 525 20 218 228 248 255 RLText 'HELD ',⍕input[RLHeld]
 unused←36 560 20 218 228 248 255 RLText 'PRESSED ',⍕input[RLPressed]
 unused←36 610 18 148 179 212 255 RLText 'Native GNU APL owns this loop, animation and draw-list construction.'
 input←RLFrame rects
 →loop
done: unused←RLLog 'smoke completed; last input ',⍕input
 unused←RLClose 0
∇
RunSmoke
)OFF
