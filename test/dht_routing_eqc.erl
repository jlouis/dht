%% @doc EQC model for routing+timing
%%
%% This model defines the rules for the DHTs timing state.
%% 
%% The system has call chain dht_state → dht_routing → dht_routing_table, where each
%% stage is responsible for a particular thing. This model, for dht_routing, defines the rules
%% for timers.
%%
%% A "routing" construction is a handle to the underlying routing table, together with
%% timers for the nodes in the RT and the ranges in the RT. The purpose of this module
%% is to provide a high-level view of the routing table, where each operation also tracks
%% the timing state:
%%
%% Ex. Adding a node to a routing table, introduces a new timer for that node, always.
%%
%% To track timing information, without really having a routing table, we mock the table.
%% The table is always named `rt_ref' and all state of the table is tracked in the model state.
%% The `dht_time' module is also mocked, and time is tracked in the model state. This allows
%% us to test the routing/timing code under various assumptions about time and timing.
%%
%% One might think that there is a simply relationship between a node in the RT and having a
%% timer for that node, but this is not true. If a timer triggers, we will generally ping that node
%% to check if it is still up. But this is temporal and the result of that ping comes later. So you
%% might have nodes in the RT which has no current timer. Also, dead nodes lingers in the RT
%% until we find better nodes for that range. Because nodes come and go in the DHT in general,
%% so remember where there were a node back in the day will help tremendously.
%%
-module(dht_routing_eqc).
-compile(export_all).

-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_component.hrl").

%% We define a name for the tracker that keeps the state of the routing system:
-define(DRIVER, dht_routing_tracker).

-type time() :: integer().
-type time_ref() :: integer().

-record(state, {
	init = false :: boolean(),
	%% init encodes if we have initialized the routing table or not.
	id :: any(),
	%% id represents the current ID of the node we are running as
	time :: time(),
	timers = [] :: [{time(), time_ref()}],
	tref = 0 :: time_ref(),
	%% The fields time, timers and tref models time. The idea is that `time' is the
	%% monotonic time on the system, timers is an (ordered) list of the current timers
	%% and tref is used to draw unique timer references in the system.
	node_timers = [] :: [{time_ref(), any()}],
	range_timers = [] :: [{time_ref(), any()}]
	%% The node_timers and range_timers represent the state of the routing table
	%% we can do this, due to the invariant that every time the routing table has an
	%% entry X, then there is a timer construction for X.
}).

%% MOCK SPECIFICATION
%% --------------------------------------------------
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

%% Initialization is an important state in the system. When the system initializes, 
%% the routing table may be loaded from disk. When that happens, we have to
%% re-instate the timers by query of the routing table, and then construct those
%% timers.
new(Tbl, _Nodes, _Ranges) ->
    eqc_lib:bind(?DRIVER, fun(_T) ->
      {ok, ID, Routing} = dht_routing:new(Tbl),
      {ok, ID, Routing}
    end).

%% You can only initialize once, so the system is not allowed to be initialized
%% if it already is.
new_pre(S) -> not initialized(S).

%% We construct a lists of Nodes we percieve is "in the table" and likewise with
%% a list of ranges. These are dummy arguments which are used by the callout
%% system to initialize correctly.
new_args(_S) ->
  Nodes = list(dht_eqc:peer()),
  Ranges = list(dht_eqc:range()),
  [rt_ref, Nodes, Ranges].

%% When new is called, the system calls out to the routing_table. We feed the
%% Nodes and Ranges we generated into the system. The assumption is that
%% these Nodes and Ranges are ones which are initialized via the internal calls
%% init_range_timers and init_node_timers.
new_callouts(#state { id = ID, time = T}, [_, Nodes, Ranges]) ->
    ?CALLOUT(dht_time, monotonic_time, [], T),
    ?CALLOUT(dht_routing_table, node_list, [rt_ref], Nodes),
    ?CALLOUT(dht_routing_table, node_id, [rt_ref], ID),
    ?CALLOUT(dht_routing_table, ranges, [rt_ref], Ranges),
    ?APPLY(init_range_timers, [Ranges]),
    ?APPLY(init_node_timers, [Nodes]),
    ?RET(ID).
  
%% Track that we initialized the system
new_next(State, _, _) -> State#state { init = true }.

%% INIT_RANGE_TIMERS (Internal call)
%% --------------------------------------------------

%% Initialization of range timers follows the same general structure:
%% we successively add a new range timer to the state.
init_range_timers_callouts(#state { }, [Ranges]) ->
    ?SEQ([?APPLY(add_range_timer, [R]) || R <- Ranges]).
      
%% INIT_NODE_TIMERS (Internal call)
%% --------------------------------------------------

%% Node timer initialization is equivalent to insertion of the nodes
%% one by one.
%%
%% TODO: Hmm, but they are already members before doing this, so they
%% will all say they are members! This means something is wrong, because
%% if they are already, this will be a no-op, and no timer will be added. Figure
%% out what is wrong here and fix it.
init_node_timers_callouts(_, [Nodes]) ->
    ?SEQ([?APPLY(insert, [N]) || N <- Nodes]).

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
            ?MATCH(Neighbours, ?CALLOUT(dht_routing_table, members, [Node, rt_ref], list(dht_eqc:peer()))),
            ?MATCH(Inactive, ?APPLY(inactive, [Neighbours])),
            case Inactive of
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

%% Ask if a given node is a member of the Routing Table.
is_member(Node) ->
    eqc_lib:bind(?DRIVER, fun(T) -> {ok, dht_routing:is_member(Node, T), T} end).

is_member_pre(S) -> initialized(S).

is_member_args(_S) -> [dht_eqc:peer()].
    
%% This is simply a forward to the underlying routing table, so it should return whatever
%% The RT returns.
is_member_callouts(_S, [Node]) ->
    ?MATCH(R, ?CALLOUT(dht_routing_table, is_member, [Node, rt_ref], bool())),
    ?RET(R).

%% RANGE_MEMBERS
%% --------------------------------------------------

%% Returns the members of given node range.
%%
range_members(Node) ->
    eqc_lib:bind(?DRIVER, fun(T) -> {ok, dht_routing:range_members(Node, T), T} end).

range_members_pre(S) -> initialized(S).

range_members_args(_S) -> [dht_eqc:peer()].
    
%% This is simply a forward to the underlying routing table, so it should return whatever
%% The RT returns.
range_members_callouts(_S, [Node]) ->
    ?MATCH(R, ?CALLOUT(dht_routing_table, members, [Node, rt_ref], [dht_eqc:peer()])),
    ?RET(R).

%% CAN_INSERT
%% --------------------------------------------------

%% We can query the routing table and ask it if we can insert a given node.
%% This is done by inserting the node and then asking for membership, but
%% not persisting the state of doing so. Hence, there is no state transition
%% possible when doing this.
can_insert(Node) ->
    eqc_lib:bind(?DRIVER, fun(T) -> {ok, dht_routing:can_insert(Node, T), T} end).
    
can_insert_pre(S) -> initialized(S).

can_insert_args(_S) ->
    [dht_eqc:peer()].
    
%% The result of doing a `can_insert' is the result of the membership test on the
%% underlying routing table. So the expected return is whatever the routing table
%% returns back to us.
can_insert_callouts(_S, [Node]) ->
    ?CALLOUT(dht_routing_table, insert, [Node, rt_ref], rt_ref),
    ?MATCH(R, ?CALLOUT(dht_routing_table, is_member, [Node, rt_ref], bool())),
    ?RET(R).

%% INACTIVE
%% --------------------------------------------------

%% Inactive is a filter. It returns those nodes in a list which are currently
%% Inactive nodes. That is, they have timed out. This can happen because
%% Nodes come and go, and we failed to refresh the given node when we
%% should. Rather than just deleting the node from the RT, we let it linger.
%%
%% But the filter function here, finds the inactive nodes.
inactive(Nodes) ->
    eqc_lib:bind(?DRIVER,
      fun(T) ->
        {ok, dht_routing:inactive(Nodes, nodes, T), T}
      end).
      
inactive_pre(S) -> initialized(S).

%% TODO: This assumption is quite weak because we only ever ask for nodes
%% which has been added to the RT at some point.
inactive_args(_S) -> [list(dht_eqc:peer())].

%% The call checks the time for each node it is given
inactive_callouts(_S, [Nodes]) ->
  ?SEQ([ ?APPLY(time_check, [N]) || N <- Nodes]).

%% Calling inactive with a set of nodes Ns, will return those nodes which are
%%
%% * Present
%% * Has a Timeout Point *before* the current time
%%
%% These nodes are the ones which are "timed out" in the sense of the notion
%% used here.
inactive_return(#state { time = T } = State, [Nodes]) ->
    F = fun(N) ->
        case find_timeout(State, N) of
            not_found -> false;
            {ok, P} -> P =< T
        end
    end,
    lists:filter(F, Nodes).

%% time_check is an internal call for checking time for a given timeout
time_check_callouts(#state { time = T } = State, [Node]) ->
    case find_timeout(State, Node) of
        not_found -> ?RET(not_found);
        {ok, P} ->
            Timestamp = P - T,
            ?CALLOUT(dht_time, monotonic_time, [], T),
            ?CALLOUT(dht_time, convert_time_unit, [Timestamp, native, milliseconds], Timestamp)
    end.
    
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

%% Time is part of the model state, and is represented as milli_seconds,
%% because I think this is enough resolution to hit the fun corner cases.
%%
%% The call is a model-internal call, so there is just a simple dummy function
%% which is called whenever time is advanced.
advance_time(_A) -> ok.

%% Advancing time is forced to be positive, so it always increases the current
%% Time interval. 
advance_time_args(_S) -> ?LET(K, nat(), [K+1]).

%% Advancing time transitions the system into a state where the time is incremented
%% by A.
advance_time_next(#state { time = T } = State, _, [A]) -> State#state { time = T+A }.
advance_time_return(_S, [_]) -> ok.

%% ADDING/REMOVING Range timers (model book-keeping)
%% --------------------------------------------------

%% Adding a range is an operation we can describe as a callout sequence as
%% well as a state transition. The callouts are calls to the timing structure, first
%% to compute the timer delay, and then to insert the timer into the Erlang Runtime
add_range_timer_callouts(#state { tref = C, time = T }, [_Range]) ->
    ?CALLOUT(dht_time, monotonic_time, [], T),
    ?CALLOUT(dht_time, convert_time_unit, [?WILDCARD, native, milli_seconds], T),
    ?CALLOUT(dht_time, send_after, [?WILDCARD, ?WILDCARD, ?WILDCARD], C).

%% Adding a range timer transitions the system by keeping track of the timer state
%% and the fact that a range timer was added.
add_range_timer_next(
	#state { time = T, timers = TS, tref = C, range_timers = RT } = State, _, [Range]) ->
    State#state {
        tref = C+1,
        range_timers = RT ++ [{C, Range}],
        timers = orddict:store(T, C, TS)
    }.

%% PROPERTY
%% --------------------------------------------------

%% Use a common postcondition for all commands, so we can utilize the valid return
%% of each command.
postcondition_common(S, Call, Res) ->
    eq(Res, return_value(S, Call)).

%% Adjust weights of commands.
weight(_S, _) -> 100.

%% Main property, just verify that the commands are in sync with reality.
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

%% Given a state and a node, find the timeout point of that node, if any
find_timeout(#state { node_timers = NT, timers = TS }, Node) ->
    case lists:keyfind(Node, 2, NT) of
        false -> not_found;
        {TRef, Node} ->
            {P, TRef} = lists:keyfind(TRef, 2, TS),
            {ok, P}
    end.

