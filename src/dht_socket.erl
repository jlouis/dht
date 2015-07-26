%%% @doc module dht_socket is a callthrough module for gen_udp
%%% @end
%%% @private
-module(dht_socket).

-export([
	open/2,
	send/4,
	sockname/1
]).

open(Port, Opts) ->
	gen_udp:open(Port, Opts).
	
send(Socket, IP, Port, Packet) ->
	gen_udp:send(Socket, IP, Port, Packet).

sockname(Socket) ->
	inet:sockname(Socket).
