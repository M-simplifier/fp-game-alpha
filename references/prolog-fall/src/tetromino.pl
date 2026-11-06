:- module(tetromino, [piece/1, shape/3, piece_cells/5, legal_pose/3,
                      enumerate_pose/3, cover_cells/2, pose_cells/2, supported/2,
                      move_pose/4, landing/4, lock_board/5, clear_rows/3]).
:- use_module(library(clpfd)).

piece(i). piece(o). piece(t). piece(s). piece(z). piece(j). piece(l).

% Local integer coordinates. J/L/S/T/Z rotate in a 3x3 box; I in 4x4.
% These are shapes, not a promise of SRS kicks (see move_pose/4 below).
shape(i,0,[0-1,1-1,2-1,3-1]).
shape(i,1,[2-0,2-1,2-2,2-3]).
shape(i,2,[0-2,1-2,2-2,3-2]).
shape(i,3,[1-0,1-1,1-2,1-3]).
shape(o,0,[1-0,2-0,1-1,2-1]).
shape(o,1,[1-0,2-0,1-1,2-1]).
shape(o,2,[1-0,2-0,1-1,2-1]).
shape(o,3,[1-0,2-0,1-1,2-1]).
shape(t,0,[1-0,0-1,1-1,2-1]).
shape(t,1,[1-0,1-1,2-1,1-2]).
shape(t,2,[0-1,1-1,2-1,1-2]).
shape(t,3,[1-0,0-1,1-1,1-2]).
shape(s,0,[1-0,2-0,0-1,1-1]).
shape(s,1,[1-0,1-1,2-1,2-2]).
shape(s,2,[1-1,2-1,0-2,1-2]).
shape(s,3,[0-0,0-1,1-1,1-2]).
shape(z,0,[0-0,1-0,1-1,2-1]).
shape(z,1,[2-0,1-1,2-1,1-2]).
shape(z,2,[0-1,1-1,1-2,2-2]).
shape(z,3,[1-0,0-1,1-1,0-2]).
shape(j,0,[0-0,0-1,1-1,2-1]).
shape(j,1,[1-0,2-0,1-1,1-2]).
shape(j,2,[0-1,1-1,2-1,2-2]).
shape(j,3,[1-0,1-1,0-2,1-2]).
shape(l,0,[2-0,0-1,1-1,2-1]).
shape(l,1,[1-0,1-1,1-2,2-2]).
shape(l,2,[0-1,1-1,2-1,0-2]).
shape(l,3,[0-0,1-0,1-1,1-2]).

% piece_cells(?Piece, ?Orientation, ?X, ?Y, ?Cells)
% The same four-cell relation is used by rendering, collision and gap queries.
piece_cells(P,R,X,Y,Cells) :-
    R in 0..3, X in -3..9, Y in -4..19,
    shape(P,R,Offsets), maplist(translate(X,Y),Offsets,Cells).
translate(X,Y,DX-DY,CX-CY) :- CX #= X+DX, CY #= Y+DY.
pose_cells(pose(P,R,X,Y),Cells) :- piece_cells(P,R,X,Y,Cells).

% legal_pose(+GroundBoard, ?Pose, ?Cells). It posts finite integer constraints;
% it does NOT enumerate coordinates. Board = list of cell(X,Y,Piece).
% Occupied cells may be in four hidden rows (-4..-1) while moving/spawning.
legal_pose(Board,pose(P,R,X,Y),Cells) :-
    piece_cells(P,R,X,Y,Cells),
    maplist(in_bounds,Cells), maplist(unoccupied(Board),Cells).
in_bounds(X-Y) :- X in 0..9, Y in -4..19.
unoccupied(Board,X-Y) :-
    ( integer(X), integer(Y) -> \+ memberchk(cell(X,Y,_),Board)
    ; maplist(disjoint(X,Y),Board)
    ).
disjoint(X,Y,cell(BX,BY,_)) :- X #\= BX #\/ Y #\= BY.

enumerate_pose(Board,pose(P,R,X,Y),Cells) :-
    legal_pose(Board,pose(P,R,X,Y),Cells), labeling([],[R,X,Y]).

% cover_cells(+UnorderedGroundCells, ?Pose) enumerates every exact fit. Four
% distinct visible cells bound the problem; the caller need not know the kind,
% orientation or origin. Permutation is only over four cells (24 cases).
cover_cells(Target,pose(P,R,X,Y)) :-
    ground(Target),length(Target,4),maplist(target_cell,Target),
    sort(Target,Unique),length(Unique,4),
    permutation(Unique,Ordered),piece_cells(P,R,X,Y,Ordered),
    labeling([],[R,X,Y]).
target_cell(X-Y) :- integer(X),integer(Y),between(0,9,X),between(0,19,Y).

% Directional transition: ground Board + Pose + Action -> at most one Pose.
% Rotation tests kicks IN ORDER and commits to the first valid one. This
% deliberate small policy is shared by play, reachability and witness replay.
move_pose(B,pose(P,R,X,Y),left,N) :- NX is X-1, N=pose(P,R,NX,Y), legal_pose(B,N,_).
move_pose(B,pose(P,R,X,Y),right,N) :- NX is X+1, N=pose(P,R,NX,Y), legal_pose(B,N,_).
move_pose(B,pose(P,R,X,Y),down,N) :- NY is Y+1, N=pose(P,R,X,NY), legal_pose(B,N,_).
move_pose(B,pose(P,R,X,Y),A,N) :-
    rotation(A,D), NR is (R+D+4) mod 4,
    once((kick(DX,DY), NX is X+DX, NY is Y+DY,
          N=pose(P,NR,NX,NY), legal_pose(B,N,_))).
rotation(cw,1). rotation(ccw,-1).
kick(0,0). kick(-1,0). kick(1,0). kick(-2,0). kick(2,0).
kick(0,-1). kick(-1,-1). kick(1,-1). kick(0,-2).

supported(B,P) :- legal_pose(B,P,_), \+ move_pose(B,P,down,_).
landing(B,P,L,Distance) :- landing_(B,P,0,L,Distance).
landing_(B,P,N,L,D) :-
    ( move_pose(B,P,down,Q) -> M is N+1, landing_(B,Q,M,L,D)
    ; L=P, D=N ).

% Lock accepts a supported, fully visible pose. Caller handles top-out.
lock_board(B,Pose,Out,Count,Rows) :-
    supported(B,Pose), pose_cells(Pose,Cells), maplist(visible,Cells),
    Pose=pose(P,_,_,_), maplist(as_cell(P),Cells,Added),
    append(B,Added,Before), clear_rows(Before,Out,Rows), length(Rows,Count).
visible(_-Y) :- Y>=0.
as_cell(P,X-Y,cell(X,Y,P)).

clear_rows(B,Out,Rows) :-
    findall(Y,(between(0,19,Y),full_row(B,Y)),Rows),
    exclude(in_rows(Rows),B,Remaining), maplist(compact(Rows),Remaining,Shifted),
    sort(Shifted,Out).
full_row(B,Y) :- forall(between(0,9,X),memberchk(cell(X,Y,_),B)).
in_rows(Rows,cell(_,Y,_)) :- memberchk(Y,Rows).
compact(Rows,cell(X,Y,P),cell(X,NY,P)) :-
    include(below(Y),Rows,Below), length(Below,N), NY is Y+N.
below(Y,R) :- R>Y.
