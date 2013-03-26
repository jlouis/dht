-module(etorrent_dht_sup).
-behaviour(supervisor).
-export([start_link/0]).

% supervisor callbacks
-export([init/1]).

%% ------------------------------------------------------------------

start_link() ->
    DHTPort = etorrent_config:dht_port(),
    StateFile = etorrent_config:dht_state_file(),
    BootstapNodes = etorrent_config:dht_bootstrap_nodes(),
    start_link(DHTPort, StateFile, BootstapNodes).

start_link(DHTPort, StateFile, BootstapNodes) ->
    SupName = {local, etorrent_dht_sup},
    SupArgs = [{port, DHTPort},
               {file, StateFile},
               {bootstap_nodes, BootstapNodes}],
    supervisor:start_link(SupName, ?MODULE, SupArgs).

%% ------------------------------------------------------------------

init(Args) ->
    Port = proplists:get_value(port, Args),
    File = proplists:get_value(file, Args),
    BootstapNodes = proplists:get_value(bootstap_nodes, Args),
    etorrent_dht_tracker:create_common_resources(),
    {ok, {{one_for_all, 1, 60}, [
        {dht_state_srv,
            {etorrent_dht_state, start_link, [File, BootstapNodes]},
            permanent, 2000, worker, dynamic},
        {dht_socket_srv,
            {etorrent_dht_net, start_link, [Port]},
            permanent, 1000, worker, dynamic}]}}.
