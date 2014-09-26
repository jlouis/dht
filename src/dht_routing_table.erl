-module(dht_routing_table).

-export([new/0]).
-export([
	closest_to/5,
	delete/3,
	has_bucket/2,
	insert/3,
	is_member/3,
	members/3,
	node_list/1,
	range/3,
	ranges/1
]).


-define(K, 8).
-define(in_range(Dist, Min, Max), ((Dist >= Min) andalso (Dist < Max))).

%%
%% Create a new bucket list
%%
new() ->
    MaxID = 1 bsl 160,
    [{0, MaxID, []}].


%%
%% Insert a new node into a bucket list
%%
insert(Self, {ID, _, _} = Node, Buckets) ->
    {Rest, Acc} = insert_(dht_metric:d(Self, ID), Self, Node, ?K, Buckets, []),
    lists:reverse(Acc) ++ Rest.

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
ranges([]) -> [];
ranges([{Min, Max, _}|T]) -> [{Min, Max}|ranges(T)].

%%
%% Return the range of the bucket that a node falls within
%%
range(ID, Self, Buckets) ->
    range_(dht_metric:d(ID, Self), Buckets).

range_(Dist, [{Min, Max, _}|_]) when ?in_range(Dist, Min, Max) ->
    {Min, Max};
range_(Dist, [_|T]) ->
    range_(Dist, T).

%%
%% Delete a node from a bucket list
%%
delete({ID, _, _} = Node, Self, RoutingTable) ->
    {Rest, Acc} = delete_(dht_metric:d(ID, Self), Node, RoutingTable, []),
    lists:reverse(Acc) ++ Rest.

delete_(_, _, [], Acc) -> {[], Acc};
delete_(Dist, Node, [{Min, Max, Members}|T], Acc) when ?in_range(Dist, Min, Max) ->
    NewMembers = ordsets:del_element(Node, Members),
    {[{Min, Max, NewMembers}|T], Acc};
delete_(Dist, Node, [H|T], Acc) ->
    delete_(Dist, Node, T, [H|Acc]).

%%
%% Return all members of the bucket that this node is a member of
%%
members(Range={_Min, _Max}, _Self, Buckets) ->
    members_1(Range, Buckets);
members(ID, Self, Buckets) ->
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
is_member({ID, _, _} = Node, Self, RoutingTable) ->
    is_member_(dht_metric:d(Self, ID), Node, RoutingTable).

is_member_(_Dist, _Node, []) -> false;
is_member_(Dist, Node, [{Min, Max, Members} | _Tail]) when ?in_range(Dist, Min, Max) ->
    lists:member(Node, Members);
is_member_(Dist, Node, [_|Tail]) ->
    is_member_(Dist, Node, Tail).


%%
%% Check if a bucket exists in a bucket list
%%
has_bucket({_, _}, []) ->
    false;
has_bucket({Min, Max}, [{Min, Max, _}|_]) ->
    true;
has_bucket({Min, Max}, [{_, _, _}|T]) ->
    has_bucket({Min, Max}, T).

closest_to(ID, Self, Buckets, NodeFilterF, Num) ->
    lists:flatten(closest_to_1(dht_metric:d(ID, Self), ID, Num, Buckets, NodeFilterF, [], [])).

closest_to_1(_, _, 0, _, _, _, Ret) ->
    Ret;
closest_to_1(Dist, ID, Num, [], NodeFilterF, Rest, Ret) ->
    closest_to_2(Dist, ID, Num, Rest, NodeFilterF, Ret);
closest_to_1(Dist, ID, Num, [{Min, _Max, Members}|T], NodeFilterF, Rest, Acc)
  when (Dist band Min) > 0 ->
    CloseNodes = dht:closest_to(ID, [M || M <- Members, NodeFilterF(M)], Num),
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
    ClosestNodes = dht:closest_to(ID, [M || M <- Members, NodeFilterF(M)], Num) ++ Acc,
    NxtN = max(0, Num - length(ClosestNodes)),
    NxtAcc = [ClosestNodes|Acc],
    closest_to_2(Dist, ID, NxtN, T, NodeFilterF, NxtAcc).

%%
%% Return a list of all members, combined, in all buckets.
%%
node_list([]) ->
    [];
node_list([{_, _, Members}|T]) ->
    Members ++ node_list(T).
