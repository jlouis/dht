-module(dht_sup).
-behaviour(supervisor).
-export([start_link/0]).

% supervisor callbacks
-export([init/1]).

-define(TAB, tracker_tab).

%% ------------------------------------------------------------------

start_link() ->
    {ok, Port} = application:get_env(dht, port),
    {ok, StateFile} = application:get_env(dht, state_file),
    {ok, BootstrapNodes} = application:get_env(dht, bootstrap_nodes),
    
    supervisor:start_link({local, dht_sup}, ?MODULE, #{ port => Port, file => StateFile, bootstrap => BootstrapNodes} ).

%% ------------------------------------------------------------------

init(#{ port := Port, file := StateFile, bootstrap := BootstrapNodes}) ->
    ets:new(?TAB, [named_table, public, bag]),
    {ok, {{one_for_all, 1, 60}, [
        {dht_state_srv,
            {dht_state, start_link, [StateFile, BootstrapNodes]},
            permanent, 2000, worker, dynamic},
        {dht_socket_srv,
            {dht_net, start_link, [Port]},
            permanent, 1000, worker, dynamic}]}}.
%% ------------------------------------------------------------------
