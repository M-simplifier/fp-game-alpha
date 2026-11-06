⍝ The graphical view is also APL: the host only draws these generic rows.
BoardX←260 ⋄ BoardY←110 ⋄ CellSize←28

∇ z←AddRect row
 Draw←Draw⍪1 9⍴row
 z←0
∇

∇ z←position Label text
 z←position RLText text
∇

∇ rows←style TileRows cellTypes;count;cells;types;x;y;rgb;inset;alpha;op
 count←(⍴cellTypes)[0]
 →(count=0)/EMPTY
 cells←cellTypes[;0] ⋄ types←cellTypes[;1]
 rgb←Palette[types;]
 inset←2 ⋄ alpha←255 ⋄ op←0
 →(style=0)/MAKE
 inset←3 ⋄ alpha←130 ⋄ op←1
 →(style=1)/MAKE
 rgb←count 3⍴246 201 111 ⋄ alpha←235
MAKE: x←BoardX+inset+CellSize×Width|cells
 y←BoardY+inset+CellSize×(⌊cells÷Width)-Hidden
 rows←⍉9 count⍴(count⍴op),x,y,(count⍴CellSize-2×inset),(count⍴CellSize-2×inset),rgb[;0],rgb[;1],rgb[;2],(count⍴alpha)
 →DONE
EMPTY: rows←0 9⍴0
DONE:
∇

∇ rows←BaseDrawing ignored;unused;cell;col;row;Draw
 Draw←0 9⍴0
 unused←AddRect 0 24 96 208 624 15 21 33 255
 unused←AddRect 0 248 98 304 584 26 35 51 255
 unused←AddRect 0 BoardX BoardY 280 560 13 20 31 255
 cell←0
GRID: col←10|cell ⋄ row←⌊cell÷10
 unused←AddRect 1 (BoardX+CellSize×col) (BoardY+CellSize×row) CellSize CellSize 25 34 48 255
 cell←cell+1 ⋄ →(cell<200)/GRID
 unused←AddRect 1 248 98 304 584 58 75 99 255
 unused←AddRect 0 24 742 1032 1 38 49 68 255
 rows←Draw
∇

∇ z←position Preview type;local;i;rgb;size;unused
 z←0 ⋄ →(type<0)/DONE
 local←Offsets[type;0;;] ⋄ rgb←Palette[type+1;] ⋄ size←position[2]
 i←0
TILE: unused←AddRect 0 (position[0]+size×local[i;1]) (position[1]+size×local[i;0]) (size-2) (size-2) rgb[0] rgb[1] rgb[2] 255
 i←i+1 ⋄ →(i<4)/TILE
DONE:
∇

∇ rows←AtlasDrawing ignored;unused;o;ids;feasible;reach;land;rgb;x;y;bx;by;count;block;Draw
 Draw←0 9⍴0 ⋄ o←0
ORIENT: bx←592+224×2|o ⋄ by←110+300×⌊o÷2
 unused←AddRect 0 bx by 208 280 15 21 33 255
 ids←(o×Plane)+⍳Plane
 feasible←Field[ids] ⋄ reach←Reachable[ids] ⋄ land←Supported[ids]
 rgb←Plane 3⍴30 40 55
 rgb[feasible/⍳Plane;]←((+/feasible),3)⍴77 93 116
 rgb[reach/⍳Plane;]←((+/reach),3)⍴75 195 169
 rgb[land/⍳Plane;]←((+/land),3)⍴246 201 111
 x←bx+45+8×3+Poses[ids;2]
 y←by+46+8×3+Poses[ids;1]
 block←⍉9 Plane⍴(Plane⍴0),x,y,(Plane⍴5),(Plane⍴5),rgb[;0],rgb[;1],rgb[;2],(Plane⍴255)
 Draw←Draw⍪block
 unused←AddRect 1 (bx+43) (by+44) 108 204 43 56 77 255
 o←o+1 ⋄ →(o<4)/ORIENT
 rows←Draw
∇

∇ z←DrawGame ignored;unused;flat;cells;types;count;ghost;visible;pairs;target;i;o;bx;by;pose;message
 Draw←Background
 unused←44 32 32 230 237 246 255 Label 'ARRAY / FALL'
 unused←45 70 15 128 149 176 255 Label 'Find a way down.'
 unused←44 128 14 129 151 180 255 Label 'HOLD'
 unused←(68 178 22) Preview Hold
 →CanHold/HOLDREADY
 unused←44 257 12 105 120 144 255 Label 'Used this turn' ⋄ →CONTROLS
HOLDREADY: unused←44 257 12 105 120 144 255 Label 'C  Store / swap'
CONTROLS: unused←44 315 14 180 195 216 255 Label 'MOVE'
 unused←44 343 14 133 153 180 255 Label 'Left / Right'
 unused←44 381 14 180 195 216 255 Label 'TURN'
 unused←44 409 14 133 153 180 255 Label 'Up / X     Z'
 unused←44 447 14 180 195 216 255 Label 'DROP'
 unused←44 475 14 133 153 180 255 Label 'Down   Soft'
 unused←44 502 14 133 153 180 255 Label 'Space  Hard'
 unused←44 559 14 133 153 180 255 Label 'P  Pause'
 unused←44 586 14 133 153 180 255 Label 'R  Restart'
 unused←44 643 14 133 153 180 255 Label 'S  Cavity study'
 flat←,Board ⋄ cells←⍳Height×Width
 visible←(cells≥Hidden×Width)∧flat≠0
 cells←visible/cells ⋄ types←visible/flat ⋄ count←(⍴cells)[0]
 pairs←⍉2 count⍴cells,types
 Draw←Draw⍪0 TileRows pairs
 →(Mode=2)/AFTERPIECE
 ghost←Pose+ColCount×Field DropDistance Pose
 cells←Foot[Type;ghost;] ⋄ visible←cells≥Hidden×Width ⋄ cells←visible/cells
 count←(⍴cells)[0] ⋄ pairs←⍉2 count⍴cells,(count⍴Type+1)
 Draw←Draw⍪1 TileRows pairs
 cells←Foot[Type;Pose;] ⋄ visible←cells≥Hidden×Width ⋄ cells←visible/cells
 count←(⍴cells)[0] ⋄ pairs←⍉2 count⍴cells,(count⍴Type+1)
 Draw←Draw⍪0 TileRows pairs
AFTERPIECE: →(Mode=3)/INSPECT
 unused←AddRect 0 584 96 254 624 15 21 33 255
 unused←608 126 14 129 151 180 255 Label 'SCORE'
 unused←608 151 35 233 239 247 255 Label ⍕Score
 unused←608 210 15 154 174 201 255 Label 'LEVEL ',⍕Level
 unused←725 210 15 154 174 201 255 Label 'LINES ',⍕Lines
 unused←608 267 14 129 151 180 255 Label 'NEXT'
 i←0
NEXT: unused←(608 (310+72×i) 18) Preview Queue[i]
 i←i+1 ⋄ →(i<5)/NEXT
 unused←876 133 13 84 105 134 255 Label 'Keep a little'
 unused←876 155 13 84 105 134 255 Label 'room to turn.'
 unused←260 701 14 132 155 185 255 Label 'SPACE  Drop to the outline'
 unused←44 762 15 145 167 197 255 Label 'TAB  Observe positions     S  Try the cavity study     R  Begin again'
 →(FlashTicks=0)/OVERLAYS
 message←'SINGLE'
 →(LastClear=1)/CLEARLABEL
 message←'DOUBLE' ⋄ →(LastClear=2)/CLEARLABEL
 message←'TRIPLE' ⋄ →(LastClear=3)/CLEARLABEL
 message←'FOUR LINES'
CLEARLABEL: unused←876 238 19 246 201 111 255 Label message
 →OVERLAYS
INSPECT: →(0≠⎕NC 'AtlasCache')/ATLASCACHED
 AtlasCache←AtlasDrawing 0
ATLASCACHED: Draw←Draw⍪AtlasCache
 o←0
TITLES: bx←592+224×2|o ⋄ by←110+300×⌊o÷2
 unused←(bx+18) (by+15) 15 183 200 222 255 Label 'TURN ',⍕o
 unused←(bx+18) (by+258) 11 113 137 168 255 Label 'col -3..9 / row -3..21'
 o←o+1 ⋄ →(o<4)/TITLES
 unused←592 52 24 217 232 243 255 Label 'POSSIBILITY / REACHABILITY'
 unused←592 83 13 143 164 193 255 Label 'Clock stopped. Same actions. First legal kick.'
 unused←260 701 14 132 155 185 255 Label 'A / D  Select     ENTER  Follow path'
 unused←44 762 14 145 167 197 255 Label 'TAB  Resume    Gray: fits    Green: reachable    Gold: supported landing'
 unused←592 715 13 155 178 204 255 Label ('Fits ',⍕+/Field),'   Reachable ',(⍕+/Reachable),'   Landings ',⍕+/Supported
 →(0=⍴LandingList)/OVERLAYS
 target←LandingList[Selection]
 cells←Foot[Type;target;] ⋄ visible←cells≥Hidden×Width ⋄ cells←visible/cells
 count←(⍴cells)[0] ⋄ pairs←⍉2 count⍴cells,(count⍴Type+1)
 Draw←Draw⍪2 TileRows pairs
 pose←Poses[target;] ⋄ o←pose[0]
 bx←592+224×2|o ⋄ by←110+300×⌊o÷2
 unused←AddRect 1 (bx+42+8×3+pose[2]) (by+43+8×3+pose[1]) 11 11 255 242 205 255
 unused←260 724 12 155 178 204 255 Label 'Selected path: ',(⍕⍴Witness target),' actions'
OVERLAYS: →(Mode=1)/PAUSED
 →(Mode≠2)/DONE
 unused←AddRect 0 260 308 280 154 10 14 23 238
 unused←310 338 29 238 220 206 255 Label 'GAME OVER'
 unused←296 389 17 157 177 204 255 Label 'R  Start a new game'
 →DONE
PAUSED: unused←AddRect 0 260 308 280 154 10 14 23 238
 unused←326 337 30 230 237 246 255 Label 'PAUSED'
 unused←312 388 17 157 177 204 255 Label 'P  Return to play'
DONE: z←0
∇

∇ z←Main ignored;input;unused;accumulator;pending;ticks;held;edges;wasMode;wasBoard;wasType
 unused←NewGame InitialSeed
 →(~DemoMode)/NORMAL
 unused←LoadDemo 0
NORMAL: Background←BaseDrawing 0
 accumulator←0 ⋄ pending←16⍴0
 input←RLFrame 0 9⍴0
FRAME: →input[0]/CLOSE
 held←input[RLHeld] ⋄ pending←pending∨input[RLPressed]
 accumulator←accumulator+0.1⌊0⌈input[1]
 ticks←0
TICK: →(accumulator<1÷60)/RENDER
 wasMode←Mode ⋄ wasBoard←Board ⋄ wasType←Type
 unused←held GameTick pending ⋄ pending←16⍴0
 →(Mode≠3)/INVALIDATE
 →((wasMode=3)∧(wasType=Type)∧wasBoard≡Board)/TICKDONE
INVALIDATE: unused←⎕EX 'AtlasCache'
TICKDONE: accumulator←0⌈accumulator-1÷60
 ticks←ticks+1 ⋄ →(ticks<6)/TICK
RENDER: unused←DrawGame 0
 input←RLFrame Draw
 →FRAME
CLOSE: unused←RLLog 'game score=',(⍕Score),' lines=',(⍕Lines),' pieces=',(⍕Pieces),' ticks=',(⍕ActiveTicks),' seed=',(⍕Seed),' mode=',(⍕Mode),' type=',(⍕Type),' pose=',(⍕Pose),' hold=',⍕Hold
 unused←RLClose 0
 z←0
∇

∇ z←Start ignored
 →(0≠⎕NC 'DemoMode')/HAVEMODE
 DemoMode←0
HAVEMODE: →(0≠⎕NC 'InitialSeed')/HAVESEED
 InitialSeed←+/⎕TS×1 13 97 101 1009 10007 100003
HAVESEED: z←Main 0
∇
unused←Start 0
)OFF
