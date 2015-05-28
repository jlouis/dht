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
-module(dht_routing_meta).

-export([new/1]).
-export([export/1]).

-export([
	active/3,
	can_insert/2,
	inactive/3,
	insert/2,
	is_member/2,
	neighbors/3,
	node_list/1,
	node_timer_state/2,
	node_timeout/2,
	range_members/2,
	range_state/2,
	range_timer_state/2,
	refresh_node/2,
	refresh_range/2,
	refresh_range_by_node/2
]).

%
% The bucket refresh timeout is the amount of time that the
% server will tolerate a node to be disconnected before it
% attempts to refresh the bucket.
%
-define(RANGE_TIMEOUT, 15 * 60 * 1000).
-define(NODE_TIMEOUT, 15 * 60 * 1000).

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
    RangeTable = init_range_timers(Now, Tbl),
    NodeTable = init_nodes(Now, Nodes),
    State = #routing {
        table = Tbl,
        ranges = RangeTable,
        nodes = NodeTable
    },
    {ok, ID, State}.

is_member(Node, #routing { table = T }) -> dht_routing_table:is_member(Node, T).
range_members(Node, #routing { table = T }) -> dht_routing_table:members(Node, T).

can_insert(Node, #routing { table = Tbl }) ->
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
        NewState = Routing#routing { nodes = node_update(Node, Now, NT) },
        {ok, update_ranges(Tbl, Now, NewState)}
    end.

update_ranges(OldTbl, Now, #routing { table = NewTbl } = State) ->
    PrevRanges = dht_routing_table:ranges(OldTbl),
    NewRanges = dht_routing_table:ranges(NewTbl),
    Operations = lists:append(
        [{del, R} || R <- ordsets:subtract(PrevRanges, NewRanges)],
        [{add, R} || R <- ordsets:subtract(NewRanges, PrevRanges)]),
    fold_update_ranges(Operations, Now, State).
    
fold_update_ranges(Ops, Now, #routing { ranges = RT } = Routing) ->
    F = fun
        ({del, R}, TM) -> timer_delete(R, TM);
        ({add, R}, TM) ->
            Recent = range_last_activity(R, Routing),
            TRef = mk_timer(Recent, ?RANGE_TIMEOUT, {inactive_range, R}),
            range_timer_add(R, Now, TRef, TM)
    end,
    Routing#routing { ranges = lists:foldl(F, RT, Ops) }.

%% @doc remove/2 removes a node from the routing table (and deletes the associated timer structure)
%% @end
remove(Node, #routing { table = Tbl, nodes = NT} = State) ->
    State#routing {
        table = dht_routing_table:delete(Node, Tbl),
        nodes = maps:remove(Node, NT)
    }.

refresh_node(Node, #routing { nodes = NT} = Routing) ->
    Routing#routing { nodes = node_update(Node, dht_time:monotonic_time(), NT)}.

refresh_range_by_node({ID, _, _}, #routing { table = Tbl, ranges = RT } = Routing) ->
    Range = dht_routing_table:range(ID, Tbl),
    #{ last_activity := RActive } = maps:get(Range, RT),
    refresh_range(Range, RActive, Routing).

refresh_range(Range, Routing) ->
    MostRecent = range_last_activity(Range, Routing),
    refresh_range(Range, MostRecent, Routing).

refresh_range(Range, MostRecent, #routing { ranges = RT } = Routing) ->
    %% Update the range timer to the oldest member
    TmpR = timer_delete(Range, RT),
    RTRef = mk_timer(MostRecent, ?RANGE_TIMEOUT, {inactive_range, Range}),
    NewRT = range_timer_add(Range, MostRecent, RTRef, TmpR),
    %% Insert the new data
    Routing#routing { ranges = NewRT}.

node_timeout(Node, #routing { nodes = NT } = Routing) ->
    #{ timeout_count := TC } = State = maps:get(Node, NT),
    NewState = State#{ timeout_count := TC + 1 },
    Routing#routing { nodes = maps:update(Node, NewState, NT) }.

node_timer_state(Node, #routing { nodes = NT} = S) ->
    case is_member(Node, S) of
        false -> not_member;
        true -> timer_state({node, Node}, NT)
    end.

range_timer_state(Range, #routing { table = Tbl, ranges = RT}) ->
    case dht_routing_table:is_range(Range, Tbl) of
        false -> not_member;
        true -> timer_state({range, Range}, RT)
    end.

range_state(Range, #routing { table = Tbl } = Routing) ->
    Members = dht_routing_table:members(Range, Tbl),
    Active = active(Members, nodes, Routing),
    Inactive = inactive(Members, nodes, Routing),
    #{ active => Active, inactive => Inactive }.

export(#routing { table = Tbl }) -> Tbl.

node_list(#routing { table = Tbl }) -> dht_routing_table:node_list(Tbl).

%% @doc neighbors/3 returns up to K neighbors around an ID
%% The search returns a list of nodes, where the nodes toward the head
%% are good nodes, and nodes further down are questionable nodes.
%% @end
neighbors(ID, K, #routing { table = Tbl, nodes = NT }) ->
    GoodFilter = fun(N) -> timer_state({node, N}, NT) =:= good end,
    QuestionableFilter = fun
        (N) ->
            case timer_state({node, N}, NT) of
                {questionable, _} -> true;
                _ -> false
            end
    end,
    case dht_routing_table:closest_to(ID, GoodFilter, K, Tbl) of
        L when length(L) == K -> L;
        L -> L ++ dht_routing_table:closest_to(
        			ID, QuestionableFilter, K-length(L), Tbl)
    end.

inactive(Nodes, nodes, #routing { nodes = Timers }) ->
    [N || N <- Nodes, timer_state({node, N}, Timers) /= good].

active(Nodes, nodes, #routing { nodes = Timers }) ->
    [N || N <- Nodes, timer_state({node, N}, Timers) =:= good].
    
%% INTERNAL FUNCTIONS
%% ------------------------------------------------------

%% Find the oldest member in the range and use that as the last activity
%% point for the range.
range_last_activity(Range, #routing { table = Tbl, nodes = NT }) ->
    Members = dht_routing_table:members(Range, Tbl),
    timer_oldest(Members, NT).

init_range_timers(Now, Tbl) ->
    Ranges = dht_routing_table:ranges(Tbl),
    F = fun(R, Acc) ->
        Ref = mk_timer(Now, ?RANGE_TIMEOUT, {inactive_range, R}),
        range_timer_add(R, Now, Ref, Acc)
    end,
    lists:foldl(F, #{}, Ranges).

init_nodes(Now, Nodes) ->
    Timeout = dht_time:convert_time_unit(?NODE_TIMEOUT, milli_seconds, native),
    F = fun(N) -> {N, #{ last_activity => Now - Timeout, timeout_count => 0 }} end,
    maps:from_list([F(N) || N <- Nodes]).


timer_delete(Item, Timers) ->
    #{ timer_ref := TRef } = V = maps:get(Item, Timers),
    _ = dht_time:cancel_timer(TRef),
    maps:update(Item, V#{ timer_ref := undefined }, Timers).

node_update(Item, Activity, Timers) ->
    Timers#{ Item => #{ last_activity => Activity, timeout_count => 0 }}.

range_timer_add(Item, ActivityTime, TRef, Timers) ->
    Timers#{ Item => #{ last_activity => ActivityTime, timer_ref => TRef} }.

timer_oldest([], _) -> dht_time:monotonic_time(); % None available
timer_oldest(Items, Timers) ->
    Activities = [maps:get(K, Timers) || K <- Items],
    lists:min([A || #{ last_activity := A } <- Activities]).

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
        #{ timeout_count := K } when K > 2 -> bad;
        #{ last_activity := LA } ->
            Age = age(LA),
            case Age < ?NODE_TIMEOUT of
              true -> good;
              false -> {questionable, Age - ?NODE_TIMEOUT}
            end
    end;
timer_state({range, R}, RTs) ->
    #{ last_activity := MR } = maps:get(R, RTs),
    Age = age(MR),
    case Age < ?RANGE_TIMEOUT of
        true -> ok;
        false -> need_refresh
    end.

