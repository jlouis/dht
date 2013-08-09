-module(etorrent_chunkstate).
%% This module implements the client interface to processes
%% assigning and tracking the state of chunk requests.
%%
%% This interface is implemented by etorrent_progress, etorrent_pending
%% and etorrent_endgame. Each process type handles a subset of these
%% operations. This module is intended to be used internally by the
%% torrent local services. A wrapper is provided by the etorrent_download
%% module.

%% protocol functions
-export([request/3,
         requests/1,
         assigned/5,
         assigned/3,
         dropped/5,
         dropped/3,
         dropped/2,
         fetched/5,
         stored/5,
         contents/5,
         forward/1]).

%% inspection functions
-export([format_by_peer/1,
         format_by_chunk/1]).


%% @doc Request chunks to download.
%% @end
request(Numchunks, Peerset, Srvpid) ->
    Call = {chunk, {request, Numchunks, Peerset, self()}},
    gen_server:call(Srvpid, Call).

%% @doc Return a list of requests held by a process.
%% @end
-spec requests(pid()) -> [{pid, {integer(), integer(), integer()}}].
requests(SrvPid) ->
    gen_server:call(SrvPid, {chunk, requests}).


%% @doc
%% @end
-spec assigned(non_neg_integer(), non_neg_integer(),
               non_neg_integer(), pid(), pid()) -> ok.
assigned(Piece, Offset, Length, Peerpid, Srvpid) ->
    Srvpid ! {chunk, {assigned, Piece, Offset, Length, Peerpid}},
    ok.


%% @doc
%% @end
-spec assigned([{non_neg_integer(), non_neg_integer(),
                 non_neg_integer()}], pid(), pid()) -> ok.
assigned(Chunks, Peerpid, Srvpid) ->
    [assigned(P, O, L, Peerpid, Srvpid) || {P, O, L} <- Chunks],
    ok.


%% @doc
%% @end
-spec dropped(non_neg_integer(), non_neg_integer(),
              non_neg_integer(), pid(), pid()) -> ok.
dropped(Piece, Offset, Length, Peerpid, Srvpid) ->
    Srvpid ! {chunk, {dropped, Piece, Offset, Length, Peerpid}},
    ok.


%% @doc
%% @end
-spec dropped([{non_neg_integer(), non_neg_integer(),
                non_neg_integer()}], pid(), pid()) -> ok.
dropped(Chunks, Peerpid, Srvpid) ->
    [dropped(P, O, L, Peerpid, Srvpid) || {P, O, L} <- Chunks],
    ok.


%% @doc
%% @end
-spec dropped(pid(), pid()) -> ok.
dropped(Peerpid, Srvpid) ->
    Srvpid ! {chunk, {dropped, Peerpid}},
    ok.



%% @doc The chunk was recieved, but it is not written yet (not stored).
%% It is used in the endgame mode.
%% @end
-spec fetched(non_neg_integer(), non_neg_integer(),
                   non_neg_integer(), pid(), pid()) -> ok.
fetched(Piece, Offset, Length, Peerpid, Srvpid) ->
    Srvpid ! {chunk, {fetched, Piece, Offset, Length, Peerpid}},
    ok.


%% @doc
%% @end
-spec stored(non_neg_integer(), non_neg_integer(),
             non_neg_integer(), pid(), pid()) -> ok.
stored(Piece, Offset, Length, Peerpid, Srvpid) ->
    Srvpid ! {chunk, {stored, Piece, Offset, Length, Peerpid}},
    ok.

%% @doc Send the contents of a chunk to a process.
%% @end
-spec contents(non_neg_integer(), non_neg_integer(),
               non_neg_integer(), binary(), pid()) -> ok.
contents(Piece, Offset, Length, Data, PeerPid) ->
    PeerPid ! {chunk, {contents, Piece, Offset, Length, Data}},
    ok.


%% @doc
%% @end
-spec forward(pid()) -> ok.
forward(Pid) ->
    Tailref = self() ! make_ref(),
    forward_(Pid, Tailref).

forward_(Pid, Tailref) ->
    receive
        Tailref -> ok;
        {chunk, _}=Msg ->
            Pid ! Msg,
            forward_(Pid, Tailref)
    end.


%% @doc
%% @end
-spec format_by_peer(pid()) -> ok.
format_by_peer(SrvPid) ->
    ByPeer = fun({_Pid, _Chunk}=E) -> E end,
    Groups = etorrent_utils:group(ByPeer, requests(SrvPid)),
    io:format("~w~n", [Groups]).


%% @doc
%% @end
-spec format_by_chunk(pid()) -> ok.
format_by_chunk(SrvPid) ->
    ByChunk = fun({Pid, Chunk}) -> {Chunk, Pid} end,
    Groups = etorrent_utils:group(ByChunk, requests(SrvPid)),
    io:format("~w~n", [Groups]).


