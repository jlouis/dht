-module(dht_time).

-export([monotonic_time/0, convert_time_unit/3, system_time/0]).
-export([timestamp/0]).

-spec monotonic_time() -> integer().
monotonic_time() ->
	erlang:monotonic_time().
	
-spec convert_time_unit(integer(), erlang:time_unit(), erlang:time_unit()) -> integer().
convert_time_unit(T, From, To) ->
	erlang:convert_time_unit(T, From, To).

-spec system_time() -> integer().
system_time() ->
	erlang:system_time().

-spec timestamp() -> {pos_integer(), pos_integer(), pos_integer()}.
timestamp() ->
    os:timestamp().

