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
    reset().
    
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

%% FINDING A POTENTIAL STORED ENTITY
%% --------------------------------------
find(ID) ->
    dht_store:find(ID).
    
find_pre(S) -> initialized(S).
find_args(S) ->
    StoredIDs = stored_ids(S),
    ID = oneof([elements(StoredIDs) || StoredIDs /= []] ++  [dht_eqc:id()]),
    [ID].

find_callouts(_S, [ID]) ->
    ?MATCH(Now, ?APPLY(dht_time_eqc, monotonic_time, [])),
    ?MATCH(Sz, ?APPLY(dht_time_eqc, convert_time_unit, [45 * 60 * 1000, milli_seconds, native])),
    Flank = Now - Sz,
    ?APPLY(evict, [Flank]),
    ?MATCH(R, ?APPLY(lookup, [ID])),
    ?RET(R).

find_features(_S, [_], L) -> [{dht_store, find, {size, length(L)}}].

%% ADDING ENTRIES TO THE STORE (Internal Call)
add_store_next(#state { entries = Es } = S, _, [ID, Loc, Now]) ->
    S#state { entries = Es ++ [{ID, Loc, Now}] }.

%% EVICTING OLD ENTRIES (Internal Call)
evict_next(#state { entries = Es } = S, _, [Flank]) ->
    S#state { entries = [{ID, Loc, T} || {ID, Loc, T} <- Es, T >= Flank] }.

%% FINDING ENTRIES (Internal Call)
lookup_callouts(#state { entries = Es }, [Target]) ->
    ?RET([Loc || {ID, Loc, _} <- Es, ID == Target]).

%% RESETTING THE STATE
reset() ->
    case whereis(dht_store) of
        undefined ->
            {ok, Pid} = dht_store:start_link(),
            unlink(Pid),
            ok;
        P when is_pid(P) ->
            exit(P, kill),
            timer:sleep(1),
            {ok, Pid} = dht_store:start_link(),
            unlink(Pid),
            ok
    end.

%% Weights
%% -------
%%
%% It is more interesting to manipulate the structure than it is to query it:
weight(_S, store) -> 100;
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

stored_ids(#state { entries = Es }) -> lists:usort([ID || {ID, _, _} <- Es]).
