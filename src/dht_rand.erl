-module(dht_rand).

-export([pick/1]).

pick([]) -> [];
pick(Items) ->
    Len = length(Items),
    Pos = rand:uniform(Len),
    lists:nth(Pos, Items).
