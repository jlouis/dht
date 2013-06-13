%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%% @doc Supervise a torrent file.
%% <p>This supervisor controls a single torrent download. It sits at
%% the top of the supervisor tree for a torrent.</p>
%% @end
-module(etorrent_torrent_sup).
-behaviour(supervisor).

%% API
-export([start_link/4,

         start_child_tracker/5,
         start_progress/6,
         start_endgame/2,
         start_peer_sup/2,
         start_io_sup/3,
         start_pending/2,
         start_scarcity/3,
         stop_assignor/1,
         stop_networking/1,
         pause/1]).

%% Supervisor callbacks
-export([init/1]).

-type bcode() :: etorrent_types:bcode().


%% =======================================================================

%% @doc Start up the supervisor
%% @end
-spec start_link({bcode(), string(), binary()}, binary(), integer(), list()) ->
                {ok, pid()} | ignore | {error, term()}.
start_link({Torrent, TorrentFile, TorrentIH}, Local_PeerId, Id, Options) ->
    supervisor:start_link(?MODULE, [{Torrent, TorrentFile, TorrentIH},
                                    Local_PeerId, Id, Options]).

%% @doc start a child process of a tracker type.
%% <p>We do this after-the-fact as we like to make sure how complete the torrent
%% is before telling the tracker we are serving it. In fact, we can't accurately
%% report the "left" part to the tracker if it is not the case.</p>
%% @end
-spec start_child_tracker(pid(), binary(), binary(), integer(), list()) ->
                {ok, pid()} | {ok, pid(), term()} | {error, term()}.
start_child_tracker(Pid, <<IntIH:160>> = BinIH,
                    Local_Peer_Id, TorrentId, Options) ->
    lager:debug("start_child_tracker(Pid=~p, TorrentId=~p)", [Pid, TorrentId]),
    %% BEP 27 Private Torrent spec does not say this explicitly, but
    %% Azureus wiki does mention a bittorrent client that conforms to
    %% BEP 27 should behave like a classic one, i.e. no PEX or DHT.
    %% So only enable DHT support for non-private torrent here.
    IsPrivate = etorrent_torrent:is_private(TorrentId),
    DhtEnabled = etorrent_config:dht(),
    [start_child_dht_tracker(Pid, IntIH, TorrentId)
     || not IsPrivate, DhtEnabled],
    [start_child_azdht_tracker(Pid, BinIH, TorrentId)
     || not IsPrivate, DhtEnabled],
    Tracker = {tracker_communication,
               {etorrent_tracker_communication, start_link,
                [BinIH, Local_Peer_Id, TorrentId, Options]},
               transient, 15000, worker, [etorrent_tracker_communication]},
    case etorrent_tracker:is_trackerless(TorrentId) of
        true -> {error, trackerless};
        false -> supervisor:start_child(Pid, Tracker)
    end.

-spec start_progress(pid(), etorrent_types:torrent_id(),
                            etorrent_types:bcode(),
                            etorrent_pieceset:t(),
                            [etorrent_pieceset:t()],
                            etorrent_pieceset:t()) ->
                            {ok, pid()} | {ok, pid(), term()} | {error, term()}.
start_progress(Pid, TorrentID, Torrent, ValidPieces, Wishes, UnwantedPieces) ->
    Spec = progress_spec(TorrentID, Torrent, ValidPieces, Wishes, UnwantedPieces),
    supervisor:start_child(Pid, Spec).

start_endgame(Pid, TorrentID) ->
    Spec = endgame_spec(TorrentID),
    supervisor:start_child(Pid, Spec).

%% @doc Start it before running trackers.
start_peer_sup(Pid, TorrentID) ->
    Spec = peer_pool_spec(TorrentID),
    supervisor:start_child(Pid, Spec).


start_io_sup(Pid, TorrentID, Torrent) ->
    Spec = io_sup_spec(TorrentID, Torrent),
    supervisor:start_child(Pid, Spec).

start_pending(Pid, TorrentID) ->
    Spec = pending_spec(TorrentID),
    supervisor:start_child(Pid, Spec).


start_scarcity(Pid, TorrentID, Torrent) ->
    Spec = scarcity_manager_spec(TorrentID, Torrent),
    supervisor:start_child(Pid, Spec).


stop_networking(Pid) ->
    supervisor:terminate_child(Pid, tracker_communication),
    supervisor:delete_child(Pid, tracker_communication),
    supervisor:terminate_child(Pid, dht_tracker),
    supervisor:delete_child(Pid, dht_tracker),
    supervisor:terminate_child(Pid, azdht_tracker),
    supervisor:delete_child(Pid, azdht_tracker),
    supervisor:terminate_child(Pid, peer_pool_sup),
    supervisor:delete_child(Pid, peer_pool_sup),
    ok.

pause(Pid) ->
    stop_networking(Pid),
    supervisor:terminate_child(Pid, chunk_mgr),
    supervisor:delete_child(Pid, chunk_mgr),
    supervisor:terminate_child(Pid, endgame),
    supervisor:delete_child(Pid, endgame),
    supervisor:terminate_child(Pid, scarcity_mgr),
    supervisor:delete_child(Pid, scarcity_mgr),
    supervisor:terminate_child(Pid, pending),
    supervisor:delete_child(Pid, pending),
    %% io_sup
    supervisor:terminate_child(Pid, fs_pool),
    supervisor:delete_child(Pid, fs_pool),
    ok.


stop_assignor(Pid) ->
    ok = supervisor:terminate_child(Pid, chunk_mgr),
    ok = supervisor:delete_child(Pid, chunk_mgr).


    
%% ====================================================================

%% @private
init([{Torrent, TorrentPath, TorrentIH}, PeerID, TorrentID, Options]) ->
    lager:debug("Init torrent supervisor #~p.", [TorrentID]),
    UrlTiers = etorrent_metainfo:get_url(Torrent),
    etorrent_tracker:register_torrent(TorrentID, UrlTiers, self()),
    Children = [
        info_spec(TorrentID, Torrent),
        torrent_control_spec(TorrentID, Torrent, TorrentPath, TorrentIH, PeerID, Options)],
    {ok, {{one_for_all, 1, 60}, Children}}.

pending_spec(TorrentID) ->
    {pending,
        {etorrent_pending, start_link, [TorrentID]},
        permanent, 5000, worker, [etorrent_pending]}.

scarcity_manager_spec(TorrentID, Torrent) ->
    Numpieces = length(etorrent_io:piece_sizes(Torrent)),
    {scarcity_mgr,
        {etorrent_scarcity, start_link, [TorrentID, Numpieces]},
        permanent, 5000, worker, [etorrent_scarcity]}.

progress_spec(TorrentID, Torrent, ValidPieces, Wishes, UnwantedPieces) ->
    PieceSizes  = etorrent_io:piece_sizes(Torrent), 
    ChunkSize   = etorrent_info:chunk_size(TorrentID),
    Args = [TorrentID, ChunkSize, ValidPieces, PieceSizes, lookup, 
            Wishes, UnwantedPieces],
    {chunk_mgr,
        {etorrent_progress, start_link, Args},
        transient, 20000, worker, [etorrent_progress]}.

endgame_spec(TorrentID) ->
    {endgame,
        {etorrent_endgame, start_link, [TorrentID]},
        temporary, 5000, worker, [etorrent_endgame]}.

torrent_control_spec(TorrentID, Torrent, TorrentFile, TorrentIH, PeerID, Options) ->
    {control,
        {etorrent_torrent_ctl, start_link,
         [TorrentID, {Torrent, TorrentFile, TorrentIH}, PeerID, Options]},
        permanent, 5000, worker, [etorrent_torrent_ctl]}.

io_sup_spec(TorrentID, Torrent) ->
    {fs_pool,
        {etorrent_io_sup, start_link, [TorrentID, Torrent]},
        transient, 5000, supervisor, [etorrent_io_sup]}.

info_spec(TorrentID, Torrent) ->
    {info,
        {etorrent_info, start_link, [TorrentID, Torrent]},
        transient, 5000, worker, [etorrent_info]}.

peer_pool_spec(TorrentID) ->
    {peer_pool_sup,
        {etorrent_peer_pool, start_link, [TorrentID]},
        transient, 5000, supervisor, [etorrent_peer_pool]}.

start_child_dht_tracker(Pid, InfoHash, TorrentID) ->
    Tracker = {dht_tracker,
                {etorrent_dht_tracker, start_link, [InfoHash, TorrentID]},
                permanent, 5000, worker, dynamic},
    supervisor:start_child(Pid, Tracker).

start_child_azdht_tracker(Pid, InfoHash, TorrentID) ->
    Tracker = {azdht_tracker,
                {etorrent_azdht_tracker, start_link, [InfoHash, TorrentID]},
                permanent, 5000, worker, dynamic},
    Res = supervisor:start_child(Pid, Tracker),
    lager:debug("start_child_azdht_tracker returns ~p.", [Res]),
    Res.
