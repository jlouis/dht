-module(dht_track_eqc).

-compile(export_all).

-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_component.hrl").

-include("dht_eqc.hrl").

api_spec() ->
    #api_spec {
       language = erlang,
       modules = [
        #api_module {
          name = dht_search,
          functions = [
            #api_fun { name = run, arity = 2, classify = dht_search_eqc } ]},
        #api_module {
          name = dht_net,
          functions = [
            #api_fun { name = store, arity = 4, classify = dht_net_eqc } ]}
    ] }.

-record(state, {
          entries = [],
          init = false
         }).
    
initial_state() -> #state{}.

-define(STORE_COUNT, 8).

%% RESETTING THE STATE
%% ------------------------------------

reset() ->
    case whereis(dht_track) of
        undefined ->
            {ok, Pid} = dht_track:start_link(),
            unlink(Pid),
            ok;
        P when is_pid(P) ->
            exit(P, kill),
            timer:sleep(1),
            {ok, Pid} = dht_track:start_link(),
            unlink(Pid),
            ok
    end.

%% START A NEW DHT TRACKER
%% -----------------------------------
start_link() ->
    reset().
    
start_link_pre(S) -> not initialized(S).

start_link_args(_S) -> [].

start_link_callouts(_S, []) ->
    ?RET(ok).

start_link_next(S, _, []) -> S#state { init = true }.

start_link_features(_S, _, _) -> [{dht_store, start_link}].

store(ID, Location) ->
    dht_track:store(ID, Location),
    dht_track:sync().
    
store_pre(S) -> initialized(S).
store_args(_S) ->
    [dht_eqc:id(), dht_eqc:port()].

store_callouts(_S, [ID, Location]) ->
    ?APPLY(refresh, [ID, Location]),
    ?RET(ok).

%% REFRESHING AN ENTRY
%% ------------------------------------------
refresh_callouts(_S, [ID, Location]) ->
    ?MATCH(Res, ?CALLOUT(dht_search, run, [find_value, ID], dht_search_find_value_ret())),
    #{ store := Stores } = Res,
    Candidates = order(ID, Stores),
    StorePoints = take(?STORE_COUNT, Candidates),
    ?APPLY(net_store, [ID, Location, StorePoints]),
    ?APPLY(dht_time_eqc, send_after, [45 * 60 * 1000, dht_track, {refresh, ID, Location}]),
    ?RET(ok).
    
net_store_callouts(_S, [_ID, _Location, []]) -> ?RET(ok);
net_store_callouts(_S, [ID, Location, [{{_, IP, Port}, Token} | SPs]]) ->
    ?CALLOUT(dht_net, store, [{IP, Port}, Token, ID, Location], ok),
    ?APPLY(net_store, [ID, Location, SPs]).

    
%% Weights
%% -------
%%
%% It is more interesting to manipulate the structure than it is to query it:
weight(_S, _Cmd) -> 10.

%% Properties
%% ----------

%% Use a common postcondition for all commands, so we can utilize the valid return
%% of each command.
postcondition_common(S, Call, Res) ->
    eq(Res, return_value(S, Call)).

%% INTERNALS
%% ------------------------
initialized(#state { init = Init }) -> Init.

dht_search_find_value_ret() ->
    ?LET(Stores, list({dht_eqc:peer(), dht_eqc:token()}),
        #{ store => Stores }).
        
order(ID, L) ->
    lists:sort(fun({{IDx, _, _}, _}, {{IDy, _, _}, _}) -> dht_metric:d(ID, IDx) < dht_metric:d(ID, IDy) end, L).

take(0, _) -> [];
take(_, []) -> [];
take(K, [X | Xs]) -> [X | take(K-1, Xs)].
