-module(dht_eqc).

-compile(export_all).

-include_lib("eqc/include/eqc.hrl").

%% Generators
id() ->
    ?LET(<<ID:160>>, binary(20),
        ID).

ip() ->
    ?LET([B1, B2, B3, B4], vector(4, choose(0,255)),
      {B1, B2, B3, B4}).
      
port() ->
    choose(0, 65535).

node_t() ->
    ?LET({ID, IP, Port}, {id(), ip(), port()},
        {ID, IP, Port}).

tag() ->
    ?LET(ID, choose(0, 16#FFFF),
        <<ID:16>>).


token() ->
    ?LET([L, U], [choose(0, 16#FFFF), choose(0, 16#FFFF)],
        <<L:16, U:16>>).

%% Operation properties
prop_op_refl() ->
    ?FORALL(X, id(),
        dht_metric:d(X, X) == 0).

prop_op_sym() ->
    ?FORALL({X, Y}, {id(), id()},
        dht_metric:d(X, Y) == dht_metric:d(Y, X)).

prop_op_triangle_ineq() ->
    ?FORALL({X, Y, Z}, {id(), id(), id()},
        dht_metric:d(X, Y) + dht_metric:d(Y, Z) >= dht_metric:d(X, Z)).
