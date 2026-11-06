% Teaching data only. Import and exercise the actual game relations; do not
% redefine game movement, shapes, search, collision, or row clearing here.
:- use_module('../src/tetromino').
:- use_module('../src/game').
:- use_module('../src/reachability').
:- use_module(library(clpfd)).
:- use_module(library(http/json)).

main :-
    current_prolog_flag(argv,[Output]),
    demo_board(Board),Start=pose(t,0,3,-1),
    reachable_locks(Board,Start,Candidates,Info),
    must(Info.poses=:=614, demo_pose_count),must(Info.landings=:=34,demo_landing_count),
    maplist(candidate_record(Board,Start),Candidates,Records),
    reachable_poses(Board,Start,Nodes,_),layers(Nodes,Layers),
    maplist(node_record,Nodes,NodeRecords),board_json(Board,BJ),pose_json(Start,SJ),
    once((nth0(Example,Candidates,candidate(_,_,Path,_)),
          (memberchk(cw,Path);memberchk(ccw,Path)),
          (memberchk(left,Path);memberchk(right,Path)))),
    inverse_examples(Inverse),constraint_examples(Constraints),
    cavity_examples(Cavity),representation_examples(Representations),projection_examples(Projection),
    (pose(t,R,X,Y)=pose(P,1,4,8)),
    U=_{kind:P,rotation:R,x:X,y:Y},A=2+3,AInteger#=2+3,term_to_atom(A,AT),
    current_prolog_flag(version_data,swi(Major,Minor,Patch,_)),
    format(atom(Version),'~d.~d.~d',[Major,Minor,Patch]),get_time(T),
    stamp_date_time(T,UTC,'UTC'),format_time(atom(Date),'%FT%TZ',UTC,posix),
    Data=_{schema:1,generated_at:Date,swi_version:Version,
           demo:_{board:BJ,start:SJ,candidates:Records,info:Info,layers:Layers,
                  nodes:NodeRecords,motion_example_index:Example},
           inverse:Inverse,constraints:Constraints,cavity:Cavity,
           representations:Representations,projection:Projection,
           unification:_{bindings:U,ordinary_equal:AT,integer_equal:AInteger}},
    setup_call_cleanup(open(Output,write,S,[encoding(utf8)]),
        json_write_dict(S,Data,[width(0)]),close(S)),
    length(Records,N),format('Exported and validated ~d landing witnesses.~n',[N]).

must(Goal,Tag) :- (call(Goal)->true;throw(error(guide_fixture_failed(Tag),_))).
pose_json(Pose,_{kind:P,rotation:R,x:X,y:Y,cells:C}) :-
    Pose=pose(P,R,X,Y),pose_cells(Pose,Cells),maplist(pair_json,Cells,C).
pair_json(X-Y,[X,Y]).
board_json(B,J) :- maplist(cell_json,B,J).
cell_json(cell(X,Y,P),[X,Y,P]).
frames(_,P,[],[J]) :- pose_json(P,J).
frames(B,P,[A|As],[J|Js]) :- pose_json(P,J),move_pose(B,P,A,Q),frames(B,Q,As,Js).
candidate_record(B,Start,candidate(Pose,Lines,Path,Cells),Record) :-
    must(replay_path(B,Start,Path,Pose),candidate_replay),
    must(supported(B,Pose),candidate_support),
    lock_board(B,Pose,After,Lines,Rows),frames(B,Start,Path,Frames),
    pose_json(Pose,PJ),board_json(After,AJ),maplist(pair_json,Cells,CJ),
    Record=_{pose:PJ,lines:Lines,path:Path,frames:Frames,cells:CJ,after:AJ,cleared_rows:Rows}.
node_record(node(P,Rev),_{pose:J,depth:N}) :- pose_json(P,J),length(Rev,N).
layers(Nodes,Layers) :-
    findall(N,(member(node(_,Path),Nodes),length(Path,N)),Depths),max_list(Depths,Max),
    findall(_{depth:D,count:C},(between(0,Max,D),include(=(D),Depths,At),length(At,C)),Layers).

inverse_examples(Examples) :-
    findall(Example,(target(Id,Cells),
        findall(P,cover_cells(Cells,P),Poses),sort(Poses,Sorted),
        inverse_expected(Id,Expected),must(Sorted==Expected,inverse(Id)),
        maplist(pose_json,Poses,Solutions),maplist(pair_json,Cells,CJ),
        Example=_{id:Id,cells:CJ,solutions:Solutions}),Examples).
target(t,[6-9,5-10,5-8,5-9]).
target(i,[7-12,4-12,6-12,5-12]).
target(o,[4-7,3-8,3-7,4-8]).
target(impossible,[0-0,3-3,5-5,9-9]).
inverse_expected(t,[pose(t,1,4,8)]).
inverse_expected(i,[pose(i,0,4,11),pose(i,2,4,10)]).
inverse_expected(o,[pose(o,0,2,7),pose(o,1,2,7),pose(o,2,2,7),pose(o,3,2,7)]).
inverse_expected(impossible,[]).

constraint_examples(_{board:BJ,stages:[Raw,Bounded,Constrained],
                      answers:Answers,domain:Domain,residual:Residual,
                      known_pose:Known,known_cells:Cells,rejected_pose:Rejected}) :-
    B=[cell(4,19,j)],board_json(B,BJ),
    X0 in -3..9,fd_set(X0,Set0),fdset_to_list(Set0,Raw),
    legal_pose([],pose(o,0,X1,18),_),fd_set(X1,Set1),fdset_to_list(Set1,Bounded),
    legal_pose(B,pose(o,0,X2,18),_),fd_set(X2,Set2),fdset_to_list(Set2,Constrained),
    fd_dom(X2,Dom),term_to_atom(Dom,Domain),
    findall(X,(legal_pose(B,pose(o,0,X,18),_),labeling([],[X])),Answers),
    must(Answers==[-1,0,1,4,5,6,7],unknown_x),
    % fd_dom is a domain summary, not an enumeration of every solution. Keep
    % actual residual constraints: linear propagation may retain holes in X
    % until labeling checks the translated cell variables.
    copy_term(X2,ResidualX,Goals),numbervars(ResidualX-Goals,0,_),
    with_output_to(atom(Residual),write_term(Goals,[numbervars(true),quoted(true)])),
    legal_pose(B,pose(o,0,4,18),KC),maplist(pair_json,KC,Cells),
    pose_json(pose(o,0,4,18),Known),
    must(legal_pose([],pose(o,0,2,18),_),x2_inside_boundary),
    must(\+legal_pose(B,pose(o,0,2,18),_),x2_rejected_by_collision),
    pose_json(pose(o,0,2,18),Rejected).

cavity_examples(_{roof:Roof,open:Open}) :-
    cavity_fixture(B,Start,Target),exclude(roof_cell,B,WithoutRoof),
    cavity_case(B,Start,Target,false,Roof),
    cavity_case(WithoutRoof,Start,Target,true,Open).
roof_cell(cell(_,17,_)).
cavity_case(B,Start,Target,Expected,Record) :-
    must(legal_pose(B,Target,_),cavity_legal),must(supported(B,Target),cavity_support),
    reachable_poses(B,Start,Nodes,Count),maplist(node_record,Nodes,NodeRecords),
    (member(node(Target,Rev),Nodes)->Reached=true,reverse(Rev,Path);Reached=false,Path=[]),
    must(Reached==Expected,cavity_reachability(Expected)),
    board_json(B,BJ),pose_json(Start,SJ),pose_json(Target,TJ),
    (Reached==true->
        must(replay_path(B,Start,Path,Target),open_cavity_replay),
        frames(B,Start,Path,Frames),lock_board(B,Target,After,Lines,Rows),board_json(After,AJ)
    ; frames(B,Start,[],Frames),AJ=BJ,Lines=0,Rows=[]),
    Record=_{board:BJ,start:SJ,target:TJ,legal:true,supported:true,
             reachable:Reached,count:Count,nodes:NodeRecords,path:Path,
             frames:Frames,after:AJ,lines:Lines,cleared_rows:Rows}.

representation_examples(Records) :-
    P0=pose(i,0,4,11),P2=pose(i,2,4,10),
    pose_cells(P0,C0),pose_cells(P2,C2),sort(C0,Same),sort(C2,Same),
    maplist(rotation_record,[P0,P2],Records),
    Records=[A,B],must(A.after.cells\==B.after.cells,i_successors_differ),
    must(A.after.cells==[[6,11],[6,12],[6,13],[6,14]],i_rotation_zero_expected),
    must(B.after.cells==[[5,10],[5,11],[5,12],[5,13]],i_rotation_two_expected).
rotation_record(P,_{before:BJ,after:AJ}) :- move_pose([],P,cw,Q),pose_json(P,BJ),pose_json(Q,AJ).
projection_examples(_{a:_{before:AJ,after:OJ,lines:1,rows:[19]},
                      b:_{before:BJ,after:OJ,lines:2,rows:[18,19]}}) :-
    projection_witness(A,B,Out),must(Out==[],projection_empty),
    clear_rows(A,Out,[19]),clear_rows(B,Out,[18,19]),
    board_json(A,AJ),board_json(B,BJ),board_json(Out,OJ).

:- initialization(main,main).
