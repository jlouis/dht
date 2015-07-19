-module(dht_store_eqc).

-compile(export_all).

-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_component.hrl").

-include("dht_eqc.hrl").

api_spec() ->
    #api_spec {
      language = erlang,
      modules = [] }.

-record(state, {
    entries = [],
    init = false
}).
    
initial_state() -> #state{}.

%% START A NEW DHT STORE
%% -----------------------------------
start_link() ->
    dht_store:start_link(),
    ok.
    
start_link_pre(S) -> not initialized(S).

start_link_args(_S) -> [].

start_link_return(_S, []) -> ok.

start_link_next(S, _, []) -> S#state { init = true }.

start_link_features(_S, _, _) -> [{dht_store, start_link}].

%% STORING AN ENTRY
%% ------------------------------
store(ID, Loc) ->
    dht_store:store(ID, Loc).
    
store_pre(S) -> initialized(S).

store_args(_S) ->
    [dht_eqc:id(), {dht_eqc:ip(), dht_eqc:port()}].

store_callouts(_S, [ID, Loc]) ->
    ?MATCH(Now, ?APPLY(dht_time_eqc, monotonic_time, [])),
    ?APPLY(add_store, [ID, Loc, Now]),
    ?RET(ok).

store_features(_S, _, _) ->
    [{dht_store, store}].

%% ADDING ENTRIES TO THE STORE
add_store_next(#state { entries = Es } = S, _, [ID, Loc, Now]) ->
    S#state { entries = Es ++ [{ID, Loc, Now}] }.

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
