%% @doc Wrap a routing table in timer constructs
%%
%% This module implements a "wrapper" around the routing table code, by adding
%% timer tables for nodes and ranges. The module provides several functions
%% which are used to manipulate not only the routing table, but also the timers
%% for the routing table. The invariant is, roughly, that any node/range in the table
%% has a timer.
%%
%% The module also provides a number of query-facilities for the policy module
%% (dht_state) to query the internal timer state when a timer triggers.
%%
%% Global TODO:
%%
%% · Rework the EQC model, since it is now in tatters.
%%% @end
%%% @private
-module(dht_routing_meta).
-include("dht_constants.hrl").

%% Create/Export
-export([new/1]).
-export([export/1]).

%% Manipulate the routing table and meta-data
-export([
	insert/2,
	replace/3,
	remove/2,
	node_touch/3,
	node_timeout/2,
	reset_range_timer/3
]).

%% Query the state of the routing table and its meta-data
-export([
	member_state/2,
	neighbors/3,
	node_list/1,
	node_state/2,
	range_members/2,
	range_state/2
]).

-record(routing, {
    table,
    nodes = #{},
    ranges = #{}
}).

-type node_state() :: good | {questionable, integer()} | bad.
-export_type([node_state/0]).

%% API
%% ------------------------------------------------------
new(Tbl) ->
    Now = dht_time:monotonic_time(),
    Nodes = dht_routing_table:node_list(Tbl),
    ID = dht_routing_table:node_id(Tbl),
    RangeTable = init_range_timers(Now, Tbl),
    NodeTable = init_nodes(Now, Nodes),
    State = #routing {
        table = Tbl,
        ranges = RangeTable,
        nodes = NodeTable
    },
    {ok, ID, State}.

member_state(Node, #routing { table = T }) -> dht_routing_table:member_state(Node, T).
range_members({_, _, _} = Node, #routing { table = T }) -> dht_routing_table:members({node, Node}, T);
range_members({_, _} = Range, #routing { table = T }) -> dht_routing_table:members({range, Range}, T).

%% @doc replace/3 substitutes one bad node for a new node
%% Preconditions:
%% • The removed node MUST be bad.
%% • The added node MUST NOT be a member.
%% @end
-spec replace(Old, New, Meta) -> not_inserted | roaming_member | {error, Reason} | {ok, Meta}
    when
      Old :: dht:peer(),
      New :: dht:peer(),
      Meta :: #routing{},
      Reason :: atom().

replace(Old, New, #routing { nodes = Ns, table = Tbl } = State) ->
    bad = timer_state({node, Old}, Ns),
    case member_state(New, State) of
        unknown ->
            Deleted = State#routing {
              table = dht_routing_table:delete(Old, Tbl),
              nodes = maps:remove(Old, Ns)
            },
            insert(New, Deleted);
        roaming_member ->
            roaming_member;
        member ->
            {error, member}
    end.
    
%% @doc insert/2 inserts a new node in the routing table
%% Precondition: The node inserted is not a member
%% Postcondition: The inserted node is now a member
%% @end
-spec insert(Node, #routing{}) -> {ok, #routing{}} | not_inserted
	when Node :: dht:peer().
insert(Node, #routing { table = Tbl, nodes = NT } = Routing) ->
    Now = dht_time:monotonic_time(),
    PrevRanges = dht_routing_table:ranges(Tbl),
    case dht_routing_table:space(Node, Tbl) of
        false -> not_inserted;
        true ->
            NextTbl = dht_routing_table:insert(Node, Tbl),
            member = dht_routing_table:member_state(Node, NextTbl),
            NewState = Routing#routing {
                    	table = NextTbl,
                    	nodes = node_update({reachable, Node}, Now, NT) },
            {ok, update_ranges(PrevRanges, Now, NewState)}
    end.

%% @doc remove/2 removes a node from the routing table
%% @end
remove(Node, #routing { table = Tbl, nodes = NT} = State) ->
    bad = timer_state({node, Node}, NT),
    State#routing {
        table = dht_routing_table:delete(Node, Tbl),
        nodes = maps:remove(Node, NT)
    }.

%% @doc node_touch/3 marks recent communication with a node
%% We pass `#{ reachable => true/false }' to signify if the touch was part of a reachable
%% communication. That is, if we know for sure the peer node is reachable.
%% @end
-spec node_touch(Node, Opts, Routing) -> Routing
  when
    Node :: dht:peer(),
    Opts :: #{ atom() => boolean() },
    Routing :: #routing{}.

node_touch(Node, #{ reachable := true }, #routing { nodes = NT} = Routing) ->
    Routing#routing { nodes = node_update({reachable, Node}, dht_time:monotonic_time(), NT) };
node_touch(Node, #{ reachable := false }, #routing { nodes = NT } = Routing) ->
    Routing#routing { nodes = node_update({unreachable, Node}, dht_time:monotonic_time(), NT) }.

%% @doc node_timeout/2 marks a Node communication as timed out
%% Tracks the flakiness of a peer. If this is called too many times, then the peer/node
%% enters the 'bad' state.
%% @end
node_timeout(Node, #routing { nodes = NT } = Routing) ->
    #{ timeout_count := TC } = State = maps:get(Node, NT),
    NewState = State#{ timeout_count := TC + 1 },
    Routing#routing { nodes = maps:update(Node, NewState, NT) }.

%% @doc node_list/1 returns the currently known nodes in the routing table.
%% @end
-spec node_list(#routing{}) -> [dht:peer()].
node_list(#routing { table = Tbl }) -> dht_routing_table:node_list(Tbl).

%% @doc node_state/2 computes the state of a node list
%% @end
-spec node_state([Peer], Routing) -> [{Peer, node_state()}]
  when Peer :: dht:peer(), Routing :: #routing{}.

node_state(Nodes, #routing { nodes = NT }) ->
    [{N, timer_state({node, N}, NT)} || N <- Nodes].

range_state(Range, #routing{ table = Tbl } = Routing) ->
    case dht_routing_table:is_range(Range, Tbl) of
        false -> {error, not_member};
        true ->
            range_state_members(range_members(Range, Routing), Routing)
   end.
   
reset_range_timer(Range, #{ force := Force },
	#routing { ranges = RT, nodes = Nodes, table = Tbl } = Routing) ->
    TS =
       case Force of
           false -> range_last_activity(Range, Nodes, Tbl);
           true -> dht_time:monotonic_time()
       end,

    %% Update the range timer to the oldest member
    TmpR = timer_delete(Range, RT),
    RTRef = mk_timer(TS, ?RANGE_TIMEOUT, {inactive_range, Range}),
    NewRT = range_timer_add(Range, TS, RTRef, TmpR),
    
    Routing#routing { ranges = NewRT }.

%% @doc export/1 returns the underlying routing table as an Erlang term
%% Note: We DON'T store the timers in between invocations. This decision
%% effectively makes the DHT system Time Warp capable
%% @end
export(#routing { table = Tbl }) -> Tbl.

%% @doc neighbors/3 returns up to K neighbors around an ID
%% The search returns a list of nodes, where the nodes toward the head
%% are good nodes, and nodes further down are questionable nodes.
%% @end
neighbors(ID, K, #routing { table = Tbl } = Routing) ->
    Nodes = dht_routing_table:closest_to(ID, Tbl),
    States = node_state(Nodes, Routing),
    {Good, QBNodes} = lists:partition(
      fun({_, S}) -> S == good end, States),
    case take(K, Good) of
        L when length(L) == K -> [N || {N, _} <- L];
        L when length(L) < K ->
            Remaining = K - length(L),
            {Questionable, _} = lists:partition(
              fun
                ({_, {questionable, _}}) -> true;
                (_) -> false
              end,
              QBNodes),
             [N || {N, _} <- L ++ take(Remaining, Questionable)]
    end.

%% INTERNAL FUNCTIONS
%% ------------------------------------------------------

take(0, _) -> [];
take(_, []) -> [];
take(K, [X|Xs]) when K > 0 -> [X | take(K-1, Xs)].

range_state_members(Members, Routing) ->
    T = dht_time:monotonic_time(),
    case last_activity(Members, Routing) of
        never -> empty;
        A when A =< T ->
            Window = dht_time:convert_time_unit(T - A, native, milli_seconds),
            case Window =< ?RANGE_TIMEOUT of
                true -> ok;
                false -> {needs_refresh, dht_rand:pick([ID || {ID, _, _} <- Members])}
            end
    end.


%% Insertion may invoke splitting of ranges. If this happens, we need to
%% update the timers for ranges: The old range gets removed. The new
%% ranges gets added.
update_ranges(PrevRanges, Now, #routing { ranges = Ranges, nodes = NT, table = NewTbl } = State) ->
    NewRanges = dht_routing_table:ranges(NewTbl),
    Operations = lists:append(
        [{del, R} || R <- ordsets:subtract(PrevRanges, NewRanges)],
        [{add, R} || R <- ordsets:subtract(NewRanges, PrevRanges)]),
    State#routing { ranges = fold_ranges(lists:sort(Operations), Now, NT, Ranges, NewTbl) }.
    
%% Carry out a sequence of operations over the ranges in a fold.
fold_ranges([{del, R} | Ops], Now, Nodes, Ranges, Tbl) ->
    fold_ranges(Ops, Now, Nodes, timer_delete(R, Ranges), Tbl);
fold_ranges([{add, R} | Ops], Now, Nodes, Ranges, Tbl) ->
    Recent = range_last_activity(R, Nodes, Tbl),
    TRef = mk_timer(Recent, ?RANGE_TIMEOUT, {inactive_range, R}),
    fold_ranges(Ops, Now, Nodes, range_timer_add(R, Now, TRef, Ranges), Tbl);
fold_ranges([], _Now, _Nodes, Ranges, _Tbl) -> Ranges.

%% Find the oldest member in the range and use that as the last activity
%% point for the range.
range_last_activity(Range, Nodes, Tbl) ->
    Members = dht_routing_table:members({range, Range}, Tbl),
    timer_newest(Members, Nodes).

last_activity(Members, #routing { nodes = NTs } ) ->
    NodeTimers = [maps:get(M, NTs) || M <- Members],
    Changed = [LA || #{ last_activity := LA } <- NodeTimers],
    case Changed of
        [] -> never;
        Cs -> lists:max(Cs)
    end.

init_range_timers(Now, Tbl) ->
    Ranges = dht_routing_table:ranges(Tbl),
    F = fun(R, Acc) ->
        Ref = mk_timer(Now, ?RANGE_TIMEOUT, {inactive_range, R}),
        range_timer_add(R, Now, Ref, Acc)
    end,
    lists:foldl(F, #{}, Ranges).

init_nodes(Now, Nodes) ->
    Timeout = dht_time:convert_time_unit(?NODE_TIMEOUT, milli_seconds, native),
    F = fun(N) -> {N, #{ last_activity => Now - Timeout, timeout_count => 0, reachable => false }} end,
    maps:from_list([F(N) || N <- Nodes]).


timer_delete(Item, Timers) ->
    #{ timer_ref := TRef } = V = maps:get(Item, Timers),
    _ = dht_time:cancel_timer(TRef),
    maps:update(Item, V#{ timer_ref := undefined }, Timers).

node_update({reachable, Item}, Activity, Timers) ->
    Timers#{ Item => #{ last_activity => Activity, timeout_count => 0, reachable => true }};
node_update({unreachable, Item}, Activity, Timers) ->
    case maps:get(Item, Timers) of
        M = #{ reachable := true } ->
            Timers#{ Item => M#{ last_activity => Activity, timeout_count => 0, reachable := true }};
        #{ reachable := false } ->
            Timers
    end.

range_timer_add(Item, ActivityTime, TRef, Timers) ->
    Timers#{ Item => #{ last_activity => ActivityTime, timer_ref => TRef} }.

timer_newest([], _) -> dht_time:monotonic_time(); % None available
timer_newest(Items, Timers) ->
    Activities = [maps:get(K, Timers) || K <- Items],
    lists:max([A || #{ last_activity := A } <- Activities]).

%% monus/2 is defined on integers in the obvious way (look up the Wikipedia article)
monus(A, B) when A > B -> A - B;
monus(A, B) when A =< B-> 0.

%% Age returns the time since a point in time T.
%% The age function is not time-warp resistant.
age(T) ->
    Now = dht_time:monotonic_time(),
    age(T, Now).
    
%% Return the age compared to the current point in time
age(T, Now) when T =< Now ->
    dht_time:convert_time_unit(Now - T, native, milli_seconds);
age(T, Now) when T > Now ->
    exit(time_warp_future).

%% mk_timer/3 creates a new timer based on starting-point and an interval
%% Given `Start', the point in time when the timer should start, and an interval,
%% construct a timer that triggers at the end of the Start+Interval window.
%%
%% Start is in native time scale, Interval is in milli_seconds.
mk_timer(Start, Interval, Msg) ->
    Age = age(Start),
    dht_time:send_after(monus(Interval, Age), self(), Msg).
    
%% @doc timer_state/2 returns the state of a timer, based on BitTorrent Enhancement Proposal 5
%% @end
-spec timer_state({node, N} | {range, R}, Timers) ->
    good | {questionable, non_neg_integer()} | bad
	when
	  N :: dht:peer(),
	  R :: dht:range(),
	  Timers :: maps:map().
    
timer_state({node, N}, NTs) ->
    case maps:get(N, NTs, undefined) of
        #{ timeout_count := K } when K > 1 -> bad;
        #{ last_activity := LA } ->
            Age = age(LA),
            case Age < ?NODE_TIMEOUT of
              true -> good;
              false -> {questionable, LA}
            end
    end.

