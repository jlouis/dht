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

%% Operation properties
prop_op_refl() ->
    ?FORALL(X, id(),
        dht_id:dist(X, X) == 0).

prop_op_sym() ->
    ?FORALL({X, Y}, {id(), id()},
        dht_id:dist(X, Y) == dht_id:dist(Y, X)).

prop_op_triangle_ineq() ->
    ?FORALL({X, Y, Z}, {id(), id(), id()},
        dht_id:dist(X, Y) + dht_id:dist(Y, Z) >= dht_id:dist(X, Z)).
