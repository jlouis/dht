%% @doc EQC model for routing+timing
%%
%% This model defines the rules for the DHTs timing state.
%% 
%% The system has call chain dht_state -> dht_routing -> dht_routing_table, where each
%% stage is responsible for a particular thing. This model, for dht_routing, defines the rules
%% for timers.
%%
%% A "routing" construction is a handle to the underlying routing table, together with
%% timing for the nodes in the RT and the ranges in the RT. The purpose of this module
%% is to provide a high-level view of the routing table, where each operation also tracks
%% the timing state as meta-data:
%%
%% Ex. Adding a node to a routing table, introduces a new timing entry for that node, always.
%%
%% To track timing information, without really having a routing table, we mock the table.
%% The table is always named `rt_ref' and all state of the table is tracked in the model state.
%% The `dht_time' module is also mocked, and time is tracked in the model state. This allows
%% us to test the routing/timing code under various assumptions about time and timing.
%%
%% The advantage of the splitting model is that when testing, we can use a much simpler routing
%% table where every entry is known precisely. This means we can avoid having to model the
%% routing table in detail, which is unwieldy for a lot of situations. In turn, this model overspecifies
%% the routing table for the rest of the system, but since the actual routing table is a subset obeying
%% the same commands, this idea works.
%%
%% NODES
%% ======================================================
%%
%% Nodes can be defined to be in one of 3 possible states:
%%
%% • Good—we have succesfully communicated with the node recently
%% • Questionable—we have not communicated with this node recently
%% • Bad—we have tried communication with the node, but communication has systematically timed
%%   out.
%%
%% so to handle a node correctly, we need to understand the differences in state among the nodes.
%%
%% We don't track the Node state with a timer. Rather, we note the last succesful point of
%% communication. This means a simple calculation defines when a node becomes questionable,
%% and thus needs a refresh.
%%
%% The reason we do it this way, is that all refreshes of nodes are event-driven: The node is
%% refreshed whenever an event happens:
%%
%% • We communicate with the node and the communication is sucessful according to the rules.
%% • We need to insert a node close to the node that needs refreshing.
%%
%% RANGES
%% ======================================================
%%
%% Ranges are tracked with a timer. We represent such timers as integers in our model and
%% inject them into the SUT. By mocking timer calls, through dht_time, we are able to handle
%% the callouts correctly. In principle, we don't do anything with these timers in this module,
%% but I'm not sure for how long that assumption is going to hold once we start all over.
%%
%% HOW TIMING WORK IN THE ROUTING SYSTEM
%%
%% The routing system uses a map() to store a mapping
%%
%%     Node => #{ last_activity => LA, timeout_count => N, reachability => true/false }, or
%%     Range => #{ timer => TRef }, where
%%
%% • LA is the point in time when the item Node was last active,
%% • timeout_count is the number of times that node has timed out,
%% • reachability measures if we can reach that node,
%% • timer is a reference to the timer that was set at that point in time.
%%
%% This means that for any point in time τ, we can measure the age(T) = τ-T, and
%% check if the age is larger than, say, ?NODE_TIMEOUT. This defines when a node is
%% questionable. The timeout_count defines a bad node, if it grows too large.
%%
%% Also, the last_activity is defined as the maximum value among its members for
%% last activity. This is far easier to reason about than tracking a separate last_activity
%% value for the range.
%%
%% MODEL IMPLEMENTATION:
%% ======================================================
%%
%% The model uses a simple list to model the routing system.
%%
%% Time
%% ====
%% 
%% The model uses time in milli_seconds rather than the native time resolution
%% used by the real system. This means time conversion is a no-op when converting
%% from native time to milli_seconds in the model.
%%
%%
%% GENERAL RULES FROM BEP 0005:
%% ======================================================
%%
%% Handling the all-important thing which is the DHTs documentation:
%% 
%% Nodes have 3 possible states:
%% 
%% -type node_state() :: good | {questionable, integer()} | bad
%% 
%% Each node maintains a point in time, last_activity, where it was last communicated with.
%% 
%% • If a node replies to one of our queries, last_activity := now();
%% • If a node sends a query and has at some point replied to a query of ours, last_activity := now()
%% 
%% The first rule makes sure that nodes which participate in communication are good.
%% The last rule is used when we know a priori a node is a participant already.
%% 
%% If a node fails to respond to a query 3 times, it is marked as bad and this usually
%% means it will eventually be removed from the routing table.
%% 
%% Nodes with good state are given priority over nodes with questionable state.
%% TODO: Verify the above for queries!
%% 
%% Buckets/ranges:
%% 
%% Buckets and ranges are split in the obvious pattern.
%% 
%% A range can maximally hold K nodes, where K := 8 currently. 
%% 
%% Insertion:
%% 
%% • Inserting a node into a bucket full of good nodes is a discard
%% • If inserting into a bucket with bad nodes present, one bad is replaced by the new node.
%% • If inserting into a bucket with questionable nodes, the oldest questionable node is pinged.
%% 	If the ping succeeds, we try the next most questionable node and so on.
%% 	If the ping fails, twice, then the node is replaced by the new good node
%% 
%% Range refresh:
%% 
%% Ranges has a last_changed property. It is updated on:
%% 
%% • Ping which responds
%% • Node Added
%% • Node Replaced (which is an add, really)
%% 
%% If a range has not been updated for 15 minutes, it should be refreshed:
%% 
%% • Pick random ID in the range.
%% • Run FIND_NODE on the random ID
%% • find_nodes will run insertion, hopefully close the ID you already had
%% 
%% Startup:
%% 
%% • Inserting the first node
%% • Or starting up with a routing table thereafter
%% 
%% Issue a FIND_NODE request on your own ID until you can't find any closer nodes.
%% 

%% TODO—Still missing work in the model:
%%
%% Structural model errors:
%%
%% • We have to precisely model that ranges are non-overlapping and that nodes
%%   falls into ranges correctly. Otherwise, it is not possible to precisely map the
%%   fact that sometimes, you can't add a new node to a range.
%%
%% Other mistakes in the current model:
%%
%% • After we started looking at the BEP 0005 spec, we have realized this module needs
%%    some serious rewriting, as it is currently not doing the right thing.
%% • Mistake #1: Return {questionable, τ} for a point in time τ rather than returning
%%    {questionable, Age} for its age. This means we can sort based on questionability.
%% • How do we assert the return from a range needing refreshing is random? The postcondition
%%   is obvious here, but it requires us to run a function on the data...
-module(dht_routing_meta_eqc).
-compile(export_all).

-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_component.hrl").

%% We define a name for the tracker that keeps the state of the routing system:
-define(K, 8).
-define(DRIVER, dht_routing_tracker).
-define(NODE_TIMEOUT, 15 * 60 * 1000).
-define(RANGE_TIMEOUT, 15 * 60 * 1000).

-type time() :: integer().
-type time_ref() :: integer().

-record(state, {
	%%% MODEL OF ROUTING TABLE
	%%
	tree = [] :: [#{ atom() => any() }],
	%% The tree models ranges and nodes within each range
	
	%%% MODEL OF TIMERS
	%%
	time :: time(),
	timers = [] :: [{time(), time_ref()}],
	tref = 0 :: time_ref(),
	%% The fields time, timers and tref models time. The idea is that `time' is the
	%% monotonic time on the system, timers is an (ordered) list of the current timers
	%% and tref is used to draw unique timer references in the system.

	%%% MODEL OF THE ROUTING SYSTEM
	%%
	init = false :: boolean(),
	%% init encodes if we have initialized the routing table or not.
	id :: any(),
	%% id represents the current ID of the node we are running as
	node_timers = [] :: [{dht:peer(), time(), non_neg_integer(), boolean()}],
	range_timers = [] :: [{dht:range(), time_ref()}]
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
          name = dht_rand,
          functions = [
            #api_fun { name = pic, arity = 1 }
          ]},
        #api_module {
          name = dht_time,
          functions = [
            #api_fun { name = convert_time_unit, arity = 3 },
            #api_fun { name = monotonic_time, arity = 0 },
            #api_fun { name = send_after, arity = 3 },
            #api_fun { name = cancel_timer, arity = 1 }
          ]},
        #api_module {
          name = dht_routing_table,
          functions = [
            #api_fun { name = closest_to, arity = 4 },
            #api_fun { name = delete, arity = 2 },
            #api_fun { name = insert, arity = 2 },
            #api_fun { name = is_member, arity = 2 },
            #api_fun { name = is_range, arity = 2 },
            #api_fun { name = members, arity = 2 },
            #api_fun { name = node_id, arity = 1 },
            #api_fun { name = node_list, arity = 1 },
            #api_fun { name = range, arity = 2 },
            #api_fun { name = ranges, arity = 1 }
          ]}
       ]}.

%% INITIAL STATE
%% --------------------------------------------------

%% Generating an initial state requires us to generate a fake routing table, and then proceed
%% by using that table. We start out by a generator which can make nodes in a given range.
%% We can't generate more than 8 nodes in a range, because this is the assumption in the
%% system.

%% We limit ourselves to a test case where IDs are not general, but limited to the range 0‥255
%% which makes understand the numbers easier.
-define(ID_MIN, 0).
-define(ID_MAX, 255).

peer() -> peer(?ID_MIN, ?ID_MAX).
id() -> choose(?ID_MIN, ?ID_MAX).
range() ->
    ?LET(R, [choose(?ID_MIN, ?ID_MAX), choose(?ID_MIN, ?ID_MAX)],
        lists:sort(R)).

peer(Lo, Hi) -> {choose(Lo, Hi), dht_eqc:ip(), dht_eqc:port()}.

nodes(Lo, Hi) ->
    ?LET(Sz, choose(0, 8),
      ?LET(IDGen, vector(Sz, choose(Lo, Hi)),
        [{ID, dht_eqc:ip(), dht_eqc:port()} || ID <- dedup(IDGen)])).

%% A tree is sized over the current generation size:
routing_tree() ->
    ?SIZED(Sz, routing_tree(Sz, ?ID_MIN, ?ID_MAX)).
    
%% Trees are based on their structure:
%% • Trees of size 0 generates nodes in the current range.
%% • Trees where the Lo–Hi distance is short are like size 0 trees.
%% • Larger trees are either done, or their consist of a split-point in the range
%%    and then they consist of two trees of smaller sizes.
routing_tree(0, Lo, Hi) ->
    [#{ lo => Lo, hi => Hi, nodes => nodes(Lo, Hi) }];
routing_tree(_N, Lo, Hi) when Hi - Lo < 4 -> routing_tree(0, Lo, Hi);
routing_tree(N, Lo, Hi) ->
    frequency([
        {50, routing_tree(0, Lo, Hi)},
        {50, ?LAZY(
            ?LET(Split, choose(Lo+1, Hi-1),
              ?LETSHRINK([L, R], [routing_tree(N div 2, Lo, Split), routing_tree(N div 2, Split+1, Hi)],
                L ++ R)))}
    ]).

gen_state() ->
    #state {
        tree = routing_tree(),
        init = false,
        id = dht_eqc:id(?ID_MIN, ?ID_MAX),
        time = int(),
        node_timers = [],
        range_timers = []
    }.

%% NEW
%% --------------------------------------------------

%% When the system initializes,  the routing table may be loaded from disk. When
%% that happens, we have to re-instate the timers by query of the routing table, and
%% then construct those timers.
new(Tbl) ->
    eqc_lib:bind(?DRIVER, fun(_T) ->
      {ok, ID, Routing} = dht_routing_meta:new(Tbl),
      {ok, ID, Routing}
    end).

%% You can only initialize once, so the system is not allowed to be initialized
%% if it already is.
new_pre(S) -> not initialized(S).

%% The atom `rt_ref` is the dummy-value for the routing table, because we mock it.
new_args(_S) -> [rt_ref].

%% When new is called, the system calls out to the routing_table. We feed the
%% Nodes and Ranges we generated into the system. The assumption is that
%% these Nodes and Ranges are ones which are initialized via the internal calls
%% init_range_timers and init_node_timers.
new_callouts(#state { id = ID, time = T } = S, [rt_ref]) ->
    ?CALLOUT(dht_time, monotonic_time, [], T),
    ?CALLOUT(dht_routing_table, node_list, [rt_ref], current_nodes(S)),
    ?CALLOUT(dht_routing_table, node_id, [rt_ref], ID),
    ?APPLY(init_range_timers, [current_ranges(S)]),
    ?APPLY(init_nodes, [current_nodes(S)]),
    ?RET(ID).
  
%% Track that we initialized the system
new_next(State, _, _) -> State#state { init = true }.

%% INSERT
%% --------------------------------------------------

%% Inserting a node into the routing table has the assumption
%% that the node we want to insert is new. We will never try to
%% insert a node into table, which is already there.
%%
%% Furthermore, the call assumes there is space in the range. If not, then the
%% insert is wrong. The precondition on this call is that the insertion is valid
%% and will succeed.
%%

%% Insertion returns `{R, S}' where `S' is the new state and `R' is the response. We
%% check the response is in accordance with what we think.
insert(Node) ->
    eqc_lib:bind(?DRIVER,
      fun(T) ->
          {R, S} = dht_routing_meta:insert(Node, T),
          {ok, R, S}
      end).

%% You can only insert data when the system has been initialized.
insert_pre(S) -> initialized(S).

%% Any peer is eligible for insertion at any time. There are no limits on how and when
%% you can do this insertion.
insert_args(_S) -> [peer()].

insert_args_pre(S, [Peer]) -> initialized(S) andalso (not has_peer(Peer, S)).

%% We `adjoin' the Node to the routing table, which is addressed as a separate
%% internal model transition.
%%
%% TODO: Go through this, it may be wrong.
insert_callouts(_S, [Node]) ->
    ?MATCH(R, ?APPLY(adjoin, [Node])),
    case R of
        ok -> ?RET(ok);
        Else -> ?FAIL(Else)
    end.

%% IS_MEMBER
%% --------------------------------------------------

%% Ask if a given node is a member of the Routing Table.
is_member(Node) ->
    eqc_lib:bind(?DRIVER, fun(T) -> {ok, dht_routing_meta:is_member(Node, T), T} end).

is_member_pre(S) -> initialized(S).

is_member_args(_S) -> [peer()].
    
%% This is simply a forward to the underlying routing table, so it should return whatever
%% The RT returns.
is_member_callouts(S, [Node]) ->
    ?MATCH(R, ?CALLOUT(dht_routing_table, is_member, [Node, rt_ref],
        lists:member(Node, current_nodes(S)))),
    ?RET(R).

%% NEIGHBORS
%% --------------------------------------------------

%% Neighbours returns the K nodes which are closest to a given node in
%% the routing table. We just verify that the call is correct with respect to
%% the system.
neighbors(ID, K) ->
    eqc_lib:bind(?DRIVER,
      fun(T) ->
          {ok, dht_routing_meta:neighbors(ID, K, T), T}
      end).
      
neighbors_pre(S) -> initialized(S).

neighbors_args(_S) -> [id(), nat()].

%% Neighbors calls out twice currently, because it has two filter functions it runs in succession.
%% First it queries for the known good nodes, and then it queries for the questionable nodes.
%%
%% Note that we don't care if we return the right nodes here. We are only interested in the
%% behavior of this call, and assumes that the routing table underneath is doing the right
%% thing.
neighbors_callouts(S, [ID, K]) ->
    ?MATCH(GoodNodes,
      ?CALLOUT(dht_routing_table, closest_to, [ID, ?WILDCARD, K, rt_ref],
    	  rt_nodes(S))),
    case GoodNodes of
       GoodNodes when length(GoodNodes) == K -> ?RET(GoodNodes);
       GoodNodes ->
         ?MATCH(QuestionableNodes,
           ?CALLOUT(dht_routing_table, closest_to, [ID, ?WILDCARD, K-length(GoodNodes), rt_ref],
             rt_nodes(S))),
         ?RET(GoodNodes ++ QuestionableNodes)
    end.

%% NODE_LIST
%% --------------------------------------------------
%%
%% Node list is a proxy forward to the node_list call of the routing table

node_list() ->
    eqc_lib:bind(?DRIVER, fun(T) -> {ok, dht_routing_meta:node_list(T), T} end).
    
node_list_pre(S) -> initialized(S).
	
node_list_args(_S) -> [].

node_list_callouts(S, []) ->
    ?MATCH(R, ?CALLOUT(dht_routing_table, node_list, [rt_ref], rt_nodes(S))),
    ?RET(R).
    
%% NODE_STATE
%% --------------------------------------------------

node_state(Nodes) ->
    eqc_lib:bind(?DRIVER,
      fun(T) -> {ok, dht_routing_meta:node_state(Nodes, T), T}
    end).
    
node_state_pre(S) -> initialized(S) andalso has_nodes(S).

%% We currently generate output for known nodes only. The obvious
%% thing to do when a node is unknown is to ignore it.
%% TODO: Send in unknown nodes.
node_state_args(S) -> [rt_nodes(S)].

node_state_pre(S, [Nodes]) ->
    Current = current_nodes(S),
    lists:all(fun(N) -> lists:member(N, Current) end, Nodes).
    
%% We simply expect this call to carry out queries on each given node in the member list.
%% And we expect the return to be computed in the same order as the query itself.
node_state_callouts(#state { time = T, node_timers = NTs } = S, [Nodes]) ->
    ?SEQ([?CALLOUT(dht_routing_table, is_member, [N, rt_ref],
    		lists:member(N, current_nodes(S)))
        || N <- Nodes]),
    ?RET([ node_state_value(T, lists:keyfind(N, 1, NTs)) || N <- Nodes]).

%% NODE_TIMEOUT
%% --------------------------------------------------

%% The node_timeout/2 call is invoked whenever a node doesn't respond within the allotted
%% time. The policy is, that the nodes ends up with a bad state once it has increased its timer
%% enough times.
node_timeout(Node) ->
    eqc_lib:bind(?DRIVER,
      fun(T) ->
        {ok, ok, dht_routing_meta:node_timeout(Node, T)}
      end).
      
node_timeout_pre(S) -> initialized(S) andalso has_nodes(S).

node_timeout_args(S) -> [rt_node(S)].

node_timeout_callouts(_S, [_Node]) ->
    ?RET(ok).

node_timeout_next(#state { node_timers = NT } = S, _, [Node]) ->
    {Node, LA, Count, Reachable} = lists:keyfind(Node, 1, NT),
    S#state { node_timers = lists:keyreplace(Node, 1, NT, {Node, LA, Count+1, Reachable}) }.

%% RANGE_MEMBERS
%% --------------------------------------------------

%% Returns the members of given node range.
%%
range_members(Node) ->
    eqc_lib:bind(?DRIVER, fun(T) -> {ok, dht_routing_meta:range_members(Node, T), T} end).

range_members_pre(S) -> initialized(S).

range_members_args(_S) -> [peer()].
    
%% This is simply a forward to the underlying routing table, so it should return whatever
%% The RT returns.
range_members_callouts(S, [{ID, _, _} = Node]) ->
    ?MATCH(R, ?CALLOUT(dht_routing_table, members, [Node, rt_ref], nodes_in_range(S, ID))),
    ?RET(R).

%% REFRESH_NODE
%% --------------------------------------------------

%% Refreshing a node means that the node had activity. In turn, its timer
%% structure should be refreshed when this happens. The transition is that
%% we remove the old timer and install a new timer at a future point in time.
refresh_node(Node, Opts) ->
    eqc_lib:bind(?DRIVER,
        fun(T) ->
            R = dht_routing_meta:refresh_node(Node, Opts, T),
            {ok, ok, R}
        end).
        
refresh_node_pre(S) -> initialized(S) andalso has_nodes(S).

refresh_node_args(S) -> [rt_node(S), #{ reachable => bool() }].

refresh_node_callouts(#state { time = T }, [_Node, _Opts]) ->
    ?CALLOUT(dht_time, monotonic_time, [], T),
    ?RET(ok).

%% Refreshing a node depends on its current reachability and if the new refresh is for a
%% reply, in which case the node is reachable. If the node is not reachable, this is a no-op.
%% and if the node is reachable, the backend structure is updated.
refresh_node_next(#state { node_timers = NTs, time = T } = S, _, [Node, #{ reachable := R2}]) ->
    {_, _, _, R1} = lists:keyfind(Node, 1, NTs),
    case R1 or R2 of
        false -> S;
        true -> S#state { node_timers = lists:keyreplace(Node, 1, NTs, {Node, T, 0, true}) }
    end.

%% RANGE_STATE
%% --------------------------------------------------

range_state(Range) ->
    eqc_lib:bind(?DRIVER,
      fun(T) ->
          {ok, dht_routing_meta:range_state(Range, T), T}
      end).
      
range_state_pre(S) -> initialized(S).

range_state_args(S) ->
    Range = frequency([
        {10, rt_range(S)},
        {1, range()}
    ]),
    [Range].

range_state_callouts(#state{ time = T } = S, [Range]) ->
    ?MATCH(IsRange, ?CALLOUT(dht_routing_table, is_range, [Range, rt_ref],
        lists:member(Range, current_ranges(S)))),
    case IsRange of
        false -> ?RET({error, not_member});
        true ->
            ?MATCH(Members, ?APPLY(range_members, [Range])),
            ?CALLOUT(dht_time, monotonic_time, [], T),
            case last_active(S, Members) of
               {error, Reason} -> ?FAIL({error, Reason});
               [] -> ?RET(empty);
               [{_M, TS, _, _} | _] ->
                   ?CALLOUT(dht_time, convert_time_unit, [T - TS, native, milli_seconds], T - TS),
                   case (T - TS) =< ?RANGE_TIMEOUT of
                     true -> ?RET(ok);
                     false ->
                       IDs = [ID || {ID, _, _} <- Members],
                       ?MATCH(PickedID, ?CALLOUT(dht_rand, pick, [IDs], rand_pick(IDs))),
                       ?RET({needs_refresh, PickedID})
                   end
            end
    end.
                   
%% RESET_RANGE_TIMER
%% --------------------------------------------------

%% Resetting the range timer is done whenever the timer has triggered. So there is
%% a rule which says this can only happen once the timer has triggered.
%%
%% NOTE: this is an assumed precondition.
reset_range_timer(Range, Opts) ->
    eqc_lib:bind(?DRIVER,
        fun(T) ->
          R = dht_routing_meta:reset_range_timer(Range, Opts, T),
          {ok, ok, R}
        end).

reset_range_timer_pre(S) -> initialized(S) andalso has_ranges(S).

reset_range_timer_args(S) ->
    [rt_range(S), #{ force => bool() }].

reset_range_timer_callouts(#state { time = T }, [Range, #{ force := true }]) ->
    ?CALLOUT(dht_time, monotonic_time, [], T),
    ?APPLY(remove_range_timer, [Range]),
    ?APPLY(add_range_timer_at, [Range, T]),
    ?RET(ok);
reset_range_timer_callouts(_S, [Range, #{ force := false }]) ->
    ?MATCH(A, ?APPLY(range_last_activity, [Range])),
    ?APPLY(remove_range_timer, [Range]),
    ?APPLY(add_range_timer_at, [Range, A]),
    ?RET(ok).

%% RANGE_LAST_ACTIVITY (Internal call)
%% ---------------------------------------------------------
%% This call is used internally to figure out when there was last activity
%% on the range.
%% TODO: Assert that the range timer is already gone here, otherwise the call is
%% not allowed.
range_last_activity_callouts(#state { time = T } = S, [Range]) ->
    ?MATCH(Members,
        ?CALLOUT(dht_routing_table, members, [Range, rt_ref], rt_nodes(S))),
    case last_active(S, Members) of
        undefined ->
          ?MATCH(R, ?CALLOUT(dht_time, monotonic_time, [], T)),
          ?RET(R);
        Min ->
          ?RET(Min)
    end.

%% INIT_RANGE_TIMERS (Internal call)
%% --------------------------------------------------

%% Initialization of range timers follows the same general structure:
%% we successively add a new range timer to the state.
init_range_timers_callouts(#state { time = T } = S, [Ranges]) ->
    ?CALLOUT(dht_routing_table, ranges, [rt_ref], current_ranges(S)),
    ?SEQ([?APPLY(add_range_timer_at, [R, T]) || R <- Ranges]).
      
%% INIT_NODE_TIMERS (Internal call)
%% --------------------------------------------------

%% Node timer initialization is equivalent to insertion of the nodes
%% one by one.
%%
%% TODO: Hmm, but they are already members before doing this, so they
%% will all say they are members! This means something is wrong, because
%% if they are already, this will be a no-op, and no timer will be added. Figure
%% out what is wrong here and fix it.
init_nodes_callouts(_, [_Nodes]) ->
    ?CALLOUT(dht_time, convert_time_unit, [?NODE_TIMEOUT, milli_seconds, native],
          ?NODE_TIMEOUT).

%% We start out by making every node questionable, so the system will catch up to
%% the game imediately.
init_nodes_next(#state { time = T } = S, _, [Nodes]) ->
    NodeTimers = [{N, T-?NODE_TIMEOUT, 0, false} || N <- lists:reverse(Nodes)],
    S#state { node_timers = NodeTimers }.

%% REMOVAL (Internal call)
%% --------------------------------------------------

%% Removing a node amounts to killing the node from the routing table
%% and also remove its timer structure.
%% TODO: Assert only bad nodes are removed because this is the rule of the system!
remove_callouts(_S, [Node]) ->
    ?CALLOUT(dht_routing_table, delete, [Node, rt_ref], rt_ref),
    ?RET(ok).

remove_next(#state { tree = Tree } = State, _, [Node]) ->
    State#state { tree = delete_node(Node, Tree) }.

%% REPLACE (Internal call)
%% --------------------------------------------------

%% Replacing a node with another node amounts to deleting one node, then adjoining in
%% the other node.
%% TODO: Assert the node we are replacing is currently questionable!
replace_callouts(_S, [OldNode, NewNode]) ->
    ?APPLY(remove, [OldNode]),
    ?APPLY(adjoin, [NewNode]).

%% ADJOIN (Internal call)
%% --------------------------------------------------

%% TODO: Go through this call for correctness
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
            ?APPLY(insert_node, [Node, T]),
            ?RET(ok)
    end.
    
%% TODO: Split too large ranges!
insert_node_callouts(S, [Node, T]) ->
    { #{ nodes := Nodes }, _Rs} = take_range(S, Node),
    case length(Nodes) of
        L when L >= ?K -> ?FAIL(range_too_large);
        _ ->  ?APPLY(add_node_timer, [Node, T])
    end.
    
insert_node_next(S, _, [Node, _T]) ->
    { #{ nodes := Nodes } = R, Rs} = take_range(S, Node),
    NR = R#{ nodes := Nodes ++ [Node] },
    S#state{ tree = Rs ++ [NR] }.

take_range(#state { tree = Tree}, {ID, _, _}) -> take_range(Tree, ID, []).

take_range([R = #{ lo := Lo, hi := Hi} | Rs], ID, Acc) when Lo =< ID, ID =< Hi ->
    {R, rev_append(Acc, Rs)};
take_range([R | Rs], ID, Acc) -> take_range(Rs, ID, [R | Acc]).

rev_append([], Ls) -> Ls;
rev_append([S|Ss], Ls) -> rev_append(Ss, [S|Ls]).

%% ADVANCING TIME (Internal call)
%% --------------------------------------------------

%% Time is part of the model state, and is represented as milli_seconds,
%% because I think this is enough resolution to hit the fun corner cases.
%%
%% The call is a model-internal call, so there is just a simple dummy function
%% which is called whenever time is advanced.
advance_time(_A) -> ok.

%% Advancing time is forced to be positive, so it always increases the current
%% Time interval. 
advance_time_args(_S) ->
    T = oneof([
        ?LET(K, nat(), K+1),
        ?LET({K, N}, {nat(), nat()}, (N+1)*1000 + K),
        ?LET({K, N, M}, {nat(), nat(), nat()}, (M+1)*60*1000 + N*1000 + K)
    ]),
    [T].

%% Advancing time transitions the system into a state where the time is incremented
%% by A.
advance_time_next(#state { time = T } = State, _, [A]) -> State#state { time = T+A }.
advance_time_return(_S, [_]) -> ok.

%% ADDING/REMOVING Timers (model book-keeping)
%% --------------------------------------------------

%% Adding a range is an operation we can describe as a callout sequence as
%% well as a state transition. The callouts are calls to the timing structure, first
%% to compute the timer delay, and then to insert the timer into the Erlang Runtime
%%
%% There are two ways to add range timers. One way adds a range timer based on
%% monotonic time, and what "now" is. The other solution adds a range timer "at"
%% A given point in time.
%%
%% TODO: The time unit returned here is incorrect!
%% TODO: The concept of adding a timer at a given time T, e.g., Tref@T, is not fleshed
%%   out yet. It is necessary to do correctly to handle the model.

add_range_timer_at_callouts(#state { tref = C, time = T }, [_Range, At]) ->
    ?CALLOUT(dht_time, monotonic_time, [], T),
    Point = T - At,
    ?CALLOUT(dht_time, convert_time_unit, [Point, native, milli_seconds], Point),
    ?CALLOUT(dht_time, send_after, [monus(?RANGE_TIMEOUT, Point), ?WILDCARD, ?WILDCARD], C).
    
%% Adding a range timer transitions the system by keeping track of the timer state
%% and the fact that a range timer was added.
add_range_timer_at_next(#state { timers = TS, tref = C, range_timers = RT } = State, _, [Range, At]) ->
    State#state {
        tref = C+1,
        range_timers = RT ++ [{Range, At, C}],
        timers = orddict:store(At+?RANGE_TIMEOUT, C, TS)
    }.

remove_range_timer_callouts(#state { range_timers = RT } = S, [Range]) ->
    {Range, _, TRef} = lists:keyfind(Range, 1, RT),
    ?CALLOUT(dht_time, cancel_timer, [TRef], timer_state(S, TRef)).
    
remove_range_timer_next(#state { range_timers = RT, timers = Timers } = State, _, [Range]) ->
    {Range, _, TRef} = lists:keyfind(Range, 1, RT),
    State#state {
        range_timers = lists:keydelete(TRef, 3, RT),
        timers = lists:keydelete(TRef, 2, Timers)
    }.

timer_state(#state { time = T, timers = Timers }, TRef) ->
    case lists:keyfind(TRef, 2, Timers) of
        false -> false;
        {P, TRef} -> monus(P, T)
    end.

%% When updating node timers, we have the option of overriding the last activity point
%% of that node. The last activity point is passed as an extra parameter in this call.
%%
%% A node starts out with no errors and as being unreachable
add_node_timer_next(#state { node_timers = NT } = State, _, [Node, Activity]) ->
    State#state {
        node_timers = NT ++ [{Node, Activity, 0, false}]
    }.
    
%% Removing a node/range timer from the model state is akin to deleting that state
%% from the list of node timers.
%%
remove_node_timer_next(#state { node_timers = NT } = State, _, [Node]) ->
    State#state { node_timers = lists:keydelete(Node, 1, NT) }.
    
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

%% TRACING
%% ------------------
trace(on) ->
    dbg:tracer(),
    dbg:p(all, c),
    dbg:tpl(dht_routing, '_', '_', cx),
    ok;
trace(off) ->
    dbg:stop(),
    ok.

%% INTERNAL FUNCTIONS FOR MODEL MANIPULATION
%% --------------------------------------------------

initialized(#state { init = I }) -> I.


%% Tree manipulation
%% --------------------------------

%% Helper, returns an assertion on node presence in the model which
%% can be grafted onto a callout specification.
assert_nodes_in_model(State, Nodes) ->
    CurrentNodes = current_nodes(State),
    case [N || N <- Nodes, not lists:member(N, CurrentNodes)] of
        [] -> ?EMPTY;
        FailedNodes ->
            ?FAIL({not_member, FailedNodes})
    end.
    
%% Returns current ranges in the tree
current_ranges(#state { tree = Tree }) ->
    [{Lo, Hi} || #{ lo := Lo, hi := Hi } <- Tree].

%% Returns current nodes in the tree
current_nodes(#state { tree = Tree }) ->
    lists:append([Nodes || #{ nodes := Nodes } <- Tree]).

%% Generators for various routing table specimens
rt_node(S) -> elements(current_nodes(S)).
rt_range(S) -> elements(current_ranges(S)).

rt_nodes(S) ->
    case current_nodes(S) of
        [] -> [];
        Ns -> list(elements(Ns))
    end.

%% Simple precondition checks
has_nodes(S) -> current_nodes(S) /= [].
has_ranges(S) -> current_ranges(S) /= [].

%% TODO: Lessen this restriction so peers may have the same ID, but different IP-addresses,
%% or different IP-addresses, but the same ID.
has_peer({ID, _, _}, S) ->
    Nodes = current_nodes(S),
    lists:keymember(ID, 1, Nodes).

delete_node(_Node, []) -> [];
delete_node({ID, _, _} = Node, [#{ lo := Lo, hi := Hi, nodes := Nodes } = R | Rs]) when Lo =< ID, ID =< Hi ->
    NewNodes = Nodes -- [Node],
    [R#{ nodes := NewNodes } | Rs];
delete_node(Node, [R | Rs]) ->
    [R | delete_node(Node, Rs)].

nodes_in_range(#state { tree = Tree }, ID) ->
    %% This MUST return exactly one target, or the Tree is broken
    [Ns] = [Nodes || #{ lo := Lo, hi := Hi, nodes := Nodes } <- Tree, Lo =< ID, ID =< Hi],
    Ns.

%% Timer manipulation
%% -----------------------------

last_active(_S, []) -> [];
last_active(#state { node_timers = NTs }, Members) ->
    Eligible = [lists:keyfind(M, 1, NTs) || M <- Members],
    case [E || E <- Eligible, E == false] of
        [] ->
            lists:reverse(lists:keysort(2, Eligible));
        [_|_] -> {error, not_member}
    end.

%% Return the current nodes with timers
nodes_with_timers(#state { node_timers = NTs }) ->
    [N || {N, _, _, _} <- NTs].

%% Given a time T and a node state tuple, compute the expected node state value
%% for that tuple.
node_state_value(_T, false) -> not_member;
node_state_value(_T, {_, _, Errs, _}) when Errs > 1 -> bad;
node_state_value(T, {_, Tau, _, _}) when T - Tau < ?NODE_TIMEOUT -> good;
node_state_value(_, {_, Tau, _, _}) -> {questionable, Tau}.

%% Various helpers
%% --------------------

monus(A, B) when A > B -> A - B;
monus(A, B) when A =< B -> 0.

rand_pick([]) -> [];
rand_pick(Elems) -> elements(Elems).

dedup(Xs) ->
    dedup(Xs, #{}).
    
dedup([], _) -> [];
dedup([X | Xs], M) ->
    case maps:get(X, M, false) of
        true -> dedup(Xs, M);
        false -> [X | dedup(Xs, M#{ X => true })]
    end.
