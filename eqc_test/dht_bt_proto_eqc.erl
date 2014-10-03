-module(dht_bt_proto_eqc).

-compile(export_all).

-include_lib("eqc/include/eqc.hrl").

%% Generators

ping() ->
    return(ping).
    
find_node() ->
    ?LET(ID, dht_eqc:id(),
        {find_node, ID}).

get_peers() ->
    ?LET(ID, dht_eqc:id(),
        {get_peers, ID}).
        
announce() ->
    ?LET([ID, Token, Port], [dht_eqc:id(), dht_eqc:token(), dht_eqc:port()],
        {announce, ID, Token, Port}).

g_query() ->
    ?LET({Cmd, OwnID, MsgID}, {oneof([ping(), find_node(), get_peers(), announce()]), dht_eqc:id(), dht_eqc:msg_id()},
        {query, OwnID, MsgID, Cmd}).
        
%% Properties
prop_iso_query() ->
    ?FORALL(Q, g_query(),
        begin
            E = iolist_to_binary(dht_bt_proto:encode(Q)),
            equals(Q, dht_bt_proto:decode_as_query(E))
        end).
