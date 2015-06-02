-module(dht_rand_eqc).
-include_lib("eqc/include/eqc.hrl").

-compile(export_all).

prop_pick() ->
    ?FORALL(Specimen, list(int()),
        case Specimen of
          [] -> equals(dht_rand:pick(Specimen), []);
          Is -> lists:member(dht_rand:pick(Specimen), Is)
        end).
