-module(dht_eqc).
-compile(export_all).

-include_lib("eqc/include/eqc.hrl").

-include("dht_eqc.hrl").

%% Generators
id(Min, Max) -> choose(Min, Max).

id() -> id(?ID_MIN, ?ID_MAX - 1).

ip() ->
    oneof([ipv4_address(),
           ipv6_address()]).
    
ipv4_address() ->
    ?LET(L, vector(4, choose(0, 255)),
         list_to_tuple(L)).
        
ipv6_address() ->
    ?LET(L, vector(8, choose(0, 65535)),
         list_to_tuple(L)).

port() ->
    choose(0, 1024*64 - 1).

peer() ->
    {id(), ip(), port()}.

endpoint() ->
    {ip(), port()}.

tag() ->
    ?LET(ID, choose(0, 16#FFFF),
        <<ID:16>>).

unique_id_pair() ->
    ?SUCHTHAT([X, Y], [id(), id()],
      X /= Y).

range() -> ?LET([X, Y], unique_id_pair(), list_to_tuple(lists:sort([X,Y]))).

token() -> binary(8).

node_eq({X, _, _}, {Y, _, _}) -> X =:= Y.

%% closer/2 generates IDs which are closer to a target
%% Generate elements which are closer to the target T than the
%% value X.
closer(X, T) ->
    ?LET(Prefix, bit_prefix(<<X:?BITS>>, <<T:?BITS>>),
      ?LET(BS, bitstring(?BITS - bit_size(Prefix)),
        begin
          <<R:?BITS>> = <<Prefix/bitstring, BS/bitstring>>,
          R
        end)).

%% bit_prefix/2 finds the prefix of two numbers
%% Given bit_prefix(X, Tgt), find the common prefix amongst
%% the two and extend it with one bit from Tgt.
bit_prefix(<<>>, <<>>) -> <<>>;
bit_prefix(<<0:1, Xs/bitstring>>, <<0:1, Ys/bitstring>>) ->
    Rest = bit_prefix(Xs, Ys),
    <<0:1, Rest/bitstring>>;
bit_prefix(<<1:1, Xs/bitstring>>, <<1:1, Ys/bitstring>>) ->
    Rest = bit_prefix(Xs, Ys),
    <<1:1, Rest/bitstring>>;
bit_prefix(_Xs, <<Bit:1, _/bitstring>>) ->
    <<Bit:1>>.


