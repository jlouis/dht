%% @doc EQC model for routing+timing
%%
%% This model defines the rules for the DHTs timing state.
%% 
%% The system has call chain dht_state → dht_routing → dht_routing_table, where each
%% stage is responsible for a particular thing. This model, for dht_routing, defines the rules
%% for timers.
%%
%% A "routing" construction is a handle to the underlying routing table, together with
%% timing for the nodes in the RT and the ranges in the RT. The purpose of this module
%% is to provide a high-level view of the routing table, where each operation also tracks
%% the timing state:
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
%% One might think that there is a simply relationship between a node in the RT and its state,
%% but this is not true. Nodes can be defined to be in one of 3 possible states:
%%
%% • Good—we have succesfully communicated with the node recently
%% • Questionable—we have not communicated with this node recently
%% • Bad—we have tried communication with the node, but communication has systematically timed
%%   out.
%%
%% so to handle a node correctly, we need to understand the differences in state among the nodes.
%%
%% NODES
%% ======================================================
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
%% HOW TIMERS WORK IN THE ROUTING SYSTEM
%%
%% The routing system uses a map() to store a mapping
%%
%%     Node => #{ last_activity => LA, timeout_count => N, or
%%     Range => #{ timer => TRef }, where
%%
%% LA is the point in time when the item Node was last active,
%% and timeout_count is the number of times that node has timed out,
%% and timer is a reference to the timer that was set at that point in time.
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
%% GENERAL RULES FROM BEP 0005:
%% ======================================================
%%
%% Handling the all–important thing which is the DHTs documentation:
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
%% The first rule makes sure that nodes which participate in communication are good. The last rule is used when we know a priori a node is a participant already.
%% 
%% If a node fails to respond to a query 3 times, it is marked as bad and this usually means it will eventually be removed from the routing table.
%% 
%% Nodes with good state are given priority over nodes with questionable state.
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
%% • Ping which respondds
%% • Node Added
%% • Node Replaced
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
%% • After we started looking at the BEP 0005 spec, we have realized this module needs
%%    some serious rewriting, as it is currently not doing the right thing.
%% • Mistake #1: Return {questionable, τ} for a point in time τ rather than returning
%%    {questionable, Age} for its age. This means we can sort based on questionability.
%% • Mistake #2: Kill the inactive/active calls, but return a Node and it's node_state() instead.
%%    This in turn lets the caller decide what to do with the data and we avoid encoding such
%%    rules in this part of the system. It is far better to return everything and let the caller split
%%    it apart. Many of the calls in this module goes away once this is done.
%% • Mistake #3: Refreshing ranges is a much simpler model. We don't need to maintain an
%%    advanced notion of what range timers are, and when they hit. Rather, we can just run them
%%    on a safe 15 minute schedule.
%% • Mistake #4: This module encodes far too much policy. It should be simpler in notion, so
%%    we avoid having to encode all of these things.
-module(dht_routing_meta_eqc).
-compile(export_all).

-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_component.hrl").

%% We define a name for the tracker that keeps the state of the routing system:
-define(DRIVER, dht_routing_tracker).
-define(NODE_TIMEOUT, 15 * 60 * 1000).
-define(RANGE_TIMEOUT, 15 * 60 * 1000).

-type time() :: integer().
-type time_ref() :: integer().

-record(state, {
	%%% MODEL OF ROUTING TABLE
	%%
	nodes = [] :: [any()],
	ranges = [] :: [any()],
	%% The nodes and ranges models what is currently in the routing table
	
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
	node_timers = [] :: [{dht:peer(), time(), non_neg_integer()}],
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

%% Generating an initial state requires us to generate the Ranges first, and then generate
%% Nodes within the ranges. This allows us to answer consistently for a range.
ranges() ->
  ?LET(Ranges, list(dht_eqc:range()),
    dedup(Ranges)).

dedup_nodes([{N, R} | Rest]) ->
    case lists:keymember(N, 1, Rest) of
        true -> dedup_nodes([{N, R} | lists:keydelete(N, 1, Rest)]);
        false -> [{N, R} | dedup_nodes(Rest)]
    end;
dedup_nodes([]) -> [].

gen_state() ->
  ?LET(Ranges, ranges(),
    ?LET(Nodes, [{list(dht_eqc:peer()), R} || R <- Ranges],
      begin
        NodesList = [{N, R} || {Ns, R} <- Nodes, N <- Ns],
        #state {
          nodes = dedup_nodes(NodesList),
          ranges = Ranges,
          init = false,
          id = dht_eqc:id(),
          time = int(),
          node_timers = [],
          range_timers = []
        }
      end)).

%% NEW
%% --------------------------------------------------

%% Initialization is an important state in the system. When the system initializes, 
%% the routing table may be loaded from disk. When that happens, we have to
%% re-instate the timers by query of the routing table, and then construct those
%% timers.
new(Tbl) ->
    eqc_lib:bind(?DRIVER, fun(_T) ->
      {ok, ID, Routing} = dht_routing_meta:new(Tbl),
      {ok, ID, Routing}
    end).

%% You can only initialize once, so the system is not allowed to be initialized
%% if it already is.
new_pre(S) -> not initialized(S).

new_args(_S) -> [rt_ref].

%% When new is called, the system calls out to the routing_table. We feed the
%% Nodes and Ranges we generated into the system. The assumption is that
%% these Nodes and Ranges are ones which are initialized via the internal calls
%% init_range_timers and init_node_timers.
new_callouts(#state { id = ID, time = T, ranges = Ranges } = S, [rt_ref]) ->
    ?CALLOUT(dht_time, monotonic_time, [], T),
    ?CALLOUT(dht_routing_table, node_list, [rt_ref], current_nodes(S)),
    ?CALLOUT(dht_routing_table, node_id, [rt_ref], ID),
    ?APPLY(init_range_timers, [Ranges]),
    ?APPLY(init_nodes, [current_nodes(S)]),
    ?RET(ID).
  
%% Track that we initialized the system
new_next(State, _, _) -> State#state { init = true }.

%% ACTIVE
%% --------------------------------------------------

active(Nodes) ->
    eqc_lib:bind(?DRIVER,
      fun(T) -> {ok, dht_routing_meta:active(Nodes, nodes, T), T}
    end).
    
active_pre(S) -> initialized(S).

active_args(S) -> [rt_nodes(S)].

active_pre(S, [Nodes]) ->
    Current = current_nodes(S),
    lists:all(fun(N) -> lists:member(N, Current) end, Nodes).

active_callouts(_S, [Nodes]) ->
    ?APPLY(active_nodes, [Nodes]).

%% CAN_INSERT
%% --------------------------------------------------

%% We can query the routing table and ask it if we can insert a given node.
%% This is done by inserting the node and then asking for membership, but
%% not persisting the state of doing so. Hence, there is no state transition
%% possible when doing this.
can_insert(Node) ->
    eqc_lib:bind(?DRIVER, fun(T) -> {ok, dht_routing_meta:can_insert(Node, T), T} end).
    
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
%%
inactive(Nodes) ->
    eqc_lib:bind(?DRIVER,
      fun(T) ->
        {ok, dht_routing_meta:inactive(Nodes, nodes, T), T}
      end).
      
inactive_pre(S) -> initialized(S).

inactive_args(S) -> [rt_nodes(S)].

inactive_pre(S, [Nodes]) ->
    Current = current_nodes(S),
    lists:all(fun(N) -> lists:member(N, Current) end, Nodes).

%% The call checks the time for each node it is given
inactive_callouts(_S, [Nodes]) ->
  ?APPLY(inactive_nodes, [Nodes]).

%% INSERT
%% --------------------------------------------------

%% Inserting a node into the routing table can have several outcomes:
%%
%% * The node is not inserted, because it is already a member of the routing table
%%   in the first place.
%% * The node could be inserted, but we alreay have enough nodes for its range in
%%   the routing table.
%% * The node is inserted into the routing table because it replaces old inactive nodes
%%   in a range.
%% * The node is inserted into the routing table, because there is space for it in a
%%   range.

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
insert_args(_S) -> [dht_eqc:peer()].

%% Insertion splits into several possible rules based on the state of the routing table
%% with respect to the Node we try to insert:
%%
%% First, there is a member-check. Nodes which are already members are ignored and
%% nothing happens to the routing table.
%%
%% For a non-member we obtain its neighbours in the routing table, and figure out
%% if there are any inactive members. If there are, we remove one member to make sure
%% there is space in the range.
%%
%% Finally we `adjoin' the Node to the routing table, which is addressed as a separate
%% internal model transition.
%%
insert_callouts(S, [Node]) ->
    ?MATCH(Member,
        ?CALLOUT(dht_routing_table, is_member, [Node, rt_ref],
            lists:member(Node, current_nodes(S)) )),
    case Member of
        true -> ?RET(already_member);
        false ->
            ?MATCH(Neighbours, ?CALLOUT(dht_routing_table, members, [Node, rt_ref], rt_nodes(S))),
            ?MATCH(Inactive, ?APPLY(inactive, [Neighbours])),
            case Inactive of
               [] -> ?EMPTY;
               [Old | _] -> ?APPLY(remove, [Old])
            end,
            ?MATCH(R, ?APPLY(adjoin, [Node])),
            ?RET(R)
     end.

%% IS_MEMBER
%% --------------------------------------------------

%% Ask if a given node is a member of the Routing Table.
is_member(Node) ->
    eqc_lib:bind(?DRIVER, fun(T) -> {ok, dht_routing_meta:is_member(Node, T), T} end).

is_member_pre(S) -> initialized(S).

is_member_args(_S) -> [dht_eqc:peer()].
    
%% This is simply a forward to the underlying routing table, so it should return whatever
%% The RT returns.
is_member_callouts(#state { nodes = Ns }, [Node]) ->
    ?MATCH(R, ?CALLOUT(dht_routing_table, is_member, [Node, rt_ref],
        lists:member(Node, Ns))),
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

neighbors_args(_S) -> [dht_eqc:id(), nat()].

neighbors_callouts(S, [ID, K]) ->
    ?MATCH(R,
      ?CALLOUT(dht_routing_table, closest_to, [ID, ?WILDCARD, K, rt_ref],
    	  rt_nodes(S))),
    case R of
       L when length(L) == K -> ?RET(L);
       L ->
         ?MATCH(Q,
           ?CALLOUT(dht_routing_table, closest_to, [ID, ?WILDCARD, K-length(L), rt_ref],
             rt_nodes(S))),
         ?RET(L ++ Q)
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
    ?MATCH(R,
        ?CALLOUT(dht_routing_table, node_list, [rt_ref],
            rt_nodes(S))),
    ?RET(R).
    
%% NODE_TIMER_STATE
%% --------------------------------------------------
%%

%% The call to the node_timer_state is a query on the internal timer state of
%% the system. It returns different values depending on the internal timer state
%% in the system
node_timer_state(Node) ->
    eqc_lib:bind(?DRIVER,
      fun(T) ->
          {ok, dht_routing_meta:node_timer_state(Node, T), T}
      end).
      
node_timer_state_pre(S) -> initialized(S) andalso has_nodes(S).

node_timer_state_args(S) -> [elements(current_nodes(S))].

node_timer_state_callouts(S, [Node]) ->
    ?MATCH(R,
        ?CALLOUT(dht_routing_table, is_member, [Node, rt_ref],
            lists:member(Node, current_nodes(S)))),
    case R of
        false -> ?RET(not_member);
        true ->
            ?APPLY(timer_state, [node, Node])
    end.

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

node_timeout_args(S) -> [elements(current_nodes(S))].

node_timeout_callouts(_S, [_Node]) ->
    ?RET(ok).

node_timeout_next(#state { node_timers = NT } = S, _, [Node]) ->
    {Node, LA, Count} = lists:keyfind(Node, 1, NT),
    S#state { node_timers = lists:keyreplace(Node, 1, NT, {Node, LA, Count+1}) }.

%% RANGE_MEMBERS
%% --------------------------------------------------

%% Returns the members of given node range.
%%
range_members(Node) ->
    eqc_lib:bind(?DRIVER, fun(T) -> {ok, dht_routing_meta:range_members(Node, T), T} end).

range_members_pre(S) -> initialized(S).

range_members_args(_S) -> [dht_eqc:peer()].
    
%% This is simply a forward to the underlying routing table, so it should return whatever
%% The RT returns.
range_members_callouts(S, [Node]) ->
    ?MATCH(R, ?CALLOUT(dht_routing_table, members, [Node, rt_ref], [rt_nodes(S)])),
    ?RET(R).

%% RANGE_STATE
%% --------------------------------------------------
%%
range_state(Range) ->
    eqc_lib:bind(?DRIVER, fun(T) -> {ok, dht_routing_meta:range_state(Range, T), T} end).
    
range_state_pre(S) -> initialized(S).

range_state_args(_S) -> [dht_eqc:range()].

range_state_callouts(S, [Range]) ->
    ?MATCH(Members,
        ?CALLOUT(dht_routing_table, members, [Range, rt_ref], rt_nodes(S))),
    ?MATCH(Active, ?APPLY(active, [Members])),
    ?MATCH(Inactive, ?APPLY(inactive, [Members])),
    ?RET(#{ active => Active, inactive => Inactive}).

%% RANGE_TIMER_STATE
%% --------------------------------------------------
%%

%% The call to the range_timer_state is a query on the internal timer state of
%% the system. It returns different values depending on the internal timer state
%% in the system. The call is more or less equivalent to the state of node timers,
%% but queries the other timer map().
range_timer_state(Range) ->
    eqc_lib:bind(?DRIVER,
      fun(T) ->
          {ok, dht_routing_meta:range_timer_state(Range, T), T}
      end).
      
range_timer_state_pre(S) -> initialized(S).

range_timer_state_args(S) ->
    Range =
      frequency(
        [{10, rt_range(S)} || has_nodes(S)] ++
        [{1, dht_eqc:range()}]),
    [Range].

range_timer_state_callouts(#state { ranges = RS }, [Range]) ->
    ?MATCH(R,
        ?CALLOUT(dht_routing_table, is_range, [Range, rt_ref],
            lists:member(Range, RS))),
    case R of
        false -> ?RET(not_member);
        true ->
            ?APPLY(timer_state, [range, Range])
    end.

%% REFRESH_NODE
%% --------------------------------------------------

%% Refreshing a node means that the node had activity. In turn, its timer
%% structure should be refreshed when this happens. The transition is that
%% we remove the old timer and install a new timer at a future point in time.
refresh_node(Node) ->
    eqc_lib:bind(?DRIVER,
        fun(T) ->
            R = dht_routing_meta:refresh_node(Node, T),
            {ok, ok, R}
        end).
        
refresh_node_pre(S) -> initialized(S) andalso has_nodes(S).

refresh_node_args(S) -> [rt_node(S)].

refresh_node_callouts(#state { time = T }, [_Node]) ->
    ?CALLOUT(dht_time, monotonic_time, [], T),
    ?RET(ok).

refresh_node_next(#state { node_timers = NTs, time = T } = S, _, [Node]) ->
    S#state { node_timers = lists:keyreplace(Node, 1, NTs, {Node, T, 0}) }.

%% REFRESH_RANGE_BY_NODE
%% --------------------------------------------------

refresh_range_by_node(Node) ->
    eqc_lib:bind(?DRIVER,
      fun(T) ->
        R = dht_routing_meta:refresh_range_by_node(Node, T),
        {ok, ok, R}
      end).
      
refresh_range_by_node_pre(S) -> initialized(S) andalso has_nodes(S).

refresh_range_by_node_args(S) -> [rt_node(S)].

refresh_range_by_node_callouts(S, [{ID, _, _} = Node]) ->
    ?MATCH(Range,
        ?CALLOUT(dht_routing_table, range, [ID, rt_ref], range_by_node(S, Node))),
    Activity = find_range_activity(S, Range),
    ?APPLY(refresh_range, [Range, Activity]),
    ?RET(ok).
    
%% REFRESH_RANGE
%% --------------------------------------------------

refresh_range(Range) ->
    eqc_lib:bind(?DRIVER,
      fun(T) ->
        R = dht_routing_meta:refresh_range(Range, T),
        {ok, ok, R}
      end).
      
refresh_range_pre(S) -> initialized(S) andalso has_nodes(S).

refresh_range_args(S) -> [rt_range(S)].

refresh_range_callouts(S, [Range]) ->
    ?MATCH(Oldest, ?APPLY(range_last_activity, [Range])),
    refresh_range_callouts(S, [Range, Oldest]);
refresh_range_callouts(_S, [Range, Timestamp]) ->
    ?APPLY(remove_range_timer, [Range]),
    ?APPLY(add_range_timer_at, [Range, Timestamp]),
    ?RET(ok).

range_last_activity_callouts(#state { time = T } = S, [Range]) ->
    ?MATCH(Members,
        ?CALLOUT(dht_routing_table, members, [Range, rt_ref], rt_nodes(S))),
    case find_oldest(S, Members, ranges) of
        undefined ->
          ?MATCH(R, ?CALLOUT(dht_time, monotonic_time, [], T)),
          ?RET(R);
        Min ->
          ?RET(Min)
    end.

%% TIMER STATE (Internal call)
%% --------------------------------------------------

%% This call implements an internal call for querying the current state of the timer.
timer_state_callouts(#state { node_timers = NT, time = T }, [node, Node]) ->
    case lists:keyfind(Node, 1, NT) of
        {_, _, Count} when Count > 2 -> ?RET(bad);
        {_, At, _} ->
            ?CALLOUT(dht_time, monotonic_time, [], T),
            Age = T - At,
            ?CALLOUT(dht_time, convert_time_unit, [Age, native, milli_seconds], Age),
            case Age < ?NODE_TIMEOUT of
                true -> ?RET(good);
                false -> ?RET({questionable, Age - ?NODE_TIMEOUT})
            end
    end;
timer_state_callouts(#state { range_timers = RT, time = T }, [range, Range]) ->
    {Range, At, _} = lists:keyfind(Range, 1, RT),
    ?CALLOUT(dht_time, monotonic_time, [], T),
    Age = T - At,
    ?CALLOUT(dht_time, convert_time_unit, [Age, native, milli_seconds], Age),
    case Age < ?RANGE_TIMEOUT of
        true -> ?RET(ok);
        false -> ?RET(need_refresh)
    end.

%% INACTIVE/ACTIVE nodes (Internal call)
%% --------------------------------------------------

%% Compute the active/inactive nodes as callout specifications. This
%% Allows us to specify what nodes are currently active and/or inactive
%% which is needed in several calls.

%% Calling inactive with a set of nodes Ns, will return those nodes which are
%%
%% * Present
%% * Their timer has already triggered
%%
%% These nodes are the ones which are "timed out" in the sense of the notion
%% used here.
%%
%% To compute this, request the last point of activity and add the range timeout
%% in order to see if the current time is beyond that. If affirmative, then the timer
%% has triggered.
inactive_nodes_callouts(#state { time = T } = S, [Nodes]) ->
    F = fun(N) ->
        case find_last_activity(S, N) of
            not_found -> false;
            {ok, P} -> (P+?RANGE_TIMEOUT) =< T
        end
    end,
    assert_nodes_in_model(S, Nodes),
    ?SEQ([ ?APPLY(time_check, [N]) || N <- Nodes]),
    ?RET(lists:filter(F, Nodes)).
    
%% Active nodes are those which are not inactive, but still present in the node table.
active_nodes_callouts(#state { time = T } = S, [Nodes]) ->
    F = fun(N) ->
        case find_last_activity(S, N) of
            not_found -> false;
            {ok, P} -> (P+?NODE_TIMEOUT) > T
        end
    end,
    assert_nodes_in_model(S, Nodes),
    ?SEQ([ ?APPLY(time_check, [N]) || N <- Nodes]),
    ?RET(lists:filter(F, Nodes)).

%% INIT_RANGE_TIMERS (Internal call)
%% --------------------------------------------------

%% Initialization of range timers follows the same general structure:
%% we successively add a new range timer to the state.
init_range_timers_callouts(#state { ranges = RS }, [Ranges]) ->
    ?CALLOUT(dht_routing_table, ranges, [rt_ref], RS),
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
init_nodes_callouts(_, [_Nodes]) ->
    ?CALLOUT(dht_time, convert_time_unit, [?NODE_TIMEOUT, milli_seconds, native],
          ?NODE_TIMEOUT).

init_nodes_next(#state { time = T } = S, _, [Nodes]) ->
    NodeTimers = [{N, T-?NODE_TIMEOUT, 0} || N <- lists:reverse(Nodes)],
    S#state { node_timers = NodeTimers }.

%% TIME_CHECK (Internal call)
%% --------------------------------------------------
%% time_check is an internal call for checking time for a given timeout

time_check_callouts(#state { time = T } = State, [Node]) ->
    case find_last_activity(State, Node) of
        not_found -> ?RET(not_found);
        {ok, P} ->
            Timestamp = T - P,
            ?CALLOUT(dht_time, monotonic_time, [], T),
            ?CALLOUT(dht_time, convert_time_unit, [Timestamp, native, milli_seconds], Timestamp)
    end.
    
%% REMOVAL (Internal call)
%% --------------------------------------------------

%% TODO: Think about the rules for timers if we remove stuff
remove_callouts(_S, [Node]) ->
    ?CALLOUT(dht_routing_table, delete, [Node, rt_ref], rt_ref),
    ?RET(ok).

remove_next(#state { nodes = Nodes } = State, _, [Node]) ->
    State#state { nodes = lists:keydelete(Node, 1, Nodes) }.

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
            ?RET(ok)
    end.
    
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

add_range_timer_callouts(#state { tref = C, time = T }, [_Range]) ->
    ?CALLOUT(dht_time, monotonic_time, [], T),
    ?CALLOUT(dht_time, convert_time_unit, [?WILDCARD, native, milli_seconds], T),
    ?CALLOUT(dht_time, send_after, [?WILDCARD, ?WILDCARD, ?WILDCARD], C).

add_range_timer_at_callouts(#state { tref = C, time = T }, [_Range, At]) ->
    ?CALLOUT(dht_time, monotonic_time, [], T),
    Point = T - At,
    ?CALLOUT(dht_time, convert_time_unit, [Point, native, milli_seconds], Point),
    ?CALLOUT(dht_time, send_after, [monus(?RANGE_TIMEOUT, Point), ?WILDCARD, ?WILDCARD], C).
    
%% Adding a range timer transitions the system by keeping track of the timer state
%% and the fact that a range timer was added.
add_range_timer_next(
	#state { time = T, timers = TS, tref = C, range_timers = RT } = State, _, [Range]) ->
    State#state {
        tref = C+1,
        range_timers = RT ++ [{Range, T, C}],
        timers = orddict:store(T+?RANGE_TIMEOUT, C, TS)
    }.

add_range_timer_at_next(#state { timers = TS, tref = C, range_timers = RT } = State, _, [Range, At]) ->
    State#state {
        tref = C+1,
        range_timers = RT ++ [{Range, At, C}],
        timers = orddict:store(At+?RANGE_TIMEOUT, C, TS)
    }.

%% When updating node timers, we have the option of overriding the last activity point
%% of that node. The last activity point is passed as an extra parameter in this call.
%%
%% TODO: The time unit returned here is incorrect!
add_node_timer_callouts(#state { tref = C, time = T}, [_Node, _Activity]) ->
    ?FAIL(called_node_timer_next),
    ?CALLOUT(dht_time, monotonic_time, [], T),
    ?CALLOUT(dht_time, convert_time_unit, [?WILDCARD, native, milli_seconds], T),
    ?CALLOUT(dht_time, send_after, [?WILDCARD, ?WILDCARD, ?WILDCARD], C).
    
%% TODO: The add_node_timer transition is probably very wrong currently.
add_node_timer_next(#state { node_timers = NT } = State, _, [Node, Activity]) ->
    State#state {
        node_timers = NT ++ [{Node, Activity, 0}]
    }.
    
%% Removing a node/range timer from the model state is akin to deleting that state
%% from the list of node timers.
%%
%% TODO: Maybe we should also kill the timer itself, but the code is not currently
%% doing so.
remove_node_timer_next(#state { node_timers = NT } = State, _, [Node]) ->
    State#state { node_timers = lists:keydelete(Node, 1, NT) }.
    
remove_range_timer_callouts(S, [Range]) ->
    {Range, _At, TRef} = range_timer(S, Range),
    ?CALLOUT(dht_time, cancel_timer, [TRef], oneof([false, nat()])),
    ?RET(ok).
    
remove_range_timer_next(#state { range_timers = RT } = State, _, [Range]) ->
    State#state { range_timers = lists:keydelete(Range, 1, RT) }.

range_timer(#state { range_timers = RT }, Range) ->
    {_, _, _} = lists:keyfind(Range, 1, RT).

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
has_nodes(#state { nodes = Ns }) -> Ns /= [].

%% Given a state and a node, find the last activity point of the node
find_last_activity(#state { node_timers = NT }, Node) ->
    case lists:keyfind(Node, 1, NT) of
        false -> not_found;
        {Node, P, _C} -> {ok, P}
    end.

find_oldest(#state { node_timers = NT }, Members, ranges) ->
    Ks = [lists:keyfind(M, 1, NT) || M <- Members],
    Xs = [TS || {_, TS, _} <- Ks],
    case Xs of
        [] -> undefined;
        L -> lists:min(L)
    end.

timer_ref(#state { range_timers = RT }, R, range) ->
    timer_find(R, RT);
timer_ref(#state { node_timers = NT }, N, node) ->
    timer_find(N, NT).
    
timer_find(E, Es) ->
    case lists:keyfind(E, 2, Es) of
        false -> not_found;
        {TRef, E, _} -> {ok, TRef}
    end.

timer_timeout(#state { timers = TS, time = T }, TRef) ->
    {P, _} = lists:keyfind(TRef, 2, TS),
    P >= T.

timer_state(#state { time = T, timers = TS }, TRef) ->
    case lists:keyfind(TRef, 2, TS) of
        false -> false;
        {P, _} when P > T -> P - T;
        {P, _} when P =< T -> false % Already triggered
    end.

node_timers(#state { node_timers = NTs }, nodes) ->
    [N || {N, _, _} <- NTs].

rt_node(S) -> elements(current_nodes(S)).

rt_nodes(#state { nodes = Ns } = S) ->
    case Ns of
        [] -> [];
        _ -> list(elements(current_nodes(S)))
    end.

rt_range(S) -> elements(current_ranges(S)).

range_by_node(#state { nodes = Ns }, Node) ->
    {Node, Range} = lists:keyfind(Node, 1, Ns),
    Range.
    
find_range_activity(#state { range_timers = RTs }, Range) ->
    {Range, Activity, _TRef} = lists:keyfind(Range, 1, RTs),
    Activity.

    
dedup(Xs) ->
    dedup(Xs, #{}).
    
dedup([], _) -> [];
dedup([X | Xs], M) ->
    case maps:get(X, M, false) of
        true -> dedup(Xs, M);
        false -> [X | dedup(Xs, M#{ X => true })]
    end.

%% Helper, returns an assertion on node presence in the model which
%% can be grafted onto a callout specification.
assert_nodes_in_model(_S, []) -> ?EMPTY;
assert_nodes_in_model(#state { nodes = Ns } = S, [N|Rest]) ->
    case lists:keymember(N, 1, Ns) of
        true -> assert_nodes_in_model(S, Rest);
        false -> ?FAIL({not_a_node, N})
    end.

current_ranges(#state { ranges = RS }) -> RS.

current_nodes(#state { nodes = NS }) ->
    [N || {N, _Range} <- NS].

monus(A, B) when A > B -> A - B;
monus(A, B) when A =< B -> 0.

