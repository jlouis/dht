%% @author Magnus Klaar <magnus.klaar@sgsstudentbostader.se>
%% @doc This module provides few helpers and supervise the DHT processes.
%% Starts two workers: {@link etorrent_dht_state} and {@link etorrent_dht_net}.
%% @end
-module(dht).
-export([integer_id/1,
         bin_id/1,
         random_id/0,
         closest_to/3,
         distance/2,
         find_self/0]).

-type node_id() :: non_neg_integer().
-type node_info() :: {node_id(), inet:ip_address(), inet:port_number()}.
-type peer_info() :: {inet:ip_address(), inet:port_number()}.


-export_type([node_id/0, node_info/0, peer_info/0]).

find_self() ->
    Self = dht_state:node_id(),
    dht_net:find_node_search(Self).

-spec integer_id(binary()) -> node_id().
integer_id(<<ID:160>>) -> ID.

-spec bin_id(node_id()) -> binary().
bin_id(ID) when is_integer(ID) -> <<ID:160>>.


-spec random_id() -> node_id().
random_id() ->
    Byte  = fun() -> random:uniform(256) - 1 end,
    Bytes = [Byte() || _ <- lists:seq(1, 20)],
    integer_id(iolist_to_binary(Bytes)).

-spec closest_to(node_id(), list(node_info()), integer()) ->
    list(node_info()).
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

-spec distance(node_id(), node_id()) -> node_id().
distance(BID0, BID1) when is_binary(BID0), is_binary(BID1) ->
    <<ID0:160>> = BID0,
    <<ID1:160>> = BID1,
    ID0 bxor ID1;
distance(ID0, ID1) when is_integer(ID0), is_integer(ID1) ->
    ID0 bxor ID1.
