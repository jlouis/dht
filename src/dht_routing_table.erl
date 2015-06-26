%% @author Magnus Klaar <magnus.klaar@sgsstudentbostader.se>
%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%% @doc module dht_routing_table maintains a Kademlia routing table
%%
%% This module implements a server maintaining the
%% DHT routing table. The nodes in the routing table
%% is distributed across a set of buckets. The bucket
%% set is created incrementally based on the local node id.
%%
%% The set of buckets, id ranges, is used to limit
%% the number of nodes in the routing table. The routing
%% table must only contain ?K nodes that fall within the
%% range of each bucket.
%%
%% @end
-module(dht_routing_table).
-include("dht_constants.hrl").

-export([new/1, new/3]).
-export([
	delete/2,
	insert/2
]).

%% Query
-export([
	closest_to/2,
	member_state/2,
	is_range/2,
	members/2,
	node_id/1,
	node_list/1,
	ranges/1,
	space/2
]).

-define(in_range(Dist, Min, Max), ((Dist >= Min) andalso (Dist < Max))).

-record(bucket, {
	low :: dht:id(),
	high :: dht:id(),
	members :: [dht:peer()]
}).

-record(routing_table, {
	self :: dht:id(),
	table :: [#bucket{}]
}).
-type t() :: #routing_table{}.
-export_type([t/0]).

%%
%% Create a new bucket list
%%
-spec new(dht:id()) -> t().
new(Self) -> new(Self, ?MIN_ID, ?MAX_ID).

new(Self, Lo, Hi) when is_integer(Self), Self >= 0 ->
    #routing_table {
       self = Self,
       table = [#bucket { low = Lo, high = Hi, members = [] }]
    }.

-spec node_id(t()) -> dht:id().
node_id(#routing_table { self = ID }) -> ID.

%%
%% Space - determine if there is space for a node
%%
-spec space(dht:peer(), t()) -> boolean().
space(N, T) ->
    TestTable = insert(N, T),
    case member_state(N, TestTable) of
        unknown -> false;
        member -> true
    end.

%%
%% Insert a new node into a bucket list
%%
%% TODO: Insertion should also provide evidence for what happened to buckets/ranges.
%%
-spec insert(dht:peer(), t()) -> t().
insert(Node, #routing_table { self = Self, table = Table} = Tbl) ->
    Tbl#routing_table { table = insert_node(Self, Node, Table) }.

%% The recursive runner for insertion
insert_node(Self, {ID, _, _} = Node, [#bucket{ low = Min, high = Max, members = Members} = B | Next])
	when ?in_range(ID, Min, Max) ->
    %% We analyze the numbers of members and either insert or split the bucket
    case length(Members) of
          L when L < ?MAX_RANGE_SZ -> [B#bucket { members = ordsets:add_element(Node, Members) } | Next];
          L when L == ?MAX_RANGE_SZ ->
              case ?in_range(Self, Min, Max) of
                  true -> insert_node(Self, Node, insert_split_bucket(B) ++ Next);
                  false -> [B | Next]
              end
    end;
insert_node(Self, Node, [H|T]) -> [H | insert_node(Self, Node, T)].

insert_split_bucket(#bucket{ low = Min, high = Max, members = Members }) ->
    Diff = Max - Min,
    Half = Max - (Diff div 2),
    F = fun({MID, _, _}) -> ?in_range(MID, Min, Half) end,
    {Lower, Upper} = lists:partition(F, Members),
    [#bucket{ low = Min, high = Half, members = Lower },
     #bucket{ low = Half, high = Max, members = Upper }].

%% Get all ranges present in a bucket list
%%
-spec ranges(t()) -> list({dht:id(), dht:id()}).
ranges(#routing_table { table = Entries }) ->
    lists:sort([{Min, Max} || #bucket{ low = Min, high = Max } <- Entries]).

%%
%% Delete a node from a bucket list
%%
-spec delete(dht:peer(), t()) -> t().
delete(Node, #routing_table { table = Table} = Tbl) ->
    Tbl#routing_table { table = delete_node(Node, Table) }.

delete_node({ID, _, _} = Node, [#bucket { low = Min, high = Max, members = Members } = B|T])
	when ?in_range(ID, Min, Max) ->
    [B#bucket { members = ordsets:del_element(Node, Members) }|T];
delete_node(Node, [H|T]) -> [H | delete_node(Node, T)];
delete_node(_, []) -> [].

%%
%% Return all members of the bucket that this node is a member of
%%
%% TODO: Figure out why we are using the metric here as well.
%% TODO: Call as members({range, Min, Max} | {node, Node}) to make search explicit.
-spec members({range, Range} | {node, Node}, t()) -> [Node]
	when
	  Node :: dht:peer(),
	  Range :: dht:range().
members({range, {Min, Max}}, #routing_table { table = Table}) ->
    S = fun(#bucket { low = Lo, high = Hi}) -> Lo == Min andalso Hi == Max end,
    Target = retrieve(S, Table),
    Target#bucket.members;    
members({node, {ID, _, _}}, RT) ->
    #bucket { members = Members } = retrieve_id(ID, RT),
    Members.
    
%%
%% Check if a node is a member of a bucket list
%%
-spec member_state(dht:peer(), t()) -> boolean().
member_state({ID, IP, Port}, RT) ->
    #bucket { members = Members } = retrieve_id(ID, RT),
    case lists:keyfind(ID, 1, Members) of
        false -> unknown;
        {ID, IP, Port} -> member;
        {ID, _, _} -> roaming_member
    end.

%%
%% Check if a range exists in a range list
%%
-spec is_range({dht:id(), dht:id()}, t()) -> boolean().
is_range(Range, RT) -> lists:member(Range, ranges(RT)).

-spec closest_to(dht:id(), t()) -> list(dht:peer()).
closest_to(ID, #routing_table { table = Buckets }) ->
    Nodes = [N || N <- all_nodes(Buckets)],
    DF = fun({MID, _, _}) -> dht_metric:d(ID, MID) end,
    lists:sort(fun(X, Y) -> DF(X) < DF(Y) end, Nodes).

%%
%% Return a list of all members, combined, in all buckets.
%%
-spec node_list(t()) -> [dht:peer()].
node_list(#routing_table { table = Entries }) ->
    lists:flatmap(fun(B) -> B#bucket.members end, Entries).

%% Retrieve an element from a list
%% Precondition: The element is already in the list
retrieve(F, [X|Xs]) ->
    case F(X) of
        true -> X;
        false -> retrieve(F, Xs)
    end.

%% Given a distance to a target, is it the right bucket?
in_bucket(Dist, #bucket { low = Lo, high = Hi }) -> ?in_range(Dist, Lo, Hi).

%% Specialized retrieve on an ID
retrieve_id(ID, #routing_table { table = Table }) ->
    S = fun(B) -> in_bucket(ID, B) end,
    retrieve(S, Table).

all_nodes([]) -> [];
all_nodes([#bucket { members = Ns } | Bs]) ->
    Rest = all_nodes(Bs),
    Ns ++ Rest.
