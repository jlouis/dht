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

-module(dht_routing).

-export([new/1]).
-export([export/1]).

-export([
	inactive/3,
	insert/2,
	is_member/2,
	neighbors/3,
	node_list/1,
	node_timer_state/2,
	range_members/2,
	range_state/2,
	range_timer_state/2,
	refresh_node/2,
	refresh_range/3,
	refresh_range_by_node/2,
	try_insert/2
]).


%
% The bucket refresh timeout is the amount of time that the
% server will tolerate a node to be disconnected before it
% attempts to refresh the bucket.
%
-define(RANGE_TIMEOUT, 5 * 60 * 1000).
-define(NODE_TIMEOUT, 10 * 60 * 1000).

-record(routing, {
    table,
    nodes = #{},
    ranges = #{}
}).

%% API
%% ------------------------------------------------------
new(Tbl) ->
    Now = dht_time:monotonic_time(),
    Nodes = dht_routing_table:node_list(Tbl),
    ID = dht_routing_table:node_id(Tbl),
    F = fun(Node, S1) -> {_, S2} = insert(Node, S1), S2 end,
    State = #routing {
        table = Tbl,
        ranges = {?RANGE_TIMEOUT, init_range_timers(Now, Tbl)}
    },
    {ok, ID, lists:foldl(F, State, Nodes)}.

is_member(Node, #routing { table = T }) -> dht_routing_table:is_member(Node, T).
range_members(Node, #routing { table = T }) -> dht_routing_table:members(Node, T).

try_insert(Node, #routing { table = Tbl }) ->
    Tbl2 = dht_routing_table:insert(Node, Tbl),
    dht_routing_table:is_member(Node, Tbl2).

%% @doc insert/2 inserts a new node in the routing table
%% @end
insert(Node, #routing { table = Tbl } = State) ->
    case dht_routing_table:is_member(Node, Tbl) of
        true -> {already_member, State};
        false ->
            Neighbours = dht_routing_table:members(Node, Tbl),
            case inactive(Neighbours, nodes, State) of
              [] -> adjoin(Node, State);
              [Old | _] ->
                Removed = remove(Old, State),
                adjoin(Node, Removed)
            end
    end.

%% @doc adjoin/2 adjoins a new node to the routing table
%% @end
adjoin(Node, #routing { table = Tbl, nodes = NT } = Routing) ->
    Now = dht_time:monotonic_time(),
    T = dht_routing_table:insert(Node, Tbl),
    case dht_routing_table:is_member(Node, T) of
      false ->
        {not_inserted, Routing#routing { table = T }};
      true ->
        %% Update the timers, if they need to change
        TimerRef = node_timer_from(Now, ?NODE_TIMEOUT, NT),
        NewState = Routing#routing { nodes = NT#{ Node => {Now, TimerRef} } },
        {ok, update_ranges(Tbl, Now, NewState)}
    end.

update_ranges(OldTbl, Now, #routing { table = NewTbl } = State) ->
    PrevRanges = dht_routing_table:ranges(OldTbl),
    NewRanges = dht_routing_table:ranges(NewTbl),
    Operations = [{del, R} || R <- ordsets:subtract(PrevRanges, NewRanges)]
    	++ [{add, R} || R <- ordsets:subtract(NewRanges, PrevRanges)],
    fold_update_ranges(Operations, Now, State).
    
fold_update_ranges(Ops, Now,
	#routing {
		nodes = {_, NT},
		ranges = {?RANGE_TIMEOUT, RT},
		table = Tbl
	} = Routing) ->
    F = fun
        ({del, R}, TM) -> timer_delete(R, TM);
        ({add, R}, TM) ->
            Members = dht_routing_table:members(R, Tbl),
            Recent = timer_oldest(Members, NT),
            TRef = range_timer_from(Now, ?RANGE_TIMEOUT, Recent, NT, R),
            timer_add(R, Now, TRef, TM)
    end,
    Routing#routing { ranges = {?RANGE_TIMEOUT, lists:foldl(F, RT, Ops)} }.

%% @doc remove/2 removes a node from the routing table (and deletes the associated timer structure)
%% @end
remove(Node, #routing { table = Tbl, nodes = NT} = State) ->
    State#routing {
        table = dht_routing_table:delete(Node, Tbl),
        nodes = timer_delete(Node, NT)
    }.

refresh_node(Node, #routing { nodes = NT} = Routing) ->
    Now = dht_time:monotonic_time(),
    {LastActive, _} = maps:get(Node, NT),
    T = maps:remove(Node, NT),
    TRef = node_timer_from(Now, ?NODE_TIMEOUT, Node),
    Routing#routing { nodes = timer_add(Node, LastActive, TRef, T)}.

refresh_range_by_node({ID, _, _}, #routing { table = Tbl, ranges = {_, RT} } = Routing) ->
    Range = dht_routing_table:range(ID, Tbl),
    {RActive, _} = maps:get(Range, RT),
    refresh_range(Range, RActive, Routing).

refresh_range(Range, Timepoint,
	#routing {
	    table = Tbl,
	    nodes = NT,
	    ranges = RT} = Routing) ->
    %% Find oldest member in the range
    Members = dht_routing_table:members(Range, Tbl),
    LRecent = timer_oldest(Members, NT),
    
    %% Update the range timer to the oldest member
    TmpR = maps:remove(Range, RT),
    RTRef = range_timer_from(Timepoint, ?RANGE_TIMEOUT, LRecent, ?NODE_TIMEOUT, Range),
    NewRT = timer_add(Range, Timepoint, RTRef, TmpR),
    %% Insert the new data
    Routing#routing { ranges = {?RANGE_TIMEOUT, NewRT}}.

node_timer_state(Node, #routing { table = Tbl, nodes = NT}) ->
    case dht_routing_table:is_member(Node, Tbl) of
        false -> not_member;
        true -> timer_state(Node, ?NODE_TIMEOUT, NT)
    end.

range_timer_state(Range, #routing { table = Tbl, ranges = RT}) ->
    case dht_routing_table:is_range(Range, Tbl) of
        false -> not_member;
        true -> timer_state(Range, ?RANGE_TIMEOUT, RT)
    end.

range_state(Range, #routing { table = Tbl } = Routing) ->
    Members = dht_routing_table:members(Range, Tbl),
    #{
      active => active(Members, nodes, Routing),
      inactive => inactive(Members, nodes, Routing)
    }.

export(#routing { table = Tbl }) -> Tbl.

node_list(#routing { table = Tbl }) -> dht_routing_table:node_list(Tbl).

neighbors(ID, K, #routing { table = Tbl, nodes = NT }) ->
    Filter = fun(Node) -> not timeout(Node, ?NODE_TIMEOUT, NT) end,
    dht_routing_table:closest_to(ID, Filter, K, Tbl).

inactive(Nodes, nodes, #routing { nodes = Timing }) ->
    [N || N <- Nodes, timed_out(N, Timing)].
    
%% INTERNAL FUNCTIONS
%% ------------------------------------------------------

timer_state(X, Timeout, Table) ->
    {_, TRef} = maps:get(X, Table),
    case erlang:read_timer(TRef) == false of
       true -> canceled;
       false ->
           case timeout(X, Timeout, Table) of
               true -> timeout;
               false -> ok
           end
    end.

init_range_timers(Now, Tbl) ->
    Ranges = dht_routing_table:ranges(Tbl),
    F = fun(R, Acc) ->
        TRef = range_timer_from(Now, ?NODE_TIMEOUT, Now, ?RANGE_TIMEOUT, R),
        timer_add(R, Now, TRef, Acc)
    end,
    lists:foldl(F, #{}, Ranges).

active(Nodes, nodes, #routing { nodes = Timing }) ->
    [N || N <- Nodes, not timed_out(N, Timing)].

timed_out(Item, {Timeout, Timers}) ->
    {LastActive, _} = maps:get(Item, Timers),
    ms_since(LastActive) > Timeout.

ms_since(Time) ->
    Point = dht_time:monotonic_time(),
    dht_time:convert_time_unit(Point - Time, native, milli_seconds).

timer_delete(Item, Timers) ->
    {_, TRef} = maps:get(Item, Timers),
    _ = erlang:cancel_timer(TRef),
    maps:remove(Item, Timers).

timer_add(Item, ATime, TRef, Timers) ->
    Timers#{ Item => {ATime, TRef} }.

timer_oldest([], _) -> dht_time:monotonic_time(); % None available
timer_oldest(Items, Timers) ->
    lists:min([element(1, maps:get(K, Timers)) || K <- Items]).

timer_from(Time, Timeout, Msg) ->
    Interval = ms_between(Time, Timeout),
    dht_time:send_after(Interval, self(), Msg).

%% In the best case, the bucket should time out N seconds
%% after the first node in the bucket timed out. If that node
%% can't be replaced, a bucket refresh should be performed
%% at most every N seconds, based on when the bucket was last
%% marked as active, instead of _constantly_.
range_timer_from(Time, BTimeout, LeastRecent, _, Range) when LeastRecent < Time ->
    timer_from(Time, BTimeout, {inactive_range, Range});
range_timer_from(Time, _BTimeout, LeastRecent, Timeout, Range)
	when LeastRecent >= Time ->
    timer_from(LeastRecent, 2*Timeout, {inactive_range, Range}).

node_timer_from(Time, Timeout, Node) ->
    Msg = {inactive_node, Node},
    timer_from(Time, Timeout, Msg).

ms_between(Time, Timeout) ->
    case Timeout - ms_since(Time) of
      MS when MS =< 0 -> Timeout; %% @todo Consider if this should really be 0!
      MS -> MS
    end.

timeout(Item, Timeout, TimerTree) ->
    {LastActive, _} = maps:get(Item, TimerTree),
    ms_since(LastActive) > Timeout.

