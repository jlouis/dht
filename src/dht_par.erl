%%% @doc Module dht_par runs commands in parallel for the DHT
-module(dht_par).

-export([pmap/2]).

pmap(_F, []) -> [];
pmap(F, [E | Es]) -> [{ok, F(E)} || pmap(F, Es)].
