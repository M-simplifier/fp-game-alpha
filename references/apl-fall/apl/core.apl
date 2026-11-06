⍝ ARRAY FALL / GNU APL 2.0. Coordinates are zero based, row first.
⎕IO←0
⎕PP←12
⎕PW←1000000

∇ z←InitGeometry ignored;t;o;n;m;flat;local;rr;cc;good;idx;sel;ids
 Height←22 ⋄ Width←10 ⋄ Hidden←2
 AnchorRows←¯3+⍳25 ⋄ AnchorCols←¯3+⍳13
 RowCount←25 ⋄ ColCount←13 ⋄ Plane←325 ⋄ PoseCount←1300
 ids←⍳PoseCount
 Poses←⍉3 PoseCount⍴(⌊ids÷Plane),(¯3+⌊(Plane|ids)÷ColCount),(¯3+ColCount|ids)
 Foot←7 PoseCount 4⍴220
 Offsets←7 4 4 2⍴0
 Sizes←4 3 3 2 3 3 3
 t←0
TYPE: n←Sizes[t]
 →(t=0)/I
 →(t=1)/J
 →(t=2)/L
 →(t=3)/O
 →(t=4)/S
 →(t=5)/T
 m←3 3⍴1 1 0 0 1 1 0 0 0 ⋄ →SHAPE
I: m←4 4⍴0 0 0 0 1 1 1 1 0 0 0 0 0 0 0 0 ⋄ →SHAPE
J: m←3 3⍴1 0 0 1 1 1 0 0 0 ⋄ →SHAPE
L: m←3 3⍴0 0 1 1 1 1 0 0 0 ⋄ →SHAPE
O: m←2 2⍴1 ⋄ →SHAPE
S: m←3 3⍴0 1 1 1 1 0 0 0 0 ⋄ →SHAPE
T: m←3 3⍴0 1 0 1 1 1 0 0 0
SHAPE: o←0
ORIENT: flat←(,m)/⍳n×n
 local←⍉2 4⍴(⌊flat÷n),(n|flat)
 Offsets[t;o;;]←local
 sel←(o×Plane)+⍳Plane
 rr←Poses[sel;1]∘.+local[;0]
 cc←Poses[sel;2]∘.+local[;1]
 good←(rr≥0)∧(rr<Height)∧(cc≥0)∧(cc<Width)
 idx←(Width×rr)+cc
 Foot[t;sel;]←(good×idx)+(220×~good)
 m←⌽⍉m
 o←o+1 ⋄ →(o<4)/ORIENT
 t←t+1 ⋄ →(t<7)/TYPE
 KickOffsets←7 2⍴0 0 0 ¯1 0 1 ¯1 0 0 ¯2 0 2 ¯2 0
 PieceNames←'IJLOSTZ'
 Palette←8 3⍴18 25 39 70 213 226 92 126 235 240 163 73 234 211 90 91 201 143 183 123 224 235 105 128
 z←0
∇

⍝ The complete collision field: gather four cells per pose, reduce that axis.
∇ field←type Feasible board;extended
 extended←(,board),1
 field←∧/0=extended[Foot[type;;]]
∇

∇ indices←PoseIndices coordinates;valid
 valid←(coordinates[;0]≥0)∧(coordinates[;0]<4)∧(coordinates[;1]≥¯3)∧(coordinates[;1]<22)∧(coordinates[;2]≥¯3)∧(coordinates[;2]<10)
 indices←(Plane×coordinates[;0])+(ColCount×3+coordinates[;1])+3+coordinates[;2]
 indices←(valid×indices)+(PoseCount×~valid)
∇

∇ index←PoseIndex coordinate
 index←(PoseIndices 1 3⍴coordinate)[0]
∇

⍝ Five total maps [left,right,down,CW,CCW], illegal actions map to self.
⍝ A rotation chooses its FIRST feasible kick; it does not branch over kicks.
∇ maps←BuildActions field;ids;extended;action;candidates;dest;legal;turn;k;found;chosen
 ids←⍳PoseCount ⋄ extended←field,0
 maps←5 PoseCount⍴ids
 action←0
MOVE: candidates←Poses
 →(action=0)/LEFT
 →(action=1)/RIGHT
 candidates[;1]←candidates[;1]+1 ⋄ →MAP
LEFT: candidates[;2]←candidates[;2]-1 ⋄ →MAP
RIGHT: candidates[;2]←candidates[;2]+1
MAP: dest←PoseIndices candidates
 legal←extended[dest]
 maps[action;legal/ids]←legal/dest
 action←action+1 ⋄ →(action<3)/MOVE
 turn←0
ROTATE: found←PoseCount⍴0 ⋄ k←0
KICK: candidates←Poses
 candidates[;0]←4|candidates[;0]+(1 ¯1)[turn]
 candidates[;1]←candidates[;1]+KickOffsets[k;0]
 candidates[;2]←candidates[;2]+KickOffsets[k;1]
 dest←PoseIndices candidates
 chosen←(~found)∧extended[dest]
 maps[3+turn;chosen/ids]←chosen/dest
 found←found∨chosen
 k←k+1 ⋄ →(k<7)/KICK
 turn←turn+1 ⋄ →(turn<2)/ROTATE
∇

⍝ Prefix conjunction stops at the FIRST obstruction, including a roof.
∇ distance←field DropDistance index;pose;slice
 pose←Poses[index;]
 slice←field[(pose[0]×Plane)+(ColCount×3+(pose[1]+⍳22-pose[1]))+3+pose[2]]
 distance←( +/∧\slice,0)-1
∇

∇ result←ClearRows board;full;count
 full←∧/board≠0
 count←+/full
 result←((count,Width)⍴0)⍪(~full)⌿board
∇

∇ z←Refresh ignored
 Field←Type Feasible Board
 Actions←BuildActions Field
 z←0
∇

⍝ Park-Miller RNG: explicit portable integer state, independent of ⎕RL.
∇ value←NextRandom ignored
 Seed←2147483647|16807×Seed
 value←Seed
∇

∇ bag←NewBag ignored;j;k;swap;random
 bag←⍳7 ⋄ j←6
LOOP: random←NextRandom 0
 k←(j+1)|random
 swap←bag[j] ⋄ bag[j]←bag[k] ⋄ bag[k]←swap
 j←j-1 ⋄ →(j>0)/LOOP
∇

∇ z←FillQueue ignored
MORE: →(7≤⍴Queue)/DONE
 Queue←Queue,NewBag 0 ⋄ →MORE
DONE: z←0
∇

∇ z←Spawn ignored;unused
 unused←FillQueue 0
 Type←Queue[0] ⋄ Queue←1↓Queue
 Pose←PoseIndex 0 1 3
 FallTicks←0 ⋄ LockTicks←0 ⋄ LockResets←0
 HorizontalTicks←0 ⋄ SoftTicks←0
 unused←Refresh 0
 →Field[Pose]/DONE
 Mode←2
DONE: z←0
∇

∇ z←NewGame seed;unused
 Seed←1+2147483646|⌊|seed
 Board←Height Width⍴0
 Queue←⍬ ⋄ Hold←¯1 ⋄ CanHold←1
 Score←0 ⋄ Lines←0 ⋄ Level←1 ⋄ Pieces←0
 Mode←0 ⋄ ActiveTicks←0 ⋄ LastClear←0
 FallTicks←0 ⋄ LockTicks←0 ⋄ LockResets←0
 HorizontalTicks←0 ⋄ SoftTicks←0 ⋄ HorizontalDirection←0
 ReplayPath←⍬ ⋄ ReplayAt←0 ⋄ ReplayTicks←0
 FlashTicks←0 ⋄ ClearedMask←Height⍴0
 unused←Spawn 0
 z←0
∇

∇ moved←MoveAction action;next;grounded
 grounded←Actions[2;Pose]=Pose
 next←Actions[action;Pose]
 moved←next≠Pose
 Pose←next
 →(~moved)/DONE
 →((action=2)∨~grounded)/DONE
 →(LockResets≥15)/DONE
 LockTicks←0 ⋄ LockResets←LockResets+1
DONE:
∇

∇ z←LockPiece ignored;cells;flat;count;unused
 cells←Foot[Type;Pose;]
 flat←,Board ⋄ flat[cells]←Type+1
 Board←Height Width⍴flat
 ClearedMask←∧/Board≠0 ⋄ count←+/ClearedMask
 LastClear←count ⋄ FlashTicks←30×count>0
 Board←ClearRows Board
 Score←Score+Level×(0 100 300 500 800)[count]
 Lines←Lines+count ⋄ Level←1+⌊Lines÷10
 Pieces←Pieces+1 ⋄ CanHold←1
 →(∨/,(Board[0 1;]≠0))/TOPPED
 unused←Spawn 0 ⋄ →DONE
TOPPED: Mode←2
 unused←Refresh 0
DONE: z←0
∇

∇ z←HardDrop ignored;distance;unused
 distance←Field DropDistance Pose
 Pose←Pose+ColCount×distance
 Score←Score+2×distance
 unused←LockPiece 0
 z←distance
∇

∇ z←HoldPiece ignored;previous;unused
 z←0 ⋄ →(~CanHold)/DONE
 previous←Type
 →(Hold≥0)/SWAP
 Hold←previous ⋄ unused←Spawn 0 ⋄ →FINISH
SWAP: Type←Hold ⋄ Hold←previous
 Pose←PoseIndex 0 1 3
 FallTicks←0 ⋄ LockTicks←0 ⋄ LockResets←0
 unused←Refresh 0
 →Field[Pose]/FINISH
 Mode←2
FINISH: CanHold←0
DONE:
∇

⍝ One tick = 1/60 s. Input order is explicit; inspect and pause stop gravity.
⍝ Held and edge vectors have the platform's sixteen named keys.
∇ z←held GameTick pressed;unused;moved;direction;interval;edge
 z←0
 →(~pressed[8])/NORESTART
 unused←NewGame InitialSeed ⋄ →DONE
NORESTART: →(~pressed[15])/NODEMO
 unused←LoadDemo 0 ⋄ →DONE
NODEMO: →(~pressed[11])/NOTAB
 →(Mode=3)/LEAVEINSPECT
 →(Mode=2)/NOTAB
 Mode←3 ⋄ unused←BeginInspect 0 ⋄ →DONE
LEAVEINSPECT: Mode←0 ⋄ ReplayPath←⍬ ⋄ →DONE
NOTAB: →(~(pressed[7]∨pressed[9]))/NOPAUSE
 →(Mode=0)/PAUSENOW
 →(Mode≠1)/NOPAUSE
 Mode←0 ⋄ →DONE
PAUSENOW: Mode←1 ⋄ →DONE
NOPAUSE: →(Mode=3)/INSPECT
 →(Mode≠0)/DONE
 ActiveTicks←ActiveTicks+1
 FlashTicks←0⌈FlashTicks-1
 →(~pressed[10])/NOHOLD
 unused←HoldPiece 0 ⋄ →(Mode≠0)/DONE
NOHOLD: →(~(pressed[3]∨pressed[5]))/NOCCW
 moved←MoveAction 3
NOCCW: →(~pressed[4])/HORIZONTAL
 moved←MoveAction 4
HORIZONTAL: direction←held[1]-held[0]
 edge←pressed[1]-pressed[0]
 →((direction=0)∧(~∨/held[0 1])∧(edge≠0))/TAP
 →(direction≠HorizontalDirection)/NEWHELD
 →(direction=0)/NOMOVE
 HorizontalTicks←HorizontalTicks+1
 →(HorizontalTicks<10)/NOMOVE
 →(0≠3|HorizontalTicks-10)/NOMOVE
 moved←MoveAction (direction=1) ⋄ →NOMOVE
NEWHELD: HorizontalDirection←direction ⋄ HorizontalTicks←0
 →(direction=0)/NOMOVE
 moved←MoveAction (direction=1)
 →NOMOVE
TAP: HorizontalDirection←0 ⋄ HorizontalTicks←0
 moved←MoveAction (edge=1)
NOMOVE: →(~pressed[6])/SOFT
 unused←HardDrop 0 ⋄ →DONE
SOFT: →(~(held[2]∨pressed[2]))/RELEASESOFT
 →(~pressed[2])/COUNTSOFT
 SoftTicks←0
COUNTSOFT:
 SoftTicks←SoftTicks+1
 →(1≠3|SoftTicks)/NOSOFT
 moved←MoveAction 2 ⋄ Score←Score+moved
 →NOSOFT
RELEASESOFT: SoftTicks←0
NOSOFT: FallTicks←FallTicks+1
 interval←3⌈⌊48×0.82*Level-1
 →(FallTicks<interval)/LOCK
 FallTicks←0 ⋄ moved←MoveAction 2
LOCK: →(Actions[2;Pose]≠Pose)/AIR
 LockTicks←LockTicks+1
 →(LockTicks<30)/DONE
 unused←LockPiece 0 ⋄ →DONE
AIR: LockTicks←0
 →DONE
INSPECT: unused←InspectTick pressed
DONE:
∇

unused←InitGeometry 0
