-module(etorrent_upnp_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(SUPERVISOR, ?MODULE).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
    supervisor:start_link({local, ?SUPERVISOR}, ?MODULE, []).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================
%%
%%

init([]) ->
    % upnp config
    Maps = [{tcp, etorrent_config:listen_port()},
            {udp, etorrent_config:udp_port()},
            {udp, etorrent_config:dht_port()}],

    UPNPSpecs = [{maps, Maps}],
    UPNPHandler = upnp:child_spec(etorrent_upnp, UPNPSpecs),
    % main upnp supervisor
    UPNPSup = {upnp_sup,
                {upnp_sup, start_link, []},
                permanent, infinity, supervisor, [upnp_sup]},
    {ok, { {one_for_one, 10, 10}, [UPNPSup, UPNPHandler]} }.
