%%% @doc Module dht_par runs commands in parallel for the DHT
-module(dht_par).

-export([pmap/2]).

-spec pmap(fun((A) -> B), [A]) -> [B].
pmap(_F, []) -> [];
pmap(F, [E | Es]) -> [F(E) | pmap(F, Es)].
