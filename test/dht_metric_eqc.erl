-module(dht_metric_eqc).

-compile(export_all).

-include_lib("eqc/include/eqc.hrl").

%% Metrics are defined by three rules:
%% • reflexivity
%% • symmetry
%% • triangle equality

prop_op_refl() ->
    ?FORALL(X, dht_eqc:id(),
        dht_metric:d(X, X) == 0).

prop_op_sym() ->
    ?FORALL({X, Y}, {dht_eqc:id(), dht_eqc:id()},
        dht_metric:d(X, Y) == dht_metric:d(Y, X)).

prop_op_triangle_ineq() ->
    ?FORALL({X, Y, Z}, {dht_eqc:id(), dht_eqc:id(), dht_eqc:id()},
        dht_metric:d(X, Y) + dht_metric:d(Y, Z) >= dht_metric:d(X, Z)).

%% Verify we can generate elements closer to a target in the metric.
prop_closer() ->
    ?FORALL({X, T}, {dht_eqc:id(), dht_eqc:id()},
      ?IMPLIES(X /= T,
        ?FORALL(Z, dht_eqc:closer(X, T),
           dht_metric:d(X, T) >= dht_metric:d(Z, T)))).
