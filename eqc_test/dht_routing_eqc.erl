-module(dht_routing_eqc).

-compile(export_all).

-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_component.hrl").

-define(DRIVER, dht_routing_tracker).

-record(state, {
	init, % Is the routing system initialized?
	id, % Current ID of this node
	time, % what time is it in the system?
	node_timers = [], % List of the current node timers in the system
	range_timers = [] % List of the current range timers in the system
}).


api_spec() ->
    #api_spec {
      language = erlang,
      modules = [
        #api_module {
          name = dht_time,
          functions = [
            #api_fun { name = monotonic_time, arity = 0 },
            #api_fun { name = convert_time_unit, arity = 3 },
            #api_fun { name = system_time, arity = 0 },
            #api_fun { name = timestamp, arity = 0 },
            #api_fun { name = send_after, arity = 3 }
          ]},
        #api_module {
          name = dht_routing_table,
          functions = [
            #api_fun { name = ranges, arity = 1 },
            #api_fun { name = node_list, arity = 1 },
            #api_fun { name = node_id, arity = 1 },
            #api_fun { name = is_member, arity = 2 },
            #api_fun { name = members, arity = 2 },
            #api_fun { name = insert, arity = 2 },
            #api_fun { name = delete, arity = 2 }
          ]}
       ]}.

%% INITIAL STATE
%% --------------------------------------------------
gen_state() ->
    #state {
      init = false,
      id = dht_eqc:id(),
      time = int(),
      node_timers = [],
      range_timers = []
    }.

%% NEW
%% --------------------------------------------------
new(Tbl) ->
    eqc_lib:bind(?DRIVER, fun(_T) ->
      {ok, ID, Routing} = dht_routing:new(Tbl),
      {ok, ID, Routing}
    end).

new_pre(S) -> not initialized(S).

new_args(_S) ->
  Nodes = list(dht_eqc:peer()),
  Ranges = list(dht_eqc:range()),
  [rt_ref].

new_callouts(#state { id = ID, time = T}, _) ->
    ?CALLOUT(dht_time, monotonic_time, [], T),
    ?CALLOUT(dht_routing_table, node_list, [rt_ref], []),
    ?CALLOUT(dht_routing_table, node_id, [rt_ref], ID),
    ?CALLOUT(dht_routing_table, ranges, [rt_ref], []),
    ?RET(ID).
  
new_next(State, _, _) -> State#state { init = true }.

%% INSERTION
%% --------------------------------------------------
insert(Node) ->
    eqc_lib:bind(?DRIVER,
      fun(T) ->
          {R, S} = dht_routing:insert(Node, T),
          {ok, R, S}
      end).

insert_pre(S) -> initialized(S).

insert_args(_S) ->
    [dht_eqc:peer()].
    
%% @todo: Return non-empty members!
insert_callouts(_S, [Node]) ->
    ?MATCH(Member, ?CALLOUT(dht_routing_table, is_member, [Node, rt_ref], bool())),
    case Member of
        true -> ?RET(already_member);
        false ->
            ?MATCH(Neighbours, ?CALLOUT(dht_routing_table, members, [Node, rt_ref], [])),
            case Neighbours of
               [] ->
                 ?MATCH(R, ?APPLY(adjoin, [Node])),
                 ?RET(R);
               [Old | _] ->
                 ?APPLY(remove, [Old]),
                 ?MATCH(R, ?APPLY(adjoin, [Node])),
                 ?RET(R)
            end
     end.

%% IS_MEMBER
%% --------------------------------------------------
is_member(Node) ->
    eqc_lib:bind(?DRIVER, fun(T) -> {ok, dht_routing:is_member(Node, T), T} end).

is_member_pre(S) -> initialized(S).

is_member_args(_S) ->
    [dht_eqc:peer()].
    
is_member_callouts(_S, [Node]) ->
    ?MATCH(R, ?CALLOUT(dht_routing_table, is_member, [Node, rt_ref], bool())),
    ?RET(R).

%% RANGE_MEMBERS
%% --------------------------------------------------
range_members(Node) ->
    eqc_lib:bind(?DRIVER, fun(T) -> {ok, dht_routing:range_members(Node, T), T} end).

range_members_pre(S) -> initialized(S).

range_members_args(_S) ->
    [dht_eqc:peer()].
    
range_members_callouts(_S, [Node]) ->
    ?MATCH(R, ?CALLOUT(dht_routing_table, members, [Node, rt_ref], [dht_eqc:peer()])),
    ?RET(R).

%% TRY_INSERT
%% --------------------------------------------------
try_insert(Node) ->
    eqc_lib:bind(?DRIVER, fun(T) -> {ok, dht_routing:try_insert(Node, T), T} end).
    
try_insert_pre(S) -> initialized(S).

try_insert_args(_S) ->
    [dht_eqc:peer()].
    
try_insert_callouts(_S, [Node]) ->
    ?CALLOUT(dht_routing_table, insert, [Node, rt_ref], rt_ref),
    ?MATCH(R, ?CALLOUT(dht_routing_table, is_member, [Node, rt_ref], bool())),
    ?RET(R).


%% REMOVAL (Internal call)
%% --------------------------------------------------
remove_callouts(_S, [Node]) ->
    ?CALLOUT(dht_routing_table, delete, [Node, rt_ref], rt_ref),
    ?RET(ok).

%% ADJOIN (Internal call)
%% --------------------------------------------------
adjoin_callouts(#state { time = T }, [Node]) ->
    ?CALLOUT(dht_time, monotonic_time, [], T),
    ?CALLOUT(dht_routing_table, insert, [Node, rt_ref], rt_ref),
    ?MATCH(Member, ?CALLOUT(dht_routing_table, is_member, [Node, rt_ref], bool())),
    case Member of
        false ->
            ?RET(not_inserted);
        true ->
            ?CALLOUT(dht_time, send_after, [T, ?WILDCARD, ?WILDCARD], make_ref()),
            ?CALLOUT(dht_routing_table, ranges, [rt_ref], rt_ref),
            ?CALLOUT(dht_routing_table, ranges, [rt_ref], rt_ref),
            ?RET(ok)
    end.
    
%% ADVANCING TIME
%% --------------------------------------------------
advance_time(_A) -> ok.
advance_time_args(_S) ->
  ?LET(K, nat(),
    [K+1]).

advance_time_next(#state { time = T } = State, _, [A]) -> State#state { time = T+A }.
advance_time_return(_S, [_]) -> ok.

%% PROPERTY
%% --------------------------------------------------
postcondition_common(S, Call, Res) ->
    eq(Res, return_value(S, Call)).

weight(_S, _) -> 100.

prop_routing_correct() ->
    ?SETUP(fun() ->
        eqc_mocking:start_mocking(api_spec()),
        fun() -> ok end
    end,
    ?FORALL(State, gen_state(),
    ?FORALL(Cmds, commands(?MODULE, State),
      begin
        ok = eqc_lib:reset(?DRIVER),
        {H,S,R} = run_commands(?MODULE, Cmds),
        pretty_commands(?MODULE, Cmds, {H,S,R},
          collect(eqc_lib:summary('Length'), length(Cmds),
          aggregate(command_names(Cmds),
            R == ok)))
      end))).

initialized(#state { init = I }) -> I.
