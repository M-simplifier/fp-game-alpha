:- use_module(tetromino).
:- use_module(game).
:- use_module(reachability).
:- use_module(library(clpfd)).
:- use_module(library(http/json)).

main :-
    legal_pose([],pose(t,0,3,18),GroundCells),
    findall(X,(legal_pose([cell(4,19,j)],pose(o,0,X,18),_),labeling([],[X])),Xs),
    findall(P,cover_cells([6-9,5-10,5-8,5-9],P),Cover),
    findall(P,cover_cells([7-12,4-12,6-12,5-12],P),IRepresentatives),
    demo_board(B),reachable_locks(B,pose(t,0,3,-1),Candidates,Info),
    Candidates=[candidate(First,Lines,Path,_)|_],length(Path,Steps),
    replay_path(B,pose(t,0,3,-1),Path,First),
    cavity_fixture(Cavity,Start,Target),legal_pose(Cavity,Target,_),supported(Cavity,Target),
    reachable_poses(Cavity,Start,Nodes,CavityCount),\+member(node(Target,_),Nodes),
    projection_witness(A,C,[]),length(A,AN),length(C,CN),
    maplist(term_atom,GroundCells,CellAtoms),maplist(term_atom,Cover,CoverAtoms),
    maplist(term_atom,IRepresentatives,IAtoms),term_atom(First,FirstAtom),
    Report=_{ground_cells:CellAtoms,unknown_x:Xs,unknown_kind_rotation_origin:CoverAtoms,
             i_representation_ambiguity:IAtoms,demo_query:Info,
             first_landing:FirstAtom,first_lines:Lines,first_steps:Steps,
             witness_replays:true,cavity_static_legal:true,cavity_reachable:false,
             cavity_visited_poses:CavityCount,projection_predecessor_sizes:[AN,CN],projection_result:[]},
    json_write_dict(current_output,Report,[width(100)]),nl.
term_atom(T,A) :- term_to_atom(T,A).
:- initialization(main,main).
