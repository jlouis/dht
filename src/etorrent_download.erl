-module(etorrent_download).


%% exported functions
-export([await_servers/1,
         request_chunks/3,
         chunk_dropped/4,
         chunks_dropped/2,
         chunk_fetched/4,
         chunk_stored/4]).

%% update functions
-export([switch_mode/3,
         update/2]).

-type torrent_id()  :: etorrent_types:torrent_id().
-type pieceset()    :: etorrent_pieceset:t().
-type piece_index()  :: etorrent_types:piece_index().
-type chunk_offset() :: etorrent_types:chunk_offset().
-type chunk_length() :: etorrent_types:chunk_len().
-type chunkspec()   :: {piece_index(), chunk_offset(), chunk_length()}.
-type update_query() :: {progress, pid()}.
-type mode_name() :: atom().


-record(tservices, {
    torrent_id :: torrent_id(),
    mode       :: mode_name(),
    progress   :: pid(),
    endgame    :: pid() | undefined,
    pending    :: pid(),
    histogram  :: pid()}).
-opaque tservices() :: #tservices{}.
-export_type([tservices/0]).

-define(endgame(Handle), (Handle#tservices.mode =:= endgame)).


%% @doc
%% @end
-spec await_servers(torrent_id()) -> tservices().
await_servers(TorrentID) ->
    Mode      = etorrent_torrent:get_mode(TorrentID),
    Pending   = etorrent_pending:await_server(TorrentID),
    Progress  = etorrent_progress:await_server(TorrentID),
    Histogram = etorrent_scarcity:await_server(TorrentID),
    Endgame   = case Mode of
                    endgame -> etorrent_endgame:await_server(TorrentID);
                    _       -> undefined
                end,
    ok = etorrent_pending:register(Pending),
    Handle = #tservices{
        mode=Mode,
        torrent_id=TorrentID,
        pending=Pending,
        progress=Progress,
        histogram=Histogram,
        endgame=Endgame},
    Handle.


%% @doc Run `update/2' for the peer with Pid.
%%      It allows to change the Hangle tuple.
%% @end
-spec switch_mode(torrent_id(), mode_name(), mode_name()) -> ok.
%%switch_mode(TorrentID, OldMode, NewMode) ->
switch_mode(TorrentID, progress, endgame) ->
    Peers = etorrent_peer_control:lookup_peers(TorrentID),
    EndGamePid = etorrent_endgame:await_server(TorrentID),
    [PeerPid ! {download, {set_endgame, EndGamePid}}
     || PeerPid <- Peers],
    ok.


%% @doc This function is called by peer.
%% @end
-spec update(update_query(), tservices()) -> tservices().
update({set_endgame, Endgame}, Handle) ->
    Handle#tservices{endgame=Endgame, mode=endgame}.

%% @doc
%% @end
-spec request_chunks(non_neg_integer(), pieceset(), tservices()) ->
    {ok, assigned | not_interested | [chunkspec()]}.
request_chunks(Numchunks, Peerset, Handle) when ?endgame(Handle) ->
    #tservices{endgame=Endgame} = Handle,
    lager:debug("request_chunks"),
    etorrent_chunkstate:request(Numchunks, Peerset, Endgame);

request_chunks(Numchunks, Peerset, Handle) ->
    #tservices{progress=Progress} = Handle,
    etorrent_chunkstate:request(Numchunks, Peerset, Progress).


%% @doc
%% @end
-spec chunk_dropped(piece_index(), chunk_offset(), chunk_length(), tservices()) -> ok.
chunk_dropped(Piece, Offset, Length, Handle) when ?endgame(Handle) ->
    #tservices{pending=Pending, endgame=Endgame} = Handle,
    ok = etorrent_chunkstate:dropped(Piece, Offset, Length, self(), Endgame),
    ok = etorrent_chunkstate:dropped(Piece, Offset, Length, self(), Pending);

chunk_dropped(Piece, Offset, Length, Handle) ->
    #tservices{pending=Pending, progress=Progress} = Handle,
    ok = etorrent_chunkstate:dropped(Piece, Offset, Length, self(), Progress),
    ok = etorrent_chunkstate:dropped(Piece, Offset, Length, self(), Pending).


%% @doc
%% @end
-spec chunks_dropped([chunkspec()], tservices()) -> ok.
chunks_dropped(Chunks, Handle) when ?endgame(Handle) ->
    #tservices{pending=Pending, endgame=Endgame} = Handle,
    ok = etorrent_chunkstate:dropped(Chunks, self(), Endgame),
    ok = etorrent_chunkstate:dropped(Chunks, self(), Pending);

chunks_dropped(Chunks, Handle) ->
    #tservices{pending=Pending, progress=Progress} = Handle,
    ok = etorrent_chunkstate:dropped(Chunks, self(), Progress),
    ok = etorrent_chunkstate:dropped(Chunks, self(), Pending).


%% @doc
%% @end
-spec chunk_fetched(piece_index(), chunk_offset(), chunk_length(), tservices()) -> ok.
chunk_fetched(Piece, Offset, Length, Handle) when ?endgame(Handle) ->
    #tservices{endgame=Endgame} = Handle,
    ok = etorrent_chunkstate:fetched(Piece, Offset, Length, self(), Endgame);

chunk_fetched(_, _, _, _) ->
    ok.


%% @doc
%% @end
-spec chunk_stored(piece_index(), chunk_offset(), chunk_length(), tservices()) -> ok.
chunk_stored(Piece, Offset, Length, Handle) ->
    #tservices{pending=Pending, progress=Progress, endgame=Endgame} = Handle,
    [ok = etorrent_chunkstate:stored(Piece, Offset, Length, self(), Endgame)
     || ?endgame(Handle)],
    ok = etorrent_chunkstate:stored(Piece, Offset, Length, self(), Progress),
    ok = etorrent_chunkstate:stored(Piece, Offset, Length, self(), Pending).

