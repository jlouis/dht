-module(etorrent_mdns_sup).
-behaviour(supervisor).
-export([start_link/1]).

% supervisor callbacks
-export([init/1]).

%% ------------------------------------------------------------------

start_link(MyPeerId) ->
    SupName = {local, etorrent_mdns_sup},
    supervisor:start_link(SupName, ?MODULE, [MyPeerId]).

%% ------------------------------------------------------------------

init([MyPeerId]) ->
    {ok, {{one_for_all, 1, 60}, [
        {mdns_state_srv,
            {etorrent_mdns_state, start_link, [MyPeerId]},
            permanent, 2000, worker, dynamic}]}}.
