%%% @doc Application behaviour for the DHT
%%% @end
%%% @private
-module(dht_app).
-behaviour(application).

%% API.
-export([start/2]).
-export([stop/1]).

%% API.

start(_Type, _Args) ->
	dht_sup:start_link().

stop(_State) ->
	ok.