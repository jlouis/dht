%%% @doc Store a subset of the DHT at this node
%%
%% This module keeps track of our subset of the DHT node in the system.
%%
%%% @end
%%% @private
-module(dht_store).
-behaviour(gen_server).
-include("dht_constants.hrl").
 -include_lib("stdlib/include/ms_transform.hrl").
 
%% lifetime API
-export([start_link/0, sync/0]).

%% Operational API
-export([store/2, find/1]).

-export([info/0]).

%% gen_server API
-export([
         init/1,
         handle_cast/2,
         handle_call/3,
         terminate/2,
         code_change/3,
         handle_info/2
]).

-define(TBL, ?MODULE).

-record(state, { tbl }).

%% API
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

sync() ->
    gen_server:call(?MODULE, sync).

store(ID, {IP, Port}) ->
    gen_server:call(?MODULE, {store, ID, {IP, Port}}).
    
find(ID) ->
    gen_server:call(?MODULE, {find, ID}).

info() ->
    L = ets:tab2list(?TBL),
    [#{ id => ID, peer => Peer, inserted => Ins } || {ID, Peer, Ins} <- L].

%% Callbacks
init([]) ->
    Tbl = ets:new(?TBL, [named_table, protected, bag]),
    dht_time:send_after(5 * 60 * 1000, ?MODULE, evict),
    {ok, #state { tbl = Tbl }}.

handle_call({store, ID, Loc}, _From, State) ->
    push(ID, Loc),
    {reply, ok, State};
handle_call({find, Key}, _From, State) ->
    evict(Key),
    Peers = ets:match(?TBL, {Key, '$1', '_'}),
    {reply, [Loc || [Loc] <- Peers], State};
handle_call(sync, _From, State) ->
    {reply, ok, State};
handle_call(_Msg, _From, State) ->
    {reply, {error, unknown_msg}, State}.
	
handle_cast(_Msg, State) ->
    {noreply, State}.
    
handle_info(evict, State) ->
    dht_time:send_after(5 * 60 * 1000, ?MODULE, evict),
    evict(),
    {noreply, State};
handle_info(_Msg, State) ->
    {noreply, State}.
    
terminate(_How, _State) ->
    ok.
    
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

evict() ->
    Now = dht_time:monotonic_time(),
    Window = Now - dht_time:convert_time_unit(?STORE_TIME, milli_seconds, native),
    MS = ets:fun2ms(fun({_, _, T}) -> T < Window end),
    ets:select_delete(?TBL, MS).

evict(Key) ->
    Now = dht_time:monotonic_time(),
    Window = Now - dht_time:convert_time_unit(?STORE_TIME, milli_seconds, native),
    MS = ets:fun2ms(fun({K, _, T}) -> K == Key andalso T < Window end), 
    ets:select_delete(?TBL, MS).

push(ID, Loc) ->
    Now = dht_time:monotonic_time(),
    %%
    %% Only match expected output. We crash if we break the invariant by any means
    %%
    case ets:match_object(?TBL, {ID, Loc, '_'}) of
        [] ->
            ets:insert(?TBL, {ID, Loc, Now}),
            ok;
        [E] ->
            ets:delete_object(?TBL, E),
            ets:insert(?TBL, {ID, Loc, Now}),
            ok
    end.

            
        
