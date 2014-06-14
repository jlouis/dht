-module(dht_sup).
-behaviour(supervisor).
-export([start_link/0]).

% supervisor callbacks
-export([init/1]).

%% ------------------------------------------------------------------

start_link() ->
    DHTPort = read_config(port),
    StateFile = read_config(state_file),
    BootstrapNodes = read_config(bootstrap_nodes),
    
    start_link(DHTPort, StateFile, BootstrapNodes).

start_link(DHTPort, StateFile, BootstapNodes) ->
    SupName = {local, dht_sup},
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
            {dht_bt_state, start_link, [File, BootstapNodes]},
            permanent, 2000, worker, dynamic},
        {dht_socket_srv,
            {dht_bt_net, start_link, [Port]},
            permanent, 1000, worker, dynamic}]}}.
%% ------------------------------------------------------------------

%% read_config/1 is a way to obtain stuff from the environment which can't fail
read_config(Option) ->
    {ok, Val} = application:get_env(dht_bt, Option),
    Val.
