%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%% @doc Supervise a pool of torrents.
%% @end
-module(etorrent_torrent_pool).
-behaviour(supervisor).

%% API
-export([start_link/0,
         start_child/4,
         terminate_child/1,
         start_magnet_child/5]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

-type bcode() :: etorrent_types:bcode().

%% ====================================================================
-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() -> supervisor:start_link({local, ?SERVER}, ?MODULE, []).

% @doc Add a new torrent file to the system
% <p>The torrent file is given by its bcode representation, file name
% and info hash. Our PeerId is also given, as well as
% the Id we wish to use for that torrent.</p>
% @end
-spec start_child({bcode(), string(), binary()}, binary(), integer(), list()) ->
    {ok, pid()} | {ok, pid(), term()} | {error, term()}.
start_child({Torrent, TorrentFile, BinIH}, Local_PeerId, Id, Options)
    when is_binary(BinIH) ->
    ChildSpec = {BinIH,
		 {etorrent_torrent_sup, start_link,
		 [{Torrent, TorrentFile, BinIH}, Local_PeerId, Id, Options]},
		 transient, infinity, supervisor, [etorrent_torrent_sup]},
    supervisor:start_child(?SERVER, ChildSpec).


start_magnet_child(BinIH, LocalPeerId, TorrentId, UrlTiers, Options) 
    when is_binary(BinIH) ->
    ChildSpec = {BinIH,
		 {etorrent_magnet_sup, start_link,
		 [BinIH, LocalPeerId, TorrentId, UrlTiers, Options]},
		 transient, infinity, supervisor, [etorrent_magnet_sup]},
    supervisor:start_child(?SERVER, ChildSpec).


% @doc Ask to stop the torrent represented by its info_hash.
% @end
-spec terminate_child(binary()) -> ok.
terminate_child(BinIH) 
    when is_binary(BinIH) ->
    ok = supervisor:terminate_child(?SERVER, BinIH),
    ok = supervisor:delete_child(?SERVER, BinIH).

%% ====================================================================

%% @private
init([]) ->
    {ok,{{one_for_one, 5, 3600}, []}}.
