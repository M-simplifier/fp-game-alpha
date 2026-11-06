:- use_module('../src/tetromino').
:- use_module('../src/game').
:- use_module('../src/reachability').
:- use_module(library(clpfd)).
:- use_module(library(plunit)).

:- begin_tests(geometry).
test(seven_kinds) :- findall(P,piece(P),Ps),sort(Ps,[i,j,l,o,s,t,z]).
test(each_shape_has_four_distinct_cells) :-
    forall(shape(_,_,Cells),(length(Cells,4),sort(Cells,S),length(S,4))).
test(t_fixture_exact) :- piece_cells(t,0,3,18,[4-18,3-19,4-19,5-19]).
test(validation_ground) :- legal_pose([],pose(t,0,3,18),[4-18,3-19,4-19,5-19]).
test(wall_failure,[fail]) :- legal_pose([],pose(t,0,-1,18),_).
test(floor_failure,[fail]) :- legal_pose([],pose(t,0,3,19),_).
test(ceiling_finite,[fail]) :- legal_pose([],pose(i,1,3,-5),_).
test(collision_failure,[fail]) :- legal_pose([cell(4,18,j)],pose(t,0,3,18),_).
test(partial_x_domain) :-
    legal_pose([cell(4,19,j)],pose(o,0,X,18),_),
    findall(X,labeling([],[X]),Xs),assertion(Xs==[-1,0,1,4,5,6,7]).
test(partial_orientation) :-
    findall(R,legal_pose([],pose(i,R,7,16),_),Rs),assertion(Rs==[1,3]).
test(partial_kind) :- findall(P,gap_piece(P),Ps),assertion(Ps==[t]).
test(partial_translation_from_cells) :-
    piece_cells(t,0,X,Y,[5-7,4-8,5-8,6-8]),assertion(X==4),assertion(Y==7).
test(unordered_translated_rotated_reverse_query) :-
    findall(Pose,cover_cells([6-9,5-10,5-8,5-9],Pose),Poses),
    assertion(Poses==[pose(t,1,4,8)]).
test(cover_i_has_two_coordinate_representatives) :-
    findall(Pose,cover_cells([7-12,4-12,6-12,5-12],Pose),Raw),sort(Raw,Poses),
    assertion(Poses==[pose(i,0,4,11),pose(i,2,4,10)]).
test(cover_o_retains_orientation_ambiguity) :-
    findall(Pose,cover_cells([4-7,3-8,3-7,4-8],Pose),Raw),sort(Raw,Poses),
    assertion(Poses==[pose(o,0,2,7),pose(o,1,2,7),pose(o,2,2,7),pose(o,3,2,7)]).
test(cover_disconnected_set_fails,[fail]) :- cover_cells([0-0,3-3,5-5,9-9],_).
test(cover_duplicate_cell_fails,[fail]) :- cover_cells([3-7,3-7,4-7,4-8],_).
test(ground_vs_partial_collision_modes) :-
    B=[cell(2,19,j),cell(7,18,l)],
    findall(X,(legal_pose(B,pose(o,0,X,18),_),labeling([],[X])),Partial),
    findall(X,(between(-1,7,X),legal_pose(B,pose(o,0,X,18),_)),Ground),
    assertion(Partial==Ground).
:- end_tests(geometry).

:- begin_tests(transitions).
test(left_wall_fails,[fail]) :- move_pose([],pose(o,0,-1,18),left,_).
test(rotation_first_kick_fixture) :-
    move_pose([],pose(t,1,-1,5),cw,Q),assertion(Q==pose(t,2,0,5)).
test(rotation_zero_kick_has_priority) :-
    findall(Q,move_pose([],pose(t,0,3,5),cw,Q),Qs),assertion(Qs==[pose(t,1,3,5)]).
test(rotation_four_turns) :-
    replay_path([],pose(j,0,3,5),[cw,cw,cw,cw],pose(j,0,3,5)).
test(rotation_blocked,[fail]) :-
    findall(cell(X,Y,j),(between(0,9,X),between(5,10,Y),\+memberchk(X-Y,[4-7,3-8,4-8,5-8])),B),
    move_pose(B,pose(t,0,3,7),cw,_).
test(landing_empty_fixture) :-
    landing([],pose(t,0,3,-1),P,D),assertion(P==pose(t,0,3,18)),assertion(D==19).
test(line_clear_compacts_only_above) :-
    findall(cell(X,18,j),between(0,9,X),Row),
    append(Row,[cell(0,4,l),cell(5,19,t)],B),clear_rows(B,Out,Rows),
    assertion(Rows==[18]),assertion(Out==[cell(0,5,l),cell(5,19,t)]).
test(two_rows_compact_by_two) :-
    findall(cell(X,Y,j),(between(18,19,Y),between(0,9,X)),Rows),
    clear_rows([cell(2,2,t)|Rows],Out,[18,19]),assertion(Out==[cell(2,4,t)]).
test(demo_lock_expected_board) :-
    demo_board(B),lock_board(B,pose(t,0,3,18),Out,1,[19]),
    sort([cell(0,19,j),cell(1,19,j),cell(0,18,j),cell(4,19,t),
          cell(8,19,l),cell(9,19,l),cell(9,18,l)],Expected),assertion(Out==Expected).
test(unsupported_lock_fails,[fail]) :- lock_board([],pose(t,0,3,5),_,_,_).
test(top_out_lock_fails,[fail]) :-
    lock_board([cell(4,1,j),cell(5,1,j)],pose(o,0,3,-1),_,_,_).
test(clear_projection_not_injective) :-
    projection_witness(A,B,Out),length(A,10),length(B,20),assertion(Out==[]).
:- end_tests(transitions).

:- begin_tests(gameplay).
test(initial_valid) :- new_game(42,S),game_valid(S).
test(first_two_bags) :-
    fill_queue([],42,Q,S),take_piece(Q,S,P,Rest,_),
    append([P|Rest],[],All),length(A,7),append(A,B,All),
    msort(A,Sorted),msort(B,Sorted),assertion(Sorted==[i,j,l,o,s,t,z]).
test(hold_once_before_lock) :-
    new_game(42,S),act(S,hold,A),act(A,hold,B),assertion(A==B),
    assertion(A.hold==s),assertion(A.active==pose(j,0,3,-1)),assertion(A.hold_used==true).
test(hold_reset_and_swap) :-
    new_game(42,S),act(S,hold,A),act(A,hard_drop,B),act(B,hold,C),
    assertion(C.active==pose(s,0,3,-1)),assertion(C.hold==t),
    assertion(C.queue==B.queue),assertion(C.hold_used==true).
test(hard_drop_score_and_lock) :-
    demo_game(42,S),act(S,hard_drop,N),
    assertion(N.lines==1),assertion(N.score==138),assertion(N.pieces==1),game_valid(N).
test(soft_drop_one_point) :-
    new_game(42,S),act(S,down,N),assertion(N.score==1),assertion(N.active==pose(s,0,3,0)).
test(invalid_move_preserves_state) :-
    new_game(42,S0),S=S0.put(active,pose(o,0,-1,18)),act(S,left,N),assertion(N==S).
test(lock_delay) :-
    new_game(42,S0),S=S0.put(active,pose(o,0,3,18)),
    ticks(9,0.05,S,A),assertion(A.pieces==0),
    ticks(2,0.05,A,B),assertion(B.pieces==1),game_valid(B).
test(lock_reset_is_bounded) :-
    new_game(42,S0),S=S0.put(_{active:pose(o,0,3,18),lock:0.4,resets:14}),
    act(S,left,A),assertion(A.lock=:=0.0),assertion(A.resets==15),
    T=A.put(lock,0.4),act(T,right,B),assertion(B.lock=:=0.4),assertion(B.resets==15).
test(gravity_does_not_score) :-
    new_game(42,S0),S=S0.put(gravity,0.74),tick(S,0.02,A),
    assertion(A.active==pose(s,0,3,0)),assertion(A.score==0).
test(game_over_on_hidden_lock) :-
    new_game(42,S0),S=S0.put(_{active:pose(o,0,3,-1),board:[cell(4,1,j),cell(5,1,j)]}),
    act(S,hard_drop,A),assertion(A.status==game_over).
test(game_over_on_blocked_spawn) :-
    new_game(42,S0),
    S=S0.put(_{active:pose(o,0,0,18),board:[cell(3,0,j)]}),
    act(S,hard_drop,A),assertion(A.status==game_over).
test(game_over_absorbs_actions) :-
    new_game(42,S0),S=S0.put(status,game_over),act(S,hard_drop,S),tick(S,0.05,S).
test(level_and_scoring) :-
    demo_game(42,S0),S=S0.put(_{lines:9,level:1}),act(S,hard_drop,A),
    assertion(A.lines==10),assertion(A.level==2),assertion(A.score==138).
test(deterministic_full_replay) :-
    new_game(2026,S),Trace=[hold,cw,left,hard_drop,right,cw,hard_drop,
                         ccw,left,left,hard_drop,hold,down,hard_drop],
    actions(Trace,S,A),actions(Trace,S,B),assertion(A==B),game_valid(A),
    assertion(A.pieces==4).
ticks(0,_,S,S) :- !.
ticks(N,D,S,O) :- tick(S,D,T),M is N-1,ticks(M,D,T,O).
actions([],S,S).
actions([A|As],S,O) :- act(S,A,T),actions(As,T,O).
:- end_tests(gameplay).

:- begin_tests(search).
test(empty_o_has_nine_physical_landings) :-
    reachable_locks([],pose(o,0,3,-1),Cs,Info),length(Cs,9),
    assertion(Info.poses>Info.landings),
    forall(member(candidate(_,0,_,Cells),Cs),
           (member(_-18,Cells),member(_-19,Cells))).
test(all_witnesses_replay_and_lock) :-
    demo_board(B),Start=pose(t,0,3,-1),reachable_locks(B,Start,Cs,_),
    forall(member(candidate(P,L,Path,Cells),Cs),
           (replay_path(B,Start,Path,P),supported(B,P),
            lock_board(B,P,_,L,_),pose_cells(P,Raw),sort(Raw,Cells))).
test(demo_line_clear_is_found,[nondet]) :-
    demo_board(B),reachable_locks(B,pose(t,0,3,-1),Cs,_),
    member(candidate(pose(t,0,3,18),1,Path,_),Cs),length(Path,19),maplist(=(down),Path).
test(no_duplicate_cell_sets) :-
    reachable_locks([],pose(i,0,3,-1),Cs,_),
    findall(Cells,member(candidate(_,_,_,Cells),Cs),All),sort(All,U),same_length(All,U).
test(cavity_is_static_legal_and_supported) :-
    cavity_fixture(B,_,Target),legal_pose(B,Target,[4-18,5-18,4-19,5-19]),supported(B,Target).
test(cavity_is_not_reachable) :-
    cavity_fixture(B,Start,Target),reachable_poses(B,Start,Nodes,_),
    assertion(\+member(node(Target,_),Nodes)),
    reachable_locks(B,Start,Cs,_),
    assertion(\+member(candidate(_,_,_,[4-18,4-19,5-18,5-19]),Cs)).
test(shortest_empty_drop_witness,[nondet]) :-
    reachable_locks([],pose(o,0,3,17),Cs,_),
    member(candidate(pose(o,0,3,18),0,[down],_),Cs).
test(search_preserves_orientation_states) :-
    reachable_poses([],pose(o,0,3,18),Nodes,_),
    forall(between(0,3,R),member(node(pose(o,R,3,18),_),Nodes)).
test(search_rejects_illegal_start,[fail]) :- reachable_locks([],pose(o,0,-3,18),_,_).
:- end_tests(search).

:- initialization((run_tests -> halt(0) ; halt(1)),main).
