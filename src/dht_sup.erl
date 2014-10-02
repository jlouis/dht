%%% @doc Main supervisor for the DHT code
%%% @end
-module(dht_sup).
-behaviour(supervisor).
-export([start_link/0]).

% supervisor callbacks
-export([init/1]).

%% ------------------------------------------------------------------

start_link() ->
    supervisor:start_link({local, dht_sup}, ?MODULE, []).

%% ------------------------------------------------------------------
init([]) ->
    {ok, Port} = application:get_env(dht, port),
    {ok, StateFile} = application:get_env(dht, state_file),
    {ok, BootstrapNodes} = application:get_env(dht, bootstrap_nodes),

    {ok, {{one_for_rest, 5, 900}, [
        {state,
            {dht_state, start_link, [StateFile, BootstrapNodes]},
            permanent, 3000, worker, dynamic},
        {network,
            {dht_net, start_link, [Port]},
            permanent, 1000, worker, dynamic}]}}.
%% ------------------------------------------------------------------
