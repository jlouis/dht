-module(dht_routing_table).

-export([new/1]).
-export([
	delete/2,
	insert/2
]).

%% Query
-export([
        node_id/1,
	closest_to/4,
	has_bucket/2,
	is_member/2,
	members/2,
	node_list/1,
	range/2,
	ranges/1
]).

%% Conversion to persistent state
-export([to_binary/1, from_binary/1]).

-define(K, 8).
-define(in_range(Dist, Min, Max), ((Dist >= Min) andalso (Dist < Max))).

-record(routing_table,
        { self :: dht:node_id(),
          table :: [{dht:node_id(), dht:node_id(), [dht:node_t()]}]
        }).
-type t() :: #routing_table{}.

-export_type([t/0]).

%%
%% Create a new bucket list
%%
-spec new(dht:node_id()) -> t().
new(Self) when is_integer(Self), Self >= 0 ->
    MaxID = 1 bsl 160,
    #routing_table {
       self = Self,
       table = [{0, MaxID, []}]
    }.

-spec to_binary(t()) -> binary().
to_binary(#routing_table{} = RT) ->
    term_to_binary(RT, [compressed]).

-spec from_binary(binary()) -> t().
from_binary(Bin) ->
    binary_to_term(Bin).

-spec node_id(t()) -> dht:node_id().
node_id(#routing_table { self = ID }) ->
    ID.

%%
%% Insert a new node into a bucket list
%%
-spec insert(dht:node_t(), t()) -> t().
insert({ID, _, _} = Node, #routing_table { self = Self, table = Buckets} = Tbl) ->
    {Rest, Acc} = insert_(dht_metric:d(Self, ID), Self, Node, ?K, Buckets, []),
    Tbl#routing_table { table = lists:reverse(Acc) ++ Rest}.

%% The recursive runner for insertion
insert_(0, _Self, _Node, _K, Buckets, Acc) ->
    {Buckets, Acc};
insert_(1, _Self, Node, _K, [{Min=0, Max=1, Members}], Acc) ->
    NewMembers = ordsets:add_element(Node, Members),
    {[{Min, Max, NewMembers}], Acc};
insert_(Dist, Self, Node, K, [{Min, Max, Members} | Next], Acc)
  when ?in_range(Dist, Min, Max) ->
    %% We analyze the numbers of members and either insert or split the bucket
    case length(Members) of
      L when L < K ->
        {[{Min, Max, ordsets:add_element(Node, Members)} | Next], Acc};
      L when L == K, Next /= [] ->
        {[{Min, Max, Members} | Next], Acc};
      L when L == K ->
        Splitted = insert_split_bucket({Min, Max, Members}, Self),
        insert_(Dist, Self, Node, K, Splitted, Acc)
	end;
insert_(Dist, Self, Node, K, [H|T], Acc) ->
    insert_(Dist, Self, Node, K, T, [H|Acc]).
        
insert_split_bucket({Min, Max, Members}, Self) ->
  Diff = Max - Min,
  Half = Max - (Diff div 2),
  {Lower, Upper} = split_partition(Members, Self, Min, Half),
  [{Min, Half, Lower}, {Half, Max, Upper}].

split_partition(Members, Self, Min, Half) ->
	{Lower, Upper} =
	  lists:foldl(fun ({MID, _, _} = N, {Ls, Us}) ->
	                case ?in_range(dht_metric:d(MID, Self), Min, Half) of
	                  true -> {[N | Ls ], Us};
	                  false -> {Ls, [N | Us]}
	                end
	              end,
	              {[], []},
	              Members),
	{lists:reverse(Lower), lists:reverse(Upper)}.


%% Get all ranges present in a bucket list
%%
-spec ranges(t()) -> list({dht:node_id(), dht:node_id()}).
ranges(#routing_table { table = Entries }) ->
    [{Min, Max} || {Min, Max, _} <- Entries].

%%
%% Return the range of the bucket that a node falls within
%%
-spec range(dht:node_id(), t()) -> {dht:node_id(), dht:node_id()}.
range(ID, #routing_table { self = Self, table = Buckets}) ->
    range_(dht_metric:d(ID, Self), Buckets).

range_(Dist, [{Min, Max, _}|_]) when ?in_range(Dist, Min, Max) ->
    {Min, Max};
range_(Dist, [_|T]) ->
    range_(Dist, T).

%%
%% Delete a node from a bucket list
%%
-spec delete(dht:node_t(), t()) -> t().
delete({ID, _, _} = Node, #routing_table { self = Self, table = RoutingTable} = Tbl) ->
    {Rest, Acc} = delete_(dht_metric:d(ID, Self), Node, RoutingTable, []),
    Tbl#routing_table { table = lists:reverse(Acc) ++ Rest }.

delete_(_, _, [], Acc) -> {[], Acc};
delete_(Dist, Node, [{Min, Max, Members}|T], Acc) when ?in_range(Dist, Min, Max) ->
    NewMembers = ordsets:del_element(Node, Members),
    {[{Min, Max, NewMembers}|T], Acc};
delete_(Dist, Node, [H|T], Acc) ->
    delete_(Dist, Node, T, [H|Acc]).

%%
%% Return all members of the bucket that this node is a member of
%%
members(Range={_Min, _Max}, #routing_table { table = Buckets}) ->
    members_1(Range, Buckets);
members(ID, #routing_table { self = Self, table = Buckets}) ->
    members_2(dht_metric:d(ID, Self), Buckets).

members_1({Min, Max}, [{Min, Max, Members}|_]) ->
    Members;
members_1({Min, Max}, [_|T]) ->
    members_1({Min, Max}, T).

members_2(Dist, [{Min, Max, Members}|_]) when ?in_range(Dist, Min, Max) ->
    Members;
members_2(Dist, [_|T]) ->
    members_2(Dist, T).

%%
%% Check if a node is a member of a bucket list
%%
-spec is_member(dht:node_t(), t()) -> boolean().
is_member({ID, _, _} = Node, #routing_table { self = Self, table = RoutingTable}) ->
    is_member_(dht_metric:d(Self, ID), Node, RoutingTable).

is_member_(_Dist, _Node, []) -> false;
is_member_(Dist, Node, [{Min, Max, Members} | _Tail]) when ?in_range(Dist, Min, Max) ->
    lists:member(Node, Members);
is_member_(Dist, Node, [_|Tail]) ->
    is_member_(Dist, Node, Tail).


%%
%% Check if a bucket exists in a bucket list
%%
-spec has_bucket({dht:node_id(), dht:node_id()}, t()) -> boolean().
has_bucket(Bucket, #routing_table { table = Entries}) ->
    lists:member(Bucket, [{Min, Max} || {Min, Max, _} <- Entries]).

-spec closest_to(dht:node_id(), fun ((dht:node_id()) -> boolean()), pos_integer(), t()) ->
                        list(dht:node_t()).
closest_to(ID, NodeFilterF, Num, #routing_table { self = Self, table = Buckets }) ->
    lists:flatten(closest_to_1(dht_metric:d(ID, Self), ID, Num, Buckets, NodeFilterF, [], [])).

closest_to_1(_, _, 0, _, _, _, Ret) ->
    Ret;
closest_to_1(Dist, ID, Num, [], NodeFilterF, Rest, Ret) ->
    closest_to_2(Dist, ID, Num, Rest, NodeFilterF, Ret);
closest_to_1(Dist, ID, Num, [{Min, _Max, Members}|T], NodeFilterF, Rest, Acc)
  when (Dist band Min) > 0 ->
    CloseNodes = dht_metric:neighborhood(ID, [M || M <- Members, NodeFilterF(M)], Num),
    NxtNum = max(0, Num - length(CloseNodes)),
    NxtAcc = [CloseNodes|Acc],
    closest_to_1(Dist, ID, NxtNum, T, NodeFilterF, Rest, NxtAcc);
closest_to_1(Dist, ID, Num, [H|T], NodeFilterF, Rest, Acc) ->
    closest_to_1(Dist, ID, Num, T, NodeFilterF, [H|Rest], Acc).

closest_to_2(_, _, 0, _, _, Ret) ->
    Ret;
closest_to_2(_, _, _, [], _, Ret) ->
    Ret;
closest_to_2(Dist, ID, Num, [{_Min, _Max, Members}|T], NodeFilterF, Acc) ->
    ClosestNodes = dht_metric:neighborhood(ID, [M || M <- Members, NodeFilterF(M)], Num) ++ Acc,
    NxtN = max(0, Num - length(ClosestNodes)),
    NxtAcc = [ClosestNodes|Acc],
    closest_to_2(Dist, ID, NxtN, T, NodeFilterF, NxtAcc).

%%
%% Return a list of all members, combined, in all buckets.
%%
-spec node_list(t()) -> list(dht:node_t()).
node_list(#routing_table { table = Entries }) ->
    lists:flatmap(fun({_, _, Members}) -> Members end, Entries).

