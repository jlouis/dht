-module(etorrent_metadata_variant).
-export([new/0,
         extract_data/2,
         save_piece/4,
         request_piece/2,
         add_peer/3
]).

-record(md_var, {
        peers=dict:new(),
        pieces=array:new([{default, []}]),
        piece_set=0,
        downloaded_piece_count=0
}).

-record(peer, {
        piece_count,
        downloaded_piece_count=0,
        %% Piece order
        schedule :: [non_neg_integer()],
        %% List of pieces (and their position) with position =/= 0
        exceptions=[]
}).

new() ->
    #md_var{}.


add_peer(PeerPid, PieceCount, Var=#md_var{peers=Peers})
    when is_integer(PieceCount), is_pid(PeerPid) ->
    PieceOrder = etorrent_utils:list_shuffle(lists:seq(0, PieceCount-1)),
    Peer = #peer{schedule=PieceOrder, piece_count=PieceCount},
    Var#md_var{peers=dict:store(PeerPid, Peer, Peers)}.


request_piece(PeerPid, #md_var{peers=Peers})
    when is_pid(PeerPid) ->
    #peer{schedule=[PieceNum|_]} = dict:fetch(PeerPid, Peers),
    PieceNum.


%% G means global.
save_piece(PeerPid, PieceNum, Piece,
           Var=#md_var{peers=Peers, pieces=Pieces, piece_set=GPieceSet,
                       downloaded_piece_count=GDownPieceCount})
    when is_integer(PieceNum), is_pid(PeerPid) ->
    #peer{schedule=[PieceNum|PieceOrder], piece_count=PieceCount,
          downloaded_piece_count=DownPieceCount, exceptions=Exs} =
    Peer = dict:fetch(PeerPid, Peers),
    %% different variants of pieces on the same position.
    PieceVars = array:get(PieceNum, Pieces),
    {PiecePos, PieceVars2} = save(PieceVars, Piece),
    Exs2 = case PiecePos of
            0 -> Exs; %% no exceptions
            ExPos -> %% there are few versions of the piece.
                [{PieceNum, ExPos}|Exs]
        end,
    Pieces2 = array:set(PieceNum, PieceVars2, Pieces),
    Peer2 = Peer#peer{downloaded_piece_count=DownPieceCount+1,
                      schedule=PieceOrder,
                      exceptions=Exs2},
    GPieceSet2 = set_bit(GPieceSet, PieceNum),
    GDownPieceCount2 = GDownPieceCount
                     + case GPieceSet of GPieceSet2 -> 0; _ -> 1 end,
    Var2 = Var#md_var{peers=dict:store(PeerPid, Peer2, Peers),
                      pieces=Pieces2,
                      piece_set=GPieceSet2,
                      downloaded_piece_count=GDownPieceCount2},
    PeerProgress = case DownPieceCount+1 of
            PieceCount -> downloaded;
            _ -> in_progress
        end,
    GlobalProgress = case GDownPieceCount2 of
            PieceCount ->
            %% not enough, if there are few variations with different length.
            %% Check, that first PieceCount bits are set.
            case all_bits_set(GPieceSet2, PieceCount) of
                true  -> downloaded;
                false -> in_progress
            end;
            _ -> in_progress
        end,
    {PeerProgress, GlobalProgress, Var2}.


%% This code allows to share pieces with peers.
%% If piece_count =/= downloaded_piece_count, than few pieces will be
%% retrieved from other peers.
-spec extract_data(PeerPid::pid(), #md_var{}) -> iolist().
extract_data(PeerPid, #md_var{peers=Peers, pieces=Pieces})
    when is_pid(PeerPid) ->
    #peer{exceptions=Exs, piece_count=PieceCount} = dict:fetch(PeerPid, Peers),
    build_pieceset(extract_data_cycle(0, PieceCount, Exs), Pieces).


%% ------------------------------------------------------------------

%% Returns a list of pieces' positions.
extract_data_cycle(PieceCount, PieceCount, _Exs) -> [];
extract_data_cycle(PieceNum, PieceCount, Exs) ->
    [{PieceNum, proplists:get_value(PieceNum, Exs, 0)}
     |extract_data_cycle(PieceNum+1, PieceCount, Exs)].

build_pieceset(Positions, Pieces) ->
    [lists:nth(PiecePos+1, array:get(PieceNum, Pieces))
    || {PieceNum, PiecePos} <- Positions].

    
%% ------------------------------------------------------------------
%% Lists

save(Xs, X) -> 
    case find_pos(Xs, X) of
        not_found -> {length(Xs), [X|Xs]};
        Pos       -> {Pos, Xs}
    end.

find_pos([X|Xs], X) -> length(Xs);
find_pos([], _)     -> not_found.


%% ------------------------------------------------------------------
%% Bits

%get_bit(N, B) -> N band bit_to_int(B) > 0.
set_bit(N, B) -> N bor bit_to_int(B).

%% C is size of the set.
all_bits_set(N, C) -> N =:= 1 bsl C - 1.

bit_to_int(B) -> 1 bsl B.

