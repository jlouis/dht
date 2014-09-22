-module(dht_bucket).

-export([new/0]).
-export([
	closest_to/5,
	delete/5,
	has_bucket/2,
	insert/5,
	is_member/5,
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
insert(Self, ID, IP, Port, Buckets) when is_integer(ID),
                                           is_integer(Port) ->
    {Rest, Acc} = insert_(distance(Self, ID), Self, ID, IP, Port, ?K, Buckets, []),
    lists:reverse(Acc) ++ Rest.

insert_(0, _Self, _ID, _IP, _Port, _K, Buckets, Acc) ->
    {Buckets, Acc};
insert_(1, _Self, ID, IP, Port, _K, [{Min=0, Max=1, Members}], Acc) ->
    NewMembers = ordsets:add_element({ID, IP, Port}, Members),
    {[{Min, Max, NewMembers}], Acc};
insert_(Dist, Self, ID, IP, Port, K, [{Min, Max, Members}], Acc) when ?in_range(Dist, Min, Max) ->
    NumMembers = length(Members),
    if  NumMembers < K ->
            NewMembers = ordsets:add_element({ID, IP, Port}, Members),
            {[{Min, Max, NewMembers}], Acc};
        NumMembers == K ->
            Diff  = Max - Min,
            Half  = Max - (Diff div 2),
            {Lower, Upper} = lists:foldl(fun ({MID, _, _}=N, {Ls,Us}) ->
                                                 case ?in_range(distance(MID, Self), Min, Half) of
                                                     true ->
                                                         {[N|Ls], Us};
                                                     false ->
                                                         {Ls, [N|Us]}
                                                 end
                                         end, {[], []}, Members),
            WithSplit = [{Half, Max, lists:reverse(Upper)},
                         {Min, Half, lists:reverse(Lower)}],
            insert_(Dist, Self, ID, IP, Port, K, WithSplit, Acc)
    end;
insert_(Dist, _Self, ID, IP, Port, K, [{Min, Max, Members}|T], Acc) when ?in_range(Dist, Min, Max) ->
    NumMembers = length(Members),
    if  NumMembers < K ->
            NewMembers = ordsets:add_element({ID, IP, Port}, Members),
            {[{Min, Max, NewMembers}|T], Acc};
        NumMembers == K ->
            {[{Min, Max, Members}|T], Acc}
    end;
insert_(Dist, Self, ID, IP, Port, K, [H|T], Acc) ->
    insert_(Dist, Self, ID, IP, Port, K, T, [H|Acc]).

%% Get all ranges present in a bucket list
%%
ranges([]) -> [];
ranges([{Min, Max, _}|T]) -> [{Min, Max}|ranges(T)].

%%
%% Return the range of the bucket that a node falls within
%%
range(ID, Self, Buckets) ->
    range_(distance(ID, Self), Buckets).

range_(Dist, [{Min, Max, _}|_]) when ?in_range(Dist, Min, Max) ->
    {Min, Max};
range_(Dist, [_|T]) ->
    range_(Dist, T).

%%
%% Delete a node from a bucket list
%%
delete(ID, IP, Port, Self, Buckets) ->
    {Rest, Acc} = delete_(distance(ID, Self), ID, IP, Port, Buckets, []),
    lists:reverse(Acc) ++ Rest.

delete_(_, _, _, _, [], Acc) ->
    {[], Acc};
delete_(Dist, ID, IP, Port, [{Min, Max, Members}|T], Acc) when ?in_range(Dist, Min, Max) ->
    NewMembers = ordsets:del_element({ID, IP, Port}, Members),
    {[{Min, Max, NewMembers}|T], Acc};
delete_(Dist, ID, IP, Port, [H|T], Acc) ->
    delete_(Dist, ID, IP, Port, T, [H|Acc]).

%%
%% Return all members of the bucket that this node is a member of
%%
members(Range={_Min, _Max}, _Self, Buckets) ->
    members_1(Range, Buckets);
members(ID, Self, Buckets) ->
    members_2(distance(ID, Self), Buckets).

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
is_member(ID, IP, Port, Self, Buckets) ->
    is_member_(distance(Self, ID), ID, IP, Port, Buckets).

is_member_(_, _, _, _, []) ->
    false;
is_member_(Dist, ID, IP, Port, [{Min, Max, Members}|_]) when ?in_range(Dist, Min, Max) ->
    lists:member({ID, IP, Port}, Members);
is_member_(Dist, ID, IP, Port, [_|T]) ->
    is_member_(Dist, ID, IP, Port, T).


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
    lists:flatten(closest_to_1(distance(ID, Self), ID, Num, Buckets, NodeFilterF, [], [])).

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

%% INTERNAL FUNCTIONS
%% -------------------

distance(ID1, ID2) ->
    ID1 bxor ID2.
