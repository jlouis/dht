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

start_link_features(_S, _, _) -> [{dht_track, start_link}].

%% STORING A NEW ENTRY
%% -----------------------------------------

store(ID, Location) ->
    dht_track:store(ID, Location),
    dht_track:sync().
    
store_pre(S) -> initialized(S).
store_args(_S) ->
    [dht_eqc:id(), dht_eqc:port()].

store_callouts(_S, [ID, Location]) ->
    ?APPLY(refresh, [ID, Location]),
    ?APPLY(add_entry, [ID, Location]),
    ?RET(ok).

store_features(#state { entries = Es }, [ID, _Location], _) ->
    case lists:keymember(ID, 1, Es) of
        true -> [{dht_track, store, overwrite}];
        false -> [{dht_track, store, new}]
    end.

%% DELETING AN ENTRY
%% ----------------------------------------------
delete(ID) ->
    dht_track:delete(ID),
    dht_track:sync().

delete_pre(S) -> initialized(S).
delete_args(S) -> [id(S)].

delete_callouts(_S, [ID]) ->
    ?APPLY(del_entry, [ID]),
    ?RET(ok).

delete_features(#state { entries = Es }, [ID], _) ->
    case lists:keymember(ID, 1, Es) of
        true -> [{dht_track, delete, existing}];
        false -> [{dht_track, delete, non_existing}]
    end.

%% LOOKUP
%% --------------------
lookup(ID) ->
    dht_track:lookup(ID).
    
lookup_pre(S) -> initialized(S).
lookup_args(S) -> [id(S)].

lookup_return(#state {entries = Es }, [ID]) ->
    case lists:keyfind(ID, 1, Es) of
        false -> not_found;
        {_, V} -> V
    end.

lookup_features(_, _, not_found) -> [{dht_track, lookup, not_found}];
lookup_features(_, _, Port) when is_integer(Port) -> [{dht_track, lookup, ok}].
    
%% TIMING OUT
%% ------------------------------
timeout(Msg) ->
    dht_track ! Msg,
    dht_track:sync().

timeout_pre(#state { entries = Es } = S) -> initialized(S) andalso Es /= [].

timeout_args(#state { entries = Es }) ->
    ?LET({ID, Loc}, elements(Es),
        [{refresh, ID, Loc}]).

timeout_pre(#state { entries = Es }, [{refresh, ID, Loc}]) ->
    lists:member({ID, Loc}, Es).

timeout_callouts(_S, [{refresh, ID, Loc}]) ->
    ?APPLY(dht_time, trigger_msg, [{refresh, ID, Loc}]),
    ?APPLY(refresh, [ID, Loc]),
    ?RET(ok).

timeout_features(_S, [_], _) -> [{dht_track, timeout, entry}].

%% REFRESHING AN ENTRY (Internal Call)
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

%% ADD/DELETE AN ENTRY
%% -------------------------------------
add_entry_next(#state { entries = Es } = S, _, [ID, Location]) ->
    S#state { entries = lists:keystore(ID, 1, Es, {ID, Location}) }.

del_entry_next(#state { entries = Es } = S, _, [ID]) ->
    S#state { entries = lists:keydelete(ID, 1, Es) }.

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

%% Generate an ID, with strong preference for IDs which exist.
id(#state { entries = Es }) ->
    IDs = [ID || {ID, _} <- Es],
    frequency(
      [{1, dht_eqc:id()}] ++ [{5, elements(IDs)} || IDs /= [] ] ).

dht_search_find_value_ret() ->
    ?LET(Stores, list({dht_eqc:peer(), dht_eqc:token()}),
        #{ store => Stores }).
        
order(ID, L) ->
    lists:sort(fun({{IDx, _, _}, _}, {{IDy, _, _}, _}) -> dht_metric:d(ID, IDx) < dht_metric:d(ID, IDy) end, L).

take(0, _) -> [];
take(_, []) -> [];
take(K, [X | Xs]) -> [X | take(K-1, Xs)].
