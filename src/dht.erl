%% @author Magnus Klaar <magnus.klaar@sgsstudentbostader.se>
%% @doc This module provides few helpers and supervise the DHT processes.
%% Starts two workers: {@link etorrent_dht_state} and {@link etorrent_dht_net}.
%% @end
-module(dht).
-export([integer_id/1,
         list_id/1,
         random_id/0,
         closest_to/3,
         distance/2,
         find_self/0]).

-type nodeinfo() :: etorrent_types:nodeinfo().
-type nodeid() :: etorrent_types:nodeid().


find_self() ->
    Self = etorrent_dht_state:node_id(),
    dht_net:find_node_search(Self).

-spec integer_id(list(byte()) | binary()) -> nodeid().
integer_id(<<ID:160>>) ->
    ID;
integer_id(StrID) when is_list(StrID) ->
    integer_id(list_to_binary(StrID)).

-spec list_id(nodeid()) -> list(byte()).
list_id(ID) when is_integer(ID) ->
    binary_to_list(<<ID:160>>).

-spec random_id() -> nodeid().
random_id() ->
    Byte  = fun() -> random:uniform(256) - 1 end,
    Bytes = [Byte() || _ <- lists:seq(1, 20)],
    integer_id(Bytes).

-spec closest_to(nodeid(), list(nodeinfo()), integer()) ->
    list(nodeinfo()).
closest_to(InfoHash, NodeList, NumNodes) ->
    WithDist = [{distance(ID, InfoHash), ID, IP, Port}
               || {ID, IP, Port} <- NodeList],
    Sorted = lists:sort(WithDist),
    Limited = if
    (length(Sorted) =< NumNodes) -> Sorted;
    (length(Sorted) >  NumNodes)  ->
        {Head, _Tail} = lists:split(NumNodes, Sorted),
        Head
    end,
    [{NID, NIP, NPort} || {_, NID, NIP, NPort} <- Limited].

-spec distance(nodeid(), nodeid()) -> nodeid().
distance(BID0, BID1) when is_binary(BID0), is_binary(BID1) ->
    <<ID0:160>> = BID0,
    <<ID1:160>> = BID1,
    ID0 bxor ID1;
distance(ID0, ID1) when is_integer(ID0), is_integer(ID1) ->
    ID0 bxor ID1.
