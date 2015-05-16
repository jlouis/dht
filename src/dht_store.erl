-module(dht_store).
-behaviour(gen_server).

%% lifetime API
-export([start_link/0]).

%% Operational API
-export([store/2, find/1]).

%% gen_server API
-export([init/1, handle_cast/2, handle_call/3, terminate/2, code_change/3, handle_info/2]).

-define(TBL, ?MODULE).

-record(state, { tbl }).

%% API
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

store(ID, {IP, Port}) ->
    gen_server:call(?MODULE, {store, ID, {IP, Port}}).
    
find(ID) ->
    gen_server:call(?MODULE, {find, ID}).

%% Callbacks
init([]) ->
    Tbl = ets:new(?TBL, [named_table, protected, bag]),
    {ok, #state { tbl = Tbl }}.
	
handle_call({store, ID, Peer}, _From, State) ->
    Now = dht_time:system_time(),
    ets:insert(?TBL, {ID, Peer, Now}),
    {reply, ok, State};
handle_call({find, Key}, _From, State) ->
    Peers = ets:match(?TBL, {Key, '$1', '_'}),
    {reply, [ID || [ID] <- Peers], State};
handle_call(_Msg, _From, State) ->
    {reply, {error, unknown_msg}, State}.
	
handle_cast(_Msg, State) ->
    {noreply, State}.
    
handle_info(_Msg, State) ->
    {noreply, State}.
    
terminate(_How, _State) ->
    ok.
    
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
