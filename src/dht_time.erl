-module(dht_time).

-export([timestamp/0]).

timestamp() ->
    os:timestamp().

