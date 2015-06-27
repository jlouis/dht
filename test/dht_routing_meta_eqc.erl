%% @doc EQC model for routing+timing
%%
%% This model defines the rules for the DHTs timing state.
%% 
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
%% How do we manage equality on Nodes? There are two answers to this question:
%% (1) N1 =:= N2
%% (2) element(1, N1) =:= element(1, N2) (compare the IDs of the nodes)
%%
%% What to use probably depends on where the node is added.
%%
%% Buckets and ranges are split in the obvious pattern. A good question is:
%% Do we split once a bucket reaches 8 nodes, or once it has more than 8 nodes?
%% The answer, of course, is: which solution gives the most lean code?
%%
%% In the case of split at ==8:
%% In the case of split at >8:
%%
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
%% TODO: Startup:
%% 
%% • Inserting the first node
%% • Or starting up with a routing table thereafter
%% 
%% Issue a FIND_NODE request on your own ID until you can't find any closer nodes.
%% 
%% TODO—things-to-analyze in the current model:
%%
%% • After we started looking at the BEP 0005 spec, we have realized this module needs
%%    some serious rewriting, as it is currently not doing the right thing.
%% • Mistake #1: Return {questionable, τ} for a point in time τ rather than returning
%%    {questionable, Age} for its age. This means we can sort based on questionability.
%% • How do we assert the return from a range needing refreshing is random? The postcondition
%%   is obvious here, but it requires us to run a function on the data...
%% • Fun one: ranges can be empty. A range splits, but nothing falls into one side. This means an
%%   empty range, and thus a range timer which picks among an empty list of nodes. Luckily, I
%%   think the specification handles this case and does the right thing :P
%% • When inserting new nodes into the routing table they are set as unreachable. Is this correct?
%%   we can implement the other behaviour by an immediate node touch, but…
%% • dht_routing_table:is_range/2 should die!
-module(dht_routing_meta_eqc).
-compile(export_all).

-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_component.hrl").

-include("dht_eqc.hrl").

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
	
	%% The fields time, timers and tref models time. The idea is that `time' is the
	%% monotonic time on the system, timers is an (ordered) list of the current timers
	%% and tref is used to draw unique timer references in the system.

	%%% MODEL OF THE ROUTING SYSTEM
	%%
	init = false :: boolean(),
	%% init encodes if we have initialized the routing table or not.
	id = 0:: any(),
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
            #api_fun { name = pick, arity = 1 }
          ]},
        #api_module {
          name = dht_routing_table,
          functions = [
            #api_fun { name = new, arity = 3, classify = dht_routing_table_eqc },

            #api_fun { name = closest_to, arity = 2, classify = dht_routing_table_eqc },
            #api_fun { name = delete, arity = 2, classify = dht_routing_table_eqc },
            #api_fun { name = insert, arity = 2, classify = dht_routing_table_eqc },
            #api_fun { name = member_state, arity = 2, classify = dht_routing_table_eqc },
            #api_fun { name = is_range, arity = 2, classify = dht_routing_table_eqc },
            #api_fun { name = members, arity = 2, classify = dht_routing_table_eqc },
            #api_fun { name = node_id, arity = 1, classify = dht_routing_table_eqc },
            #api_fun { name = node_list, arity = 1, classify = dht_routing_table_eqc },
            #api_fun { name = ranges, arity = 1, classify = dht_routing_table_eqc },
            #api_fun { name = space, arity = 2, classify = dht_routing_table_eqc }
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
nodes(Lo, Hi, Limit) ->
    ?LET(Sz, choose(0, Limit),
      ?LET(IDGen, vector(Sz, choose(Lo, Hi)),
        [{ID, dht_eqc:ip(), dht_eqc:port()} || ID <- dedup(IDGen)])).

%% A tree is sized over the current generation size:
routing_tree() ->
    ?SIZED(Sz, routing_tree(Sz, ?ID_MIN, ?ID_MAX, split_yes)).
    
%% Trees are based on their structure:
%% • Trees of size 0 generates nodes in the current range.
%% • Trees where the Lo–Hi distance is short are like size 0 trees.
%% • Larger trees are either done, or their consist of a split-point in the range
%%    and then they consist of two trees of smaller sizes.
%%
%% Also a tree node can either be the one which can be split, or the one which
%% can't be split. We only consider splitting nodes which are splittable in the tree
%% and this guides the structure of the tree.
%% • Leaf nodes which can be split can at most have 7 nodes. If they had 8, they would be
%%   split by the code.
%% • Leaf nodes which cannot be split, can have 0 to 8 nodes in them.
%%
routing_tree(0, Lo, Hi, Split) ->
    {Splittable, Nodes} =
      case Split of
        split_yes -> {true, nodes(Lo, Hi, 7)};
        split_no -> {false, nodes(Lo, Hi, 8)}
      end,
    [#{ lo => Lo, hi => Hi, nodes => Nodes, split => Splittable }];
routing_tree(_N, Lo, Hi, Split) when Hi - Lo < 4 -> routing_tree(0, Lo, Hi, Split);
routing_tree(_N, Lo, Hi, split_no) ->
    routing_tree(0, Lo, Hi, split_no);
routing_tree(N, Lo, Hi, split_yes) ->
    oneof([
        routing_tree(0, Lo, Hi, split_yes),
        ?LAZY(
            ?LET({Point, Side}, {choose(Lo+1, Hi-1), elements([l, r])},
              ?LET([L, R], split_tree(N div 2, Lo, Hi, Point, Side),
                L ++ R)))
    ]).

split_tree(Sz, Lo, Hi, Point, l) ->
    [routing_tree(Sz, Lo, Point, split_yes), routing_tree(Sz, Point+1, Hi, split_no)];
split_tree(Sz, Lo, Hi, Point, r) ->
    [routing_tree(Sz, Lo, Point, split_no), routing_tree(Sz, Point+1, Hi, split_yes)].

pick_id([#{ lo := L, hi := H, split := true } | _]) -> choose(L, H);
pick_id([_ | Rs]) -> pick_id(Rs).

gen_state(ID) ->
      #state {
        tree = [#{ lo => 0, hi => 128, nodes => [], split => true }],
        init = false,
        id = ID,
        node_timers = [],
        range_timers = []
      }.

initial_state() -> #state{}.

%% NEW
%% --------------------------------------------------

%% When the system initializes,  the routing table may be loaded from disk. When
%% that happens, we have to re-instate the timers by query of the routing table, and
%% then construct those timers.
new(Tbl) ->
    eqc_lib:reset(?DRIVER),
    eqc_lib:bind(?DRIVER, fun(_T) ->
      {ok, ID, Routing} = dht_routing_meta:new(Tbl),
      {ok, {ok, ID, 'ROUTING_TABLE'}, Routing}
    end).

new_callers() -> [dht_state_eqc].

%% You can only initialize once, so the system is not allowed to be initialized
%% if it already is.
new_pre(S) -> not initialized(S).

%% Construct a Table entry for injection.
new_args(#state {}) -> ['ROUTING_TABLE'].

%% When new is called, the system calls out to the routing_table. We feed the
%% Nodes and Ranges we generated into the system. The assumption is that
%% these Nodes and Ranges are ones which are initialized via the internal calls
%% init_range_timers and init_node_timers.
new_callouts(#state { id = ID } = S, [Tbl]) ->
    ?APPLY(dht_routing_table_eqc, ensure_started, []),
    ?MATCH(T, ?APPLY(dht_time_eqc, monotonic_time, [])),
    ?CALLOUT(dht_routing_table, node_list, [Tbl], current_nodes(S)),
    ?CALLOUT(dht_routing_table, node_id, [Tbl], ID),
    ?APPLY(init_range_timers, [current_ranges(S), T]),
    ?APPLY(init_nodes, [current_nodes(S), T]),
    ?RET({ok, ID, 'ROUTING_TABLE'}).
  
%% Track that we initialized the system
new_next(S, _, _) -> S#state { init = true }.

new_features(_S, [_Tbl], _R) -> [{meta, new}].

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
insert(Node, _) ->
    eqc_lib:bind(?DRIVER,
      fun(T) ->
          case dht_routing_meta:insert(Node, T) of
              {ok, S} -> {ok, ok, S};
              not_inserted -> {ok, not_inserted, T}
          end
      end).

insert_callers() -> [dht_state_eqc].

%% You can only insert data when the system has been initialized.
insert_pre(S) -> initialized(S).

%% Any peer is eligible for insertion at any time. There are no limits on how and when
%% you can do this insertion.
insert_args(S) ->
    Peer = ?SUCHTHAT(P, dht_eqc:peer(), not has_peer(P, S)),
    [Peer, 'ROUTING_TABLE'].

insert_pre(S, [Peer, _]) -> initialized(S) andalso (not has_peer(Peer, S)).

%% We `adjoin' the Node to the routing table, which is addressed as a separate
%% internal model transition.
%%
%% TODO: Go through this, it may be wrong.
%% TODO list:
%% • The bucket may actually split more than once in this call, and we don't track it!
insert_callouts(_S, [Node, _]) ->
    ?MATCH(R, ?APPLY(adjoin, [Node])),
    case R of
        ok -> ?RET(ok);
        not_inserted -> ?RET(not_inserted);
        Else -> ?FAIL(Else)
    end.

insert_features(_S, _A, _R) -> [{meta, insert}].

%% IS_MEMBER
%% --------------------------------------------------

%% Ask if a given node is a member of the Routing Table.
member_state(Node, _) ->
    eqc_lib:bind(?DRIVER, fun(T) -> {ok, dht_routing_meta:member_state(Node, T), T} end).

member_state_callers() -> [dht_state_eqc].

member_state_pre(S) -> initialized(S).

member_state_args(_S) -> [dht_eqc:peer(), 'ROUTING_TABLE'].
    
%% This is simply a forward to the underlying routing table, so it should return whatever
%% The RT returns.
member_state_callouts(_S, [Node, _]) ->
    ?MATCH(R, ?CALLOUT(dht_routing_table, member_state, [Node, 'ROUTING_TABLE'],
        oneof([unknown, member, roaming_member]))),
    ?RET(R).

member_state_features(_S, _A, Res) -> [{meta, {member_state, Res}}].

%% NEIGHBORS
%% --------------------------------------------------

%% Neighbours returns the K nodes which are closest to a given node in
%% the routing table. We just verify that the call is correct with respect to
%% the system.
neighbors(ID, K, _) ->
    eqc_lib:bind(?DRIVER,
      fun(T) ->
          {ok, dht_routing_meta:neighbors(ID, K, T), T}
      end).

neighbors_callers() -> [dht_state_eqc].
      
neighbors_pre(S) -> initialized(S).

neighbors_args(_S) -> [dht_eqc:id(), choose(0, 8), 'ROUTING_TABLE'].

take(0, _) -> [];
take(_, []) -> [];
take(K, [X|Xs]) when K > 0 -> [X | take(K-1, Xs)].

%% To figure out what nodes to return, we obtain a sorted order of nodes. Then we
%% satisy the call by picking good nodes in preference, and then picking questionable
%% nodes for the remainder if we can't satisfy our target with good nodes.
neighbors_callouts(S, [ID, K, _]) ->
    ?MATCH(Nodes, ?CALLOUT(dht_routing_table, closest_to, [ID, 'ROUTING_TABLE'],
        rt_nodes(S))),
    ?MATCH(State, ?APPLY(node_state, [Nodes, 'META'])),
    {Good, _} = lists:partition(fun ({_, St}) -> St == good end, State),
    {Questionable, _} = lists:partition(
        fun
          ({_, {questionable, _}}) -> true;
          (_) -> false
        end,
        State),
    ?RET(take(K, [N || {N, _} <- (Good ++ Questionable)])).

neighbors_features(_S, _A, R) ->
    case R of
        [] -> [{meta, {neighbors, empty}}];
        L when is_list(L) -> [{meta, {neighbors, cons}}]
    end.

%% NODE_LIST
%% --------------------------------------------------
%%
%% Node list is a proxy forward to the node_list call of the routing table

node_list(_) ->
    eqc_lib:bind(?DRIVER, fun(T) -> {ok, dht_routing_meta:node_list(T), T} end).
    
node_list_callers() -> [dht_state_eqc].

node_list_pre(S) -> initialized(S).
	
node_list_args(_S) -> ['ROUTING_TABLE'].

node_list_callouts(S, [_]) ->
    ?MATCH(R, ?CALLOUT(dht_routing_table, node_list, [?WILDCARD], rt_nodes(S))),
    ?RET(R).
    
node_list_features(_S, _A, _R) -> [{meta, node_list}].

%% NODE_STATE
%% --------------------------------------------------

node_state(Nodes, _) ->
    eqc_lib:bind(?DRIVER,
      fun(T) -> {ok, dht_routing_meta:node_state(Nodes, T), T}
    end).

node_state_callers() -> [dht_state_eqc].
    
node_state_pre(S) -> initialized(S).

%% We currently generate output for known nodes only. The obvious
%% thing to do when a node is unknown is to ignore it.
%% TODO: Send in unknown nodes.
node_state_args(S) -> [rt_nodes(S), 'ROUTING_TABLE'].

node_state_pre(S, [Nodes, _]) ->
    Current = current_nodes(S),
    lists:all(fun(N) -> lists:member(N, Current) end, Nodes).
    
%% Node state value (Internal call)
%% --------------------------------------

%% Given a time T and a node last activity point, Tau, compute the expected node state value
%% for that tuple.
node_questionability(T, Tau) ->
    Age = T - Tau,
    case Age < ?NODE_TIMEOUT of
        true -> good;
        false -> {questionable, Tau}
    end.

%% We simply expect this call to carry out queries on each given node in the member list.
%% And we expect the return to be computed in the same order as the query itself.
node_state_callouts(_S, [[], _X]) -> ?RET([]);
node_state_callouts(#state { node_timers = NTs }, [[N|Ns], X]) ->
    case lists:keyfind(N, 1, NTs) of
        false ->
          ?MATCH(Rest, ?APPLY(node_state, [Ns, X])),
          ?RET([{N, not_member} | Rest]);
        {_, _, Errs, _} when Errs > 1 ->
          ?MATCH(Rest, ?APPLY(node_state, [Ns, X])),
          ?RET([{N, bad} | Rest]);
        {_, Tau, _, _} ->
            ?MATCH(T, ?APPLY(dht_time_eqc, monotonic_time, [])),
            ?APPLY(dht_time_eqc, convert_time_unit, [T - Tau, native, milli_seconds]),
            NodeState = node_questionability(T, Tau),
            ?MATCH(Rest, ?APPLY(node_state, [Ns, X])),
            ?RET([{N, NodeState} | Rest])
    end.

node_state_features(_S, _A, Result) ->
    lists:usort([
      case R of
        {_, {questionable, _}} -> {meta, {node_state, questionable}};
        {_, X} -> {meta, {node_state, X}}
      end || R <- Result]).

%% NODE_TIMEOUT
%% --------------------------------------------------

%% The node_timeout/2 call is invoked whenever a node doesn't respond within the allotted
%% time. The policy is, that the nodes ends up with a bad state once it has increased its timer
%% enough times.
node_timeout(Node, _) ->
    eqc_lib:bind(?DRIVER,
      fun(T) ->
        {ok, ok, dht_routing_meta:node_timeout(Node, T)}
      end).

node_timeout_callers() -> [dht_state_eqc].
      
node_timeout_pre(S) -> initialized(S) andalso has_nodes(S).

node_timeout_args(S) -> [rt_node(S), 'ROUTING_TABLE'].

node_timeout_pre(S, [Node, _]) -> has_peer(Node, S).

node_timeout_callouts(#state { node_timers = NT }, [Node, _]) ->
    case lists:keymember(Node, 1, NT) of
        true -> ?RET(ok);
        false -> ?FAIL({node_timeout, {unknown_node, Node}})
    end.

node_timeout_next(#state { node_timers = NT } = S, _, [Node, _]) ->
    case lists:keyfind(Node, 1, NT) of
        {Node, LA, Count, Reachable} ->
            S#state { node_timers = lists:keyreplace(Node, 1, NT, {Node, LA, Count+1, Reachable}) };
        false ->
            S
    end.

node_timeout_features(_S, _A, _R) -> [{meta, node_timeout}].

%% RANGE_MEMBERS
%% --------------------------------------------------

%% Returns the members of given node range.
%%
range_members(Node, _) ->
    eqc_lib:bind(?DRIVER, fun(T) -> {ok, dht_routing_meta:range_members(Node, T), T} end).

range_members_callers() -> [dht_state_eqc].

range_members_pre(S) -> initialized(S).

range_members_args(S) ->
    NodeOrRange = oneof([dht_eqc:peer(), rt_range(S)]),
    [NodeOrRange, 'ROUTING_TABLE'].

%% This is simply a forward to the underlying routing table, so it should return whatever
%% The RT returns.
range_members_callouts(S, [{Lo, Hi} = Range, _]) ->
    ?MATCH(R, ?CALLOUT(dht_routing_table, members, [{range, Range}, 'ROUTING_TABLE'],
    		nodes_in_range(S, {Lo, Hi}))),
    case R of
        error -> ?FAIL(range_invariant_broken);
        Res -> ?RET(Res)
    end;
range_members_callouts(S, [{ID, _, _} = Node, _]) ->
    ?MATCH(R, ?CALLOUT(dht_routing_table, members, [{node, Node}, 'ROUTING_TABLE'],
    		nodes_in_range(S, ID))),
    case R of
        error -> ?FAIL(range_invariant_broken);
        Res -> ?RET(Res)
    end.

range_members_features(_S, [{_, _, _}, _], _) -> [{meta, {range_members, node}}];
range_members_features(_S, [{_, _}, _], _) -> [{meta, {range_members, range}}].

%% NODE_TOUCH
%% --------------------------------------------------

%% Refreshing a node means that the node had activity. In turn, its timer
%% structure should be refreshed when this happens. The transition is that
%% we remove the old timer and install a new timer at a future point in time.
node_touch(Node, Opts, _) ->
    eqc_lib:bind(?DRIVER,
        fun(T) ->
            R = dht_routing_meta:node_touch(Node, Opts, T),
            {ok, ok, R}
        end).

node_touch_callers() -> [dht_state_eqc].
        
node_touch_pre(S) -> initialized(S) andalso has_nodes(S).

node_touch_args(S) -> [rt_node(S), #{ reachable => bool() }, 'ROUTING_TABLE'].

node_touch_pre(S, [Node, _, _]) -> 
    Ns = current_nodes(S),
    lists:member(Node, Ns).

node_replace_next(#state{ node_timers = NTs } = S, _, [Node, Tuple]) ->
    S#state { node_timers = lists:keyreplace(Node, 1, NTs, Tuple) }.

node_touch_callouts(#state { node_timers = NTs }, [Node, #{ reachable := R2}, _]) ->
    case lists:keyfind(Node, 1, NTs) of
        {_, _, _, R1} when R1 or R2 -> 
            ?MATCH(T, ?APPLY(dht_time_eqc, monotonic_time, [])),
            ?APPLY(node_replace, [Node, {Node, T, 0, true}]),
            ?RET(ok);
        {_, _, _, _} ->
            ?RET(ok);
        false ->
            ?FAIL({node_touch, {unknown_node, Node}})
    end.

node_touch_features(_S, _A, _R) -> [{meta, node_touch}].


%% RANGE_STATE
%% --------------------------------------------------

range_state(Range, _) ->
    eqc_lib:bind(?DRIVER,
      fun(T) ->
          {ok, dht_routing_meta:range_state(Range, T), T}
      end).

range_state_callers() -> [dht_state_eqc].
      
range_state_pre(S) -> initialized(S).

range_state_args(S) ->
    Range = frequency([
        {10, rt_range(S)},
        {1, dht_eqc:range()}
    ]),
    [Range, 'ROUTING_TABLE'].

range_state_callouts(S, [Range, _]) ->
    ?MATCH(IsRange, ?CALLOUT(dht_routing_table, is_range, [Range, ?WILDCARD],
        lists:member(Range, current_ranges(S)))),
    case IsRange of
        false -> ?RET({error, not_member});
        true ->
            ?MATCH(Members, ?APPLY(range_members, [Range, ?WILDCARD])),
            ?MATCH(T, ?APPLY(dht_time_eqc, monotonic_time, [])),
            case last_active(S, Members) of
               {error, Reason} -> ?FAIL({error, Reason});
               [] -> ?RET(empty);
               [{_M, TS, _, _} | _] ->
                   ?APPLY(dht_time_eqc, convert_time_unit, [T - TS, native, milli_seconds]),
                   case (T - TS) =< ?RANGE_TIMEOUT of
                     true -> ?RET(ok);
                     false ->
                       IDs = [ID || {ID, _, _} <- Members],
                       ?MATCH(PickedID, ?CALLOUT(dht_rand, pick, [IDs], rand_pick(IDs))),
                       ?RET({needs_refresh, PickedID})
                   end
            end;
        Ret -> ?FAIL({wrong_result, Ret})
    end.
               
range_state_features(_S, _A, empty) -> [{meta, {range_state, empty}}];
range_state_features(_S, _A, {error, not_member}) -> [{meta, {range_state, non_existing_range}}];
range_state_features(_S, _A, ok) -> [{meta, {range_state, ok}}];
range_state_features(_S, _A, {needs_refresh, _}) -> [{meta, {range_state, needs_refresh}}].
    
%% REPLACE
%% --------------------------------------------------
replace(Old, New, _) ->
  eqc_lib:bind(?DRIVER,
    fun(T) ->
      case dht_routing_meta:replace(Old, New, T) of
          {ok, R} -> {ok, ok, R};
          Other -> {ok, Other, T}
      end
    end).
    
bad_nodes(#state { node_timers = NTs }) -> [N || {N, _, Errs, _} <- NTs, Errs > 1].

replace_pre(S) -> initialized(S) andalso (bad_nodes(S) /= []).

replace_args(S) ->
    [elements(bad_nodes(S)), dht_eqc:peer(), 'META'].

replace_pre(S, [Old, New, _]) ->
    has_peer(Old, S) andalso (not has_peer(New, S)).

%% Replacing a node with another node amounts to deleting one node, then adjoining in
%% the other node.
%% TODO: Assert the node we are replacing is currently questionable!
replace_callouts(_S, [OldNode, NewNode, Meta]) ->
    ?MATCH(MS, ?APPLY(member_state, [NewNode, Meta])),
    case MS of
        unknown ->
          ?APPLY(remove, [OldNode]),
          ?MATCH(Res, ?APPLY(adjoin, [NewNode])),
          ?RET(Res);
        roaming_member -> ?RET(roaming_member);
        member -> ?RET({error, member})
    end.

replace_features(_S, _A, ok) -> [{meta, {replace, ok}}];
replace_features(_S, _A, not_inserted) -> [{meta, {replace, not_inserted}}];
replace_features(_S, _A, roaming_member) -> [{meta, {replace, roaming_member}}];
replace_features(_S, _A, {error, What}) -> [{meta, {replace, {error, What}}}].


%% RESET_RANGE_TIMER
%% --------------------------------------------------

%% Resetting the range timer is done whenever the timer has triggered. So there is
%% a rule which says this can only happen once the timer has triggered.
%%
%% NOTE: this is an assumed precondition.
reset_range_timer(Range, Opts, _) ->
    eqc_lib:bind(?DRIVER,
        fun(T) ->
          R = dht_routing_meta:reset_range_timer(Range, Opts, T),
          {ok, ok, R}
        end).

reset_range_timer_callers() -> [dht_state_eqc].

reset_range_timer_pre(S) -> initialized(S).

reset_range_timer_args(S) ->
    [rt_range(S), #{ force => bool() }, 'ROUTING_TABLE'].

reset_range_timer_pre(S, [Range, _ ,_]) -> has_range(Range, S).

reset_range_timer_callouts(#state {}, [Range, #{ force := true }, _]) ->
    ?MATCH(T, ?APPLY(dht_time_eqc, monotonic_time, [])),
    ?APPLY(remove_range_timer, [Range]),
    ?APPLY(add_range_timer_at, [Range, T]),
    ?RET(ok);
reset_range_timer_callouts(_S, [Range, #{ force := false }, _]) ->
    ?MATCH(A, ?APPLY(range_last_activity, [Range])),
    ?APPLY(remove_range_timer, [Range]),
    ?APPLY(add_range_timer_at, [Range, A]),
    ?RET(ok).

reset_range_timer_features(_S, [_Range, #{ force := Force }, _], _R) ->
    [{meta, {reset_range_timer, case Force of true -> forced; false -> normal end}}].
    
%% RANGE_LAST_ACTIVITY (Internal call)
%% ---------------------------------------------------------
%% This call is used internally to figure out when there was last activity
%% on the range.
%% TODO: Assert that the range timer is already gone here, otherwise the call is
%% not allowed.
range_last_activity_callouts(S, [Range]) ->
    ?MATCH(Members,
        ?CALLOUT(dht_routing_table, members, [{range, Range}, ?WILDCARD], rt_nodes(S))),
    case last_active(S, Members) of
        [] ->
          ?MATCH(R, ?APPLY(dht_time_eqc, monotonic_time, [])),
          ?RET(R);
        [{_, At, _, _} | _] ->
          ?RET(At)
    end.

range_last_activity_features(_S, _A, _R) -> [{meta, range_last_activity}].

%% INIT_RANGE_TIMERS (Internal call)
%% --------------------------------------------------

%% Initialization of range timers follows the same general structure:
%% we successively add a new range timer to the state.
init_range_timers_callouts(#state {} = S, [Ranges, T]) ->
    ?CALLOUT(dht_routing_table, ranges, [?WILDCARD], current_ranges(S)),
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
init_nodes_callouts(_, [_Nodes, _T]) ->
    ?APPLY(dht_time_eqc, convert_time_unit, [?NODE_TIMEOUT, milli_seconds, native]).

%% We start out by making every node questionable, so the system will catch up to
%% the game imediately.
init_nodes_next(#state {} = S, _, [Nodes, T]) ->
    NodeTimers = [{N, T-?NODE_TIMEOUT, 0, false} || N <- lists:reverse(Nodes)],
    S#state { node_timers = NodeTimers }.

%% REMOVAL (Internal call)
%% --------------------------------------------------

%% Removing a node amounts to killing the node from the routing table
%% and also remove its timer structure.
%% TODO: Assert only bad nodes are removed because this is the rule of the system!
remove_pre(#state { node_timers = NTs }, [Node]) ->
    case lists:keyfind(Node, 1, NTs) of
        false -> false;
        {_, _, Errs, _} when Errs > 1 -> true;
        _ -> false
    end.

remove_callouts(_S, [Node]) ->
    ?CALLOUT(dht_routing_table, delete, [Node, ?WILDCARD], 'ROUTING_TABLE'),
    ?RET(ok).

remove_next(#state { tree = Tree, node_timers = NTs } = State, _, [Node]) ->
    State#state { tree = delete_node(Node, Tree), node_timers = lists:keydelete(Node, 1, NTs) }.

remove_features(_S, _A, _R) -> [{meta, remove}].

%% ADJOIN (Internal call)
%% --------------------------------------------------

%% Adjoin a new node to the routing table, tracking meta-data information as well
adjoin_callouts(#state {}, [Node]) ->
    ?MATCH(T, ?APPLY(dht_time_eqc, monotonic_time, [])),
    ?MATCH(Before, ?APPLY(obtain_ranges, [])),
    ?MATCH(HasSpace, ?CALLOUT(dht_routing_table, space, [Node, ?WILDCARD], bool() )),
    case HasSpace of
        true ->
            ?CALLOUT(dht_routing_table, insert, [Node, ?WILDCARD], 'ROUTING_TABLE'),
            ?CALLOUT(dht_routing_table, member_state, [Node, ?WILDCARD], member),
            ?APPLY(insert_node, [Node, T]),
            ?MATCH(After, ?APPLY(obtain_ranges, [])),
            Ops = lists:append(
                [{del, R} || R <- ordsets:subtract(Before, After)],
                [{add, R} || R <- ordsets:subtract(After, Before)]),
            ?APPLY(fold_ranges, [lists:sort(Ops)]),
            ?RET(ok);
        false ->
            ?RET(not_inserted)
    end.
    
adjoin_features(_S, _A, ok) -> [{meta, {adjoin, ok}}];
adjoin_features(_S, _A, not_inserted) -> [{meta, {adjoin, not_inserted}}].

obtain_ranges_callouts(S, []) ->
    ?MATCH(R, ?CALLOUT(dht_routing_table, ranges, [?WILDCARD], ?LET(Rs, current_ranges(S), lists:sort(Rs)))),
    ?RET(R).

fold_ranges_callouts(_S, [[]]) -> ?EMPTY;
fold_ranges_callouts(S, [[{del, R} | Ops]]) ->
    ?APPLY(remove_range_timer, [R]),
    fold_ranges_callouts(S, [Ops]);
fold_ranges_callouts(S, [[{add, R} | Ops]]) ->
    ?MATCH(Activity, ?APPLY(range_last_activity, [R])),
    ?APPLY(add_range_timer_at, [R, Activity]),
    fold_ranges_callouts(S, [Ops]).

insert_node_callouts(#state {}, [Node, T]) ->
    ?APPLY(split_range, [Node]),
    ?APPLY(insert_node_2, [Node]),
    ?APPLY(add_node_timer, [Node, T, true]).

insert_node_2_next(S, _, [Node]) ->
    { #{ nodes := Nodes } = R, Rs} = take_range(S, Node),
    NR = R#{ nodes := Nodes ++ [Node] },
    S#state{ tree = Rs ++ [NR] }.

%% SPLIT_RANGE (Model internal call)
%% ------------------------------

%% This call is used by the model to figure out if a range needs to split when
%% inserting a new node.
split_range_callouts(S, [Node]) ->
    { #{ split := Split, lo := Lo, hi := Hi, nodes := Nodes }, _Rs} = take_range(S, Node),
    case length(Nodes) +1 of
       L when L =< ?K ->
           ?EMPTY;
       L when L > ?K, Split ->
           Half = Lo + ((Hi - Lo) bsr 1),
           ?APPLY(perform_split, [Node, Half]),
           ?APPLY(split_range, [Node]);
       L when L > ?K, not Split ->
           ?EMPTY
    end.

split_range_features(_S, _A, _R) -> [{meta, split_range}].

%% PERFORM_SPLIT (Model Internal Call)
%% --------------------------------------------

%% Performing a split is a tool we use to actually split a range. The precondition is that
%% we can only split a range if our own node falls within it. And we track this by means
%% of a test on the `split` value of the range.
perform_split_callouts(#state {} = S, [Node, _P]) ->
    { #{ split := Split }, _Rs} = take_range(S, Node),
    case Split of
        true -> ?EMPTY;
        false -> ?FAIL(cannot_perform_split)
    end.

perform_split_next(#state { id = Own } = S, _, [Node, P]) ->
    F = fun({ID, _, _}) -> ID < P end,
    { #{ lo := L, hi := H, nodes := Nodes, split := Split }, Rs} = take_range(S, Node),
    Split = within(L, Own, H), %% Assert the state of the split
    case Split of
        true ->
            {LowNodes, HighNodes} = lists:partition(F, Nodes),
            Low = #{ lo => L, hi => P, nodes => LowNodes, split => within(L, Own, P) },
            High = #{ lo => P, hi => H, nodes => HighNodes, split => within(P, Own, H) },
            S#state { tree = Rs ++ [Low, High] };
        false ->
            S
    end.
    
take_range(#state { tree = Tree}, {ID, _, _}) -> take_range(Tree, ID, []).

take_range([R = #{ lo := Lo, hi := Hi} | Rs], ID, Acc) when Lo =< ID, ID =< Hi ->
    {R, rev_append(Acc, Rs)};
take_range([R | Rs], ID, Acc) -> take_range(Rs, ID, [R | Acc]).

rev_append([], Ls) -> Ls;
rev_append([S|Ss], Ls) -> rev_append(Ss, [S|Ls]).

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

add_range_timer_at_callouts(#state { }, [Range, At]) ->
    ?MATCH(T, ?APPLY(dht_time_eqc, monotonic_time, [])),
    Point = T - At,
    ?APPLY(dht_time_eqc, convert_time_unit, [Point, native, milli_seconds]),
    ?MATCH(Timer,
      ?APPLY(dht_time_eqc, send_after, [monus(?RANGE_TIMEOUT, Point), self(), {inactive_range, Range}])),
    ?APPLY(add_timer_for_range, [Range, Timer]).
    
add_timer_for_range_next(#state { range_timers = RT } = State, _, [Range, Timer]) ->
    State#state { range_timers = RT ++ [{Range, Timer}] }.
    
remove_range_timer_callouts(#state { range_timers = RT }, [Range]) ->
    case lists:keyfind(Range, 1, RT) of
        {Range, TRef} ->
            ?APPLY(dht_time_eqc, cancel_timer, [TRef]);
        false ->
            ?FAIL(remove_non_existing_range)
    end.
    
remove_range_timer_next(#state { range_timers = RT } = State, _, [Range]) ->
    State#state { range_timers = lists:keydelete(Range, 1, RT) }.

%% When updating node timers, we have the option of overriding the last activity point
%% of that node. The last activity point is passed as an extra parameter in this call.
%%
%% A node starts out with no errors and as being unreachable
add_node_timer_next(#state { node_timers = NT } = State, _, [Node, Activity, Reachable]) ->
    State#state {
        node_timers = NT ++ [{Node, Activity, 0, Reachable}]
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

%% Weighting
weight(_S, insert) -> 150;
weight(_S, _) -> 10.

%% Main property, just verify that the commands are in sync with reality.
prop_component_correct() ->
    ?SETUP(fun() ->
        eqc_mocking:start_mocking(api_spec()),
        fun() -> ok end
    end,
    ?FORALL(ID, dht_eqc:id(),
    ?FORALL(State, gen_state(ID),
    ?FORALL(Cmds, commands(?MODULE, State),
      begin
        {H,S,R} = run_commands(?MODULE, Cmds),
        pretty_commands(?MODULE, Cmds, {H,S,R},
            aggregate(with_title('Commands'), command_names(Cmds),
            collect(eqc_lib:summary('Length'), length(Cmds),
            aggregate(with_title('Features'), eqc_statem:call_features(H),
            features(eqc_statem:call_features(H),
                R == ok)))))
      end)))).

self(#state { id = ID }) -> ID.

%% Helper for showing states of the output:
t() -> t(5).

t(Secs) ->
    eqc:quickcheck(eqc:testing_time(Secs, eqc_statem:show_states(prop_component_correct()))).

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

%% TODO: Lessen this restriction so peers may have the same ID, but different IP-addresses,
%% or different IP-addresses, but the same ID.
has_peer(N, S) ->
    Nodes = current_nodes(S),
    lists:member(N, Nodes).

has_range(R, S) ->
    Rs = current_ranges(S),
    lists:member(R, Rs).

delete_node(_Node, []) -> [];
delete_node({ID, _, _} = Node, [#{ lo := Lo, hi := Hi, nodes := Nodes } = R | Rs]) when Lo =< ID, ID =< Hi ->
    NewNodes = Nodes -- [Node],
    [R#{ nodes := NewNodes } | Rs];
delete_node(Node, [R | Rs]) ->
    [R | delete_node(Node, Rs)].

%% You can request nodes in a range by either querying on the range or by the node (ID)
%% One returns the nodes neighboring the ID or that particular range, which must exist.
nodes_in_range(#state { tree = Tree }, {L, H}) ->
    %% This MUST return exactly one target, or the Tree is broken
    case [Nodes || #{ lo := Lo, hi := Hi, nodes := Nodes } <- Tree, Lo == L, Hi == H] of
        [Ns] -> Ns;
        _ -> error
    end;
nodes_in_range(#state { tree = Tree }, ID) ->
    %% This MUST return exactly one target, or the Tree is broken
    case [Nodes || #{ lo := Lo, hi := Hi, nodes := Nodes } <- Tree, Lo =< ID, ID < Hi] of
        [Ns] -> Ns;
        _ -> error
    end.

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


%% Various helpers
%% --------------------

%% A monus operation is a subtraction for natural numbers
monus(A, B) when A > B -> A - B;
monus(A, B) when A =< B -> 0.

%% Pick a random element
rand_pick([]) -> [];
rand_pick(Elems) -> elements(Elems).

%% Remove duplicates in a list through the use of a map()
dedup(Xs) ->
    dedup(Xs, #{}).
    
dedup([], _) -> [];
dedup([X | Xs], M) ->
    case maps:get(X, M, false) of
        true -> dedup(Xs, M);
        false -> [X | dedup(Xs, M#{ X => true })]
    end.

%% within(L, X, H) checks that L ≤ X < H
within(L, X, H) when L =< X, X < H -> true;
within(_, _, _) -> false.
