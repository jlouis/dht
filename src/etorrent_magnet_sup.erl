%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%% @doc Supervise a torrent file.
%% <p>This supervisor controls a single torrent download. It sits at
%% the top of the supervisor tree for a torrent.</p>
%% @end
-module(etorrent_magnet_sup).
-behaviour(supervisor).

%% API
-export([start_link/5]).

%% Supervisor callbacks
-export([init/1]).


%% =======================================================================

%% @doc Start up the supervisor
%% @end
-spec start_link(binary(), binary(), integer(), [[string()]], list()) ->
                {ok, pid()} | ignore | {error, term()}.
start_link(TorrentIH, LocalPeerID, TorrentID, UrlTiers, Options)
        when is_binary(TorrentIH), is_binary(LocalPeerID), is_integer(TorrentID) ->
    supervisor:start_link(?MODULE, [TorrentIH, LocalPeerID, TorrentID, UrlTiers, Options]).

    
%% ====================================================================

%% @private
init([TorrentIH, LocalPeerID, TorrentID, UrlTiers, Options]) ->
    lager:debug("Init torrent magnet supervisor #~p.", [TorrentID]),
    etorrent_dht:add_torrent(TorrentIH, TorrentID),
    Control =
        {control,
            {etorrent_magnet_ctl, start_link,
             [TorrentIH, LocalPeerID, TorrentID, UrlTiers, Options]},
            permanent, 5000, worker, [etorrent_magnet_ctl]},
    PeerPool =
        {peer_pool_sup,
            {etorrent_magnet_peer_pool, start_link, [TorrentID]},
            transient, 5000, supervisor, [etorrent_magnet_peer_pool]},
    Tracker =
    {tracker_communication,
     {etorrent_tracker_communication, start_link,
      [self(), UrlTiers, TorrentIH, LocalPeerID, TorrentID]},
     transient, 15000, worker, [etorrent_tracker_communication]},
    {ok, {{one_for_all, 1, 60}, [Control, PeerPool, Tracker]}}.

