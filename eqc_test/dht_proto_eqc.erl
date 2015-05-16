-module(dht_proto_eqc).

-compile(export_all).

-include_lib("eqc/include/eqc.hrl").

%% Generators
q_ping() ->
    return(ping).
    
q_find_node()->
    ?LET(ID, dht_eqc:id(),
        {find, node, ID}).
        
q_find_value() ->
    ?LET(ID, dht_eqc:id(),
        {find, value, ID}).
        
q_find() ->
	oneof([
	    q_find_node(),
	    q_find_value()
	]).
        
q_store(Token) ->
    ?LET([ID, Port], [dht_eqc:id(), dht_eqc:port()],
        {store, Token, ID, Port}).
        
q_store() ->
    ?LET(Token, dht_eqc:token(),
        q_store(Token)).

q() ->
    q(oneof([q_ping(), q_find(), q_store()])).
        
q(G) ->
    ?LET({Tag, ID, Query}, {dht_eqc:tag(), dht_eqc:id(), G},
      {query, Tag, ID, Query}).

r_ping() -> return(ping).
        
r_find_node() ->
    ?LET(Rs, list(dht_eqc:peer()),
        {find, node, Rs}).

r_find_value() ->
    ?LET({Rs, Token}, {list(dht_eqc:peer()), dht_eqc:token()},
        {find, value, Token, Rs}).

r_find() ->
    oneof([r_find_node(), r_find_value()]).

r_store() -> return(store).

r_reply() ->
    oneof([r_ping(), r_find(), r_store()]).

r() ->
    ?LET({Tag, ID, Reply}, {dht_eqc:tag(), dht_eqc:id(), r_reply()},
        {response, Tag, ID, Reply}).

e() ->
    ?LET({Tag, ID, Code, Msg}, {dht_eqc:tag(), dht_eqc:id(), nat(), binary()},
        {error, Tag, ID, Code, Msg}).

packet() ->
	oneof([q(), r(), e()]).

%% Properties
prop_iso_packet() ->
    ?FORALL(P, packet(),
        begin
          E = iolist_to_binary(dht_proto:encode(P)),
          equals(P, dht_proto:decode(E))
        end).
