-module(etorrent_chunkset).

-export([new/2,
         new/1,
         proto_full/1,
         proto_empty/1,
         size/1,
         min/1,
         min/2,
         extract/2,
         is_empty/1,
         delete/2,
         delete/3,
         insert/3,
         from_list/3,
         in/3,
         subtract/3]).

-record(chunkset, {
    piece_len :: pos_integer(),
    chunk_len :: pos_integer(),
    chunks :: list({non_neg_integer(), pos_integer()})}).

-opaque chunkset() :: #chunkset{}.
-export_type([chunkset/0]).

%% @doc
%% Create a set of chunks for a piece.
%% @end
-spec new(pos_integer(), pos_integer()) -> chunkset().
new(PieceLen, ChunkLen) ->
    #chunkset{
        piece_len=PieceLen,
        chunk_len=ChunkLen,
        chunks=[{0, PieceLen - 1}]}.


%% @doc Create am empty copy of the chunkset.
new(Prototype) ->
    Prototype#chunkset{chunks=[]}.


%% @doc Create a copy with all chunks, using a prototype.
proto_full(#chunkset{piece_len=PieceLen, chunk_len=ChunkLen}) ->
    #chunkset{
        piece_len=PieceLen,
        chunk_len=ChunkLen,
        chunks=[{0, PieceLen - 1}]}.


%% @doc Create an empty copy, using a prototype.
proto_empty(#chunkset{piece_len=PieceLen, chunk_len=ChunkLen}) ->
    #chunkset{
        piece_len=PieceLen,
        chunk_len=ChunkLen,
        chunks=[]}.


from_list(PieceLen, ChunkLen, Chunks) ->
    #chunkset{
        piece_len=PieceLen,
        chunk_len=ChunkLen,
        chunks=Chunks}.

%% @doc
%% Get sum of the size of all chunks in the chunkset.
%% @end
-spec size(chunkset()) -> non_neg_integer().
size(Chunkset) ->
    #chunkset{chunks=Chunks} = Chunkset,
    Lengths = [1 + End - Start || {Start, End} <- Chunks],
    lists:sum(Lengths).

%% @doc
%% Get the offset and length of the chunk that is the closest
%% to the beginning of the piece. The chunk that is returned may
%% be shorter than the chunk length of the set.
%% @end
-spec min(chunkset()) -> {pos_integer(), pos_integer()}.
min(Chunkset) ->
    case min_(Chunkset) of
        none  -> erlang:error(badarg);
        Other -> Other
    end.

min_(Chunkset) ->
    #chunkset{chunk_len=ChunkLen, chunks=Chunks} = Chunkset,
    case Chunks of
        [] ->
            none;
        [{Start, End}|_] when (1 + End - Start) > ChunkLen ->
            {Start, ChunkLen};
        [{Start, End}|_] when (1 + End - Start) =< ChunkLen ->
            {Start, (End - Start) + 1}
    end.

%% @doc
%% Get at most N chunks from the beginning of the chunkset.
%% @end
min(_, Numchunks) when Numchunks < 1 ->
    erlang:error(badarg);
min(Chunkset, Numchunks) ->
    case min_(Chunkset, Numchunks) of
        [] -> erlang:error(badarg);
        List -> List
    end.

min_(_, 0) ->
    [];
min_(Chunkset, Numchunks) ->
    case min_(Chunkset) of
        none -> [];
        {Start, Size}=Chunk ->
            Without = delete(Start, Size, Chunkset),
            [Chunk|min_(Without, Numchunks - 1)]
    end.


%% @doc This operation combines min/2 and delete.
extract(Chunkset, Numchunks) when Numchunks >= 0 ->
    extract_(Chunkset, Numchunks, []).


extract_(Chunkset, 0, Acc) ->
    {lists:reverse(Acc), Chunkset, 0};

extract_(Chunkset, Numchunks, Acc) ->
    case min_(Chunkset) of
        none -> 
            {lists:reverse(Acc), Chunkset, Numchunks};

        {Start, Size}=Chunk ->
            Without = delete(Start, Size, Chunkset),
            extract_(Without, Numchunks - 1, [Chunk|Acc])
    end.



in(Offset, Size, Chunkset) ->
    NewChunkset = delete(Offset, Size, Chunkset),
    OldSize = ?MODULE:size(Chunkset),
    NewSize = ?MODULE:size(NewChunkset),
    Size =:= (OldSize - NewSize).


%% @doc This operation run `delete/3' and return result and 
%%      the list of the deleted values.
subtract(Offset, Length, Chunkset) when Length > 0, Offset >= 0 ->
    #chunkset{chunks=Chunks} = Chunkset,
    {NewChunks, Deleted} = sub_(Offset, Offset + Length - 1, Chunks, [], []),
    {Chunkset#chunkset{chunks=NewChunks}, rev_deleted_(Deleted, [])}.

%% E = S + L - 1.
%% L = E - S + 1.
rev_deleted_([{S, E}|T], Acc) ->
    L = E - S + 1,
    rev_deleted_(T, [{S, L}|Acc]);

rev_deleted_([], Acc) -> Acc.


sub_(CS, CE, [{S, E}=H|T], Res, Acc) 
    when is_integer(S), is_integer(CS), 
         is_integer(E), is_integer(CE) ->
    if
    CS =< S, CE =:= E ->
        % full match
        {lists:reverse(Res, T), [H|Acc]}; % H
    CS =< S, CE < E, CE > S ->
        % try delete smaller piece
        {lists:reverse(Res, [{CE+1, E}|T]), [{S, CE}|Acc]};
    CS =< S, CE < S ->
        % skip range
        {lists:reverse(Res, [H|T]), Acc};
    CS =< S, CE > E ->
        % try delete bigger piece
        sub_(E+1, CE, T, Res, [H|Acc]);
    CS > S, CE =:= E ->
        % try delete smaller piece
        {lists:reverse(Res, [{S, CS-1}|T]), [{CS, E}|Acc]};
    CS > S, CE < E ->
        % try delete smaller piece
        {lists:reverse(Res, [{S, CS-1},{CE+1, E}|T]), 
         [{CS, CE}|Acc]};
    CS > S, CS < E, CE > E ->
        % try delete bigger piece
        sub_(E+1, CE, T, [{S, CS-1}|Res], [{CS, E}|Acc]);
    CS > E ->
        % chunk is higher
        sub_(E+1, CE, T, [H|Res], Acc)
    end;
sub_(_CS, _CE, [], Res, Acc) ->
    {lists:reverse(Res), Acc}.
    

%% @doc Check is a chunkset is empty
%% @end
is_empty(Chunkset) ->
    #chunkset{chunks=Chunks} = Chunkset,
    Chunks == [].


%% @doc
%%
%% @end
delete([], Chunkset) ->
    Chunkset;
delete([{Offset, Length}|T], Chunkset) ->
    delete(T, delete(Offset, Length, Chunkset)).

%% @doc
%% 
%% @end
delete(Offset, Length, _Chunkset) when Length < 1; Offset < 0 ->
    erlang:error(badarg);
delete(Offset, Length, Chunkset) ->
    #chunkset{chunks=Chunks} = Chunkset,
    NewChunks = delete_(Offset, Offset + Length - 1, Chunks),
    Chunkset#chunkset{chunks=NewChunks}.

delete_(_, _, []) ->
    [];
delete_(ChStart, ChEnd, [{Start, End}=H|T]) when ChStart =< Start ->
    if  ChEnd == End  -> T;
        ChEnd < Start -> [H|T];
        ChEnd < End   -> [{ChEnd + 1, End}|T];
        ChEnd > End   -> delete_(End, ChEnd, T)
    end;
delete_(ChStart, ChEnd, [{Start, End}|T]) when ChStart =< End ->
    if  ChStart == End -> [{Start, ChStart - 1}|delete_(End, ChEnd, T)];
        ChEnd   == End -> [{Start, ChStart - 1}|T];
        ChEnd   <  End -> [{Start, ChStart - 1},{ChEnd + 1, End}|T];
        ChEnd   >  End -> [{Start, ChStart - 1}|delete_(End, ChEnd, T)]
    end;
delete_(ChStart, ChEnd, [H|T]) ->
    [H|delete_(ChStart, ChEnd, T)].

%% @doc
%%
%% @end
insert(Offset, _, _) when Offset < 0 ->
    erlang:error(badarg);
insert(_, Length, _) when Length < 1 ->
    erlang:error(badarg);
insert(Offset, Length, Chunkset) ->
    #chunkset{piece_len=PieceLen, chunks=Chunks} = Chunkset,
    case (Offset + Length) > PieceLen of
        true ->
            erlang:error(badarg);
        false ->
            NewChunks = insert_(Offset, Offset + Length - 1, Chunks),
            Chunkset#chunkset{chunks=NewChunks}
    end.

insert_(ChStart, ChEnd, []) ->
    [{ChStart, ChEnd}];
insert_(ChStart, ChEnd, [{Start, _}|T]) when ChStart > Start ->
    insert_(Start, ChEnd, T);
insert_(ChStart, ChEnd, [{_, End}|T]) when ChEnd =< End ->
    [{ChStart, End}|T];
insert_(ChStart, ChEnd, [{_, End}|T]) when ChEnd > End ->
    insert_(ChStart, ChEnd, T).

