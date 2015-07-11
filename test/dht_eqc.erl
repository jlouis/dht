-module(dht_eqc).
-compile(export_all).

-include_lib("eqc/include/eqc.hrl").

-include("dht_eqc.hrl").

%% Generators
id(Min, Max) -> choose(Min, Max).

id() -> id(?ID_MIN, ?ID_MAX - 1).

ip() ->
    oneof([ipv4_address(),
           ipv6_address()]).
    
ipv4_address() ->
    ?LET(L, vector(4, choose(0, 255)),
         list_to_tuple(L)).
        
ipv6_address() ->
    ?LET(L, vector(8, choose(0, 65535)),
         list_to_tuple(L)).

port() ->
    choose(0, 1024*64 - 1).

socket() ->
    {ip(), port()}.

peer() ->
    ?LET({ID, IP, Port}, {id(), ip(), port()},
         {ID, IP, Port}).

value() -> peer().

tag() ->
    ?LET(ID, choose(0, 16#FFFF),
        <<ID:16>>).

unique_id_pair() ->
    ?SUCHTHAT([X, Y], [id(), id()],
      X /= Y).

range() -> ?LET([X, Y], unique_id_pair(), list_to_tuple(lists:sort([X,Y]))).

token() ->
    ?LET([L, U], [choose(0, 16#FFFF), choose(0, 16#FFFF)],
        <<L:16, U:16>>).

node_eq({X, _, _}, {Y, _, _}) -> X =:= Y.
