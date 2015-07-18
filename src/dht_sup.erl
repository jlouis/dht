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
    
    Store = #{ id => store,
               start => {dht_store, start_link, []} },
    State = #{ id => state,
               start => {dht_state, start_link, [StateFile, BootstrapNodes]} },
    Network = #{ id => network,
                 start => {dht_net, start_link, [Port]} },
    Tracker = #{ id => tracker,
                 start => {dht_track, start_link, []} },
    {ok,
     #{ strategy => rest_for_one,
        intensity => 5,
        period => 900 },
     [Store, State, Network, Tracker]}.

%% ------------------------------------------------------------------
