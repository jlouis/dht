-module(dht_proto_eqc).

-compile(export_all).

-include_lib("eqc/include/eqc.hrl").

%% Generators
q_ping() ->
    return(ping).
    
q_find() ->
    ?LET({Mode, ID}, {elements([node, value]), dht_eqc:id()},
      {find, Mode, ID}).
        
q_store() ->
    ?LET([Token, ID, Port], [dht_eqc:token(), dht_eqc:id(), dht_eqc:port()],
        {store, Token, ID, Port}).

q() ->
    ?LET({Query, Tag},
         {oneof([q_ping(), q_find(), q_store()]),
          dht_eqc:msg_id()},
      {query, Tag, Query}).
        
r_ping() ->
    ?LET(ID, dht_eqc:id(),
        {ping, ID}).
        
r_find_node() ->
    ?LET(Rs, list(dht_eqc:node_t()),
        {find, node, Rs}).

r_find_value() ->
    ?LET({Rs, Token}, {list(dht_eqc:node_t()), dht_eqc:token()},
        {find, value, Token, Rs}).

r_find() ->
    oneof([r_find_node(), r_find_value()]).

r_store() -> store.

r_reply() ->
    oneof([r_ping(), r_find(), r_store()]).

r() ->
    ?LET({Reply, Tag}, {r_reply(), dht_eqc:msg_id()},
        {response, Tag, Reply}).

e() ->
    ?LET({Tag, Code, Msg}, {dht_eqc:msg_id(), int(), binary()},
        {error, Tag, Code, Msg}).

packet() ->
	oneof([q(), r(), e()]).

%% Properties
prop_can_encode() ->
	?FORALL(P, packet(),
		begin
		  dht_proto:encode(P),
		  true
		end).

xprop_iso_packet() ->
    ?FORALL(P, packet(),
        begin
          E = iolist_to_binary(dht_proto:encode(P)),
          equals(P, dht_proto:decode(E))
        end).
