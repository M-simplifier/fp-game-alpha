⍝ Board-fixed graph closure over the exact five gameplay destination maps.
∇ z←ReachFrom start;front;next;sources;action;dest;fresh;first;ids
 ids←⍳PoseCount
 Reachable←PoseCount⍴0 ⋄ Parents←PoseCount⍴¯1 ⋄ ParentActions←PoseCount⍴¯1
 Reachable[start]←1 ⋄ front←Reachable ⋄ ReachLayers←0
LAYER: next←PoseCount⍴0 ⋄ sources←front/ids ⋄ action←0
ACTION: dest←Actions[action;sources]
 fresh←∪(~Reachable[dest])/dest
 →(0=⍴fresh)/NEXTACTION
 first←dest⍳fresh
 Parents[fresh]←sources[first] ⋄ ParentActions[fresh]←action
 Reachable[fresh]←1 ⋄ next[fresh]←1
NEXTACTION: action←action+1 ⋄ →(action<5)/ACTION
 ReachLayers←ReachLayers+1 ⋄ front←next
 →(∨/front)/LAYER
 StaticLandings←Field∧(Actions[2;]=ids)
 Supported←Reachable∧StaticLandings
 z←0
∇

∇ path←Witness target;at
 path←⍬ ⋄ at←target
LOOP: →(Parents[at]<0)/DONE
 path←ParentActions[at],path
 at←Parents[at] ⋄ →LOOP
DONE:
∇

∇ z←BeginInspect ignored;unused
 InspectStart←Pose
 unused←ReachFrom Pose
 LandingList←Supported/⍳PoseCount
 Selection←0
 ReplayPath←⍬ ⋄ ReplayAt←0 ⋄ ReplayTicks←0
 z←0
∇

∇ z←InspectTick pressed;unused;moved
 z←0
 →(0=⍴LandingList)/DONE
 →(~pressed[13])/NONEXT
 Selection←((⍴LandingList)[0])|Selection-1
 ReplayPath←⍬ ⋄ Pose←InspectStart
NONEXT: →(~pressed[14])/NOREPLAY
 Selection←((⍴LandingList)[0])|Selection+1
 ReplayPath←⍬ ⋄ Pose←InspectStart
NOREPLAY: →(~pressed[12])/PLAY
 Pose←InspectStart
 ReplayPath←Witness LandingList[Selection]
 ReplayAt←0 ⋄ ReplayTicks←0
PLAY: →(ReplayAt≥⍴ReplayPath)/DONE
 ReplayTicks←ReplayTicks+1
 →(ReplayTicks<5)/DONE
 ReplayTicks←0
 moved←MoveAction ReplayPath[ReplayAt]
 ReplayAt←ReplayAt+1
DONE:
∇

⍝ An enclosed left cavity and two rows with an O-shaped opening at right.
∇ z←LoadDemo ignored;unused
 unused←NewGame InitialSeed
 Board[20 21;]←7
 Board[20 21;7 8]←0
 Board[16;0 1 2 3 4]←2
 Board[17 18 19;4]←2
 Board[18;6]←6 ⋄ Board[19;6]←6
 Type←3
 →(0=⎕NC 'DemoType')/TYPESET
 Type←DemoType
TYPESET: Pose←PoseIndex 0 0 3
 unused←Refresh 0
 Mode←3 ⋄ unused←BeginInspect 0
 z←0
∇
