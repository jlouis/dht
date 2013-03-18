%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%% @doc Supervise a pool of peers.
%% <p>This module is a simple supervisor of Peers</p>
%% @end
-module(etorrent_magnet_peer_pool).
-behaviour(supervisor).

%% API
-export([start_link/1]).

%% Supervisor callbacks
-export([init/1]).

%% ====================================================================

%% @doc Start the pool supervisor
%% @end
-spec start_link(integer()) -> {ok, pid()} | ignore | {error, term()}.
start_link(Id) -> supervisor:start_link(?MODULE, [Id]).

%% @doc Add a peer to the supervisor pool.
%% see etorrent_peer_pool:start_child/7
%% @end

%% ====================================================================

%% @private
init([Id]) ->
    gproc:add_local_name({torrent, Id, peer_pool_sup}),
    ChildSpec = {child,
                 {etorrent_magnet_peer_sup, start_link, []},
                 temporary, infinity, supervisor, [etorrent_magnet_peer_sup]},
    {ok, {{simple_one_for_one, 50, 3600}, [ChildSpec]}}.
