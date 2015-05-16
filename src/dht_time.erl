-module(dht_time).

-export([monotonic_time/0, convert_time_unit/3, system_time/0]).
-export([timestamp/0]).

monotonic_time() ->
	erlang:monotonic_time().
	
convert_time_unit(T, From, To) ->
	erlang:convert_time_unit(T, From, To).

system_time() ->
	erlang:system_time().

timestamp() ->
    os:timestamp().

