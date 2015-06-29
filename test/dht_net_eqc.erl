-module(dht_net_eqc).
-compile(export_all).

-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_component.hrl").

-record(state, {
	init = false,
	port = 1729,
	token = undefined,
	
	%% Callers currently blocked
	blocked = [],
	
	%% Unique message ID's we have currently in use
	unique_ids = []
}).

-record(response, {
	ip :: inet:ip_address(),
	port :: inet:port_number(),
	packet :: binary()
}).

-define(TOKEN_LIFETIME, 5 * 60 * 1000).
-define(QUERY_TIMEOUT, 2000).

initial_state() -> #state{}.

api_spec() ->
    #api_spec {
        language = erlang,
        modules = [
          #api_module {
            name = dht_rand,
            functions = [
                #api_fun { name = uniform, arity = 1 },
                #api_fun { name = crypto_rand_bytes, arity = 1 }
            ] },
          #api_module {
            name = dht_state,
            functions = [
                #api_fun { name = node_id, arity = 0 },
                #api_fun { name = closest_to, arity = 1 },
                #api_fun { name = insert_node, arity = 1 },
                #api_fun { name = request_success, arity = 2 } ] },
          #api_module {
            name = dht_store,
            functions = [
                #api_fun { name = find, arity = 1 },
                #api_fun { name = store, arity = 2 }
            ] },
          #api_module {
            name = dht_socket,
            functions = [
                 #api_fun { name = send, arity = 4 },
                 #api_fun { name = open,  arity = 2 },
                 #api_fun { name = sockname, arity = 1 } ] }
        ]
    }.

%% Return typical POSIX error codes here
%% I'm not sure we hit them all, but...
error_posix() ->
  ?LET(PErr, elements([eagain]),
      {error, PErr}).
  	
socket_response_send() ->
    fault(error_posix(), ok).
    
unique_id(#state { blocked = Bs }, Peer) ->
    ?SUCHTHAT(N, choose(1, 16#FFFF),
        not has_unique_id(Peer, N, Bs)).

has_unique_id(_P, _N, []) -> false;
has_unique_id(P, N, [{request, P, N, _Q}|_Bs]) -> true;
has_unique_id(P, N, [_ | Bs]) -> has_unique_id(P, N, Bs).

%% INITIALIZATION
%% -------------------------------------

init_pre(S) -> not initialized(S).

init(Port, Tokens) ->
    {ok, Pid} = dht_net:start_link(Port, #{ tokens => Tokens }),
    unlink(Pid),
    erlang:is_process_alive(Pid).

init_args(_S) ->
  [dht_eqc:port(), [dht_eqc:token()]].

init_next(S, _, [Port, [Token]]) ->
  S#state { init = true, token = Token, port = Port }.

init_callouts(_S, [P, _T]) ->
    ?CALLOUT(dht_socket, open, [P, ?WILDCARD], {ok, 'SOCKET_REF'}),
    ?APPLY(dht_time_eqc, send_after, [?TOKEN_LIFETIME, dht_net, renew_token]),
    ?RET(true).
    
init_features(_S, _A, _R) -> [{dht_net, initialized}].

%% NODE_PORT
%% -------------------------------------------
node_port_pre(S) -> initialized(S).

node_port() ->
    dht_net:node_port().
    
node_port_args(_S) -> [].

node_port_callouts(_S, []) ->
    ?MATCH(R, ?CALLOUT(dht_socket, sockname, ['SOCKET_REF'], {ok, dht_eqc:socket()})),
    case R of
        {ok, NP} -> ?RET(NP);
        Otherwise -> ?FAIL(Otherwise)
    end.

node_port_features(_S, _A, _R) -> [{dht_net, queried_for_node_port}].

%% FIND_NODE
%% -----------------------
find_node(Node) ->
    dht_net:find_node(Node).

find_node_pre(S) -> initialized(S).
find_node_args(_S) -> [dht_eqc:peer()].
find_node_callouts(_S, [{ID, IP, Port} = Node]) ->
    ?MATCH(R, ?APPLY(request, [{IP, Port}, {find, node, ID}])),
    case R of
        {error, Reason} -> ?RET({error, Reason});
        {response, _, _, {find, node, Nodes}} ->
            ?CALLOUT(dht_state, request_success, [Node, #{ reachable => true }], list(dht_eqc:peer())),
            ?RET({nodes, ID, Nodes})
    end.

find_node_features(_S, _A, _R) -> [{dht_net, find_node}].

%% FIND_VALUE
%% -------------------------
find_value(Peer, IDKey) ->
    dht_net:find_value(Peer, IDKey).
    
find_value_pre(S) -> initialized(S).
find_value_args(_S) -> [{dht_eqc:ip(), dht_eqc:port()}, dht_eqc:id()].
find_value_callouts(_S, [{IP, Port}, KeyID]) ->
    ?MATCH(R, ?APPLY(request, [{IP, Port}, {find, value, KeyID}])),
    case R of
        {error, Reason} -> ?RET({error, Reason});
        {response, _, ID, {find, node, Nodes}} ->
            ?RET({nodes, ID, Nodes});
        {response, _, ID, {find, value, Token, Values}} ->
            ?RET({values, ID, Token, Values})
    end.
find_value_features(_S, _A, _R) -> [{dht_net, find_value}].

%% PING
%% ------------

ping_pre(S) -> initialized(S).

ping(Peer) ->
    dht_net:ping(Peer).
    
ping_args(_S) ->
    [{dht_eqc:ip(), dht_eqc:port()}].
    
ping_callouts(_S, [Target]) ->
    ?MATCH(R, ?APPLY(request, [Target, ping])),
    case R of
        {response, _Tag, PeerID, ping} -> ?RET({ok, PeerID})
    end.

ping_features(_S, _A, _R) -> [{dht_net, ping}].

%% REQUEST (Internal call)
%% --------------

%% All queries initiated by our side follows the pattern given here in the request:
request_callouts(S, [{IP, Port} = Target, Q]) ->
    ?CALLOUT(dht_state, node_id, [], dht_eqc:id()),
    ?MATCH(Tag, ?CALLOUT(dht_rand, uniform, [16#FFFF], unique_id(S, {IP, Port}))),
    ?MATCH(SocketResponse,
        ?CALLOUT(dht_socket, send, ['SOCKET_REF', IP, Port, ?WILDCARD], socket_response_send())),
    case SocketResponse of
        {error, Reason} -> ?RET({error, Reason});
        ok ->
          ?MATCH(TimerRef,
              ?APPLY(dht_time_eqc, send_after, [?QUERY_TIMEOUT, dht_net, {request_timeout, ?WILDCARD}])),
          ?APPLY(add_blocked, [?SELF, {request, Target, Tag, Q}]),
          ?MATCH(Response, ?BLOCK),
          ?APPLY(del_blocked, [?SELF]),
          ?CALLOUT(dht_state, node_id, [], dht_eqc:id()),
          ?APPLY(dht_time_eqc, cancel_timer, [TimerRef]),
          case Response of
              {response, IP, Port, Resp} -> ?RET(Resp)
          end
    end.

%% UNIVERSE NETWORK_RESPONSE (Internal, injecting response packets)
%% -----------------------------------
universe_respond(_, #response {ip = IP, port = Port, packet = Packet }) ->
    inject('SOCKET_REF', IP, Port, Packet).

response_to({_Pid, {request, {IP, Port}, Tag, Query}}) ->
  ?LET(PeerNodeID, dht_eqc:id(),
      #response {
        ip = IP,
        port = Port,
        packet = {response, <<Tag:16/integer>>, PeerNodeID, q2r(Query)}
      }).

q2r(Q) ->
   q2r_ok(Q).
   
q2r_ok(ping) -> ping;
q2r_ok({find, node, _ID}) -> {find, node, list(dht_eqc:peer())};
q2r_ok({find, value, _KeyID}) ->
    oneof([
        {find, node, list(dht_eqc:peer())},
        {find, value, dht_eqc:token(), list(dht_eqc:value())}
    ]).

universe_respond_pre(S) -> blocked(S) /= [].
universe_respond_args(S) ->
    ?LET(R, elements(blocked(S)),
        [R, response_to(R)]).
        
universe_respond_pre(S, [E, _]) -> lists:member(E, blocked(S)).

universe_respond_callouts(_S, [{Pid, _Request}, Response]) ->
    ?UNBLOCK(Pid, Response),
    ?RET(ok).
        
universe_respond_features(_S, [{_, Request}, _], _R) -> [{dht_net, {universe_respond, canonicalize(Request)}}].

canonicalize({request, _, _, Q}) ->
    case Q of
        ping -> ping;
        {find, node, _ID} -> find_node;
        {find, value, _Val} -> find_value
    end.

%% INTERNAL HANDLING OF BLOCKING
%% -------------------------------------------

%% When we block a Pid internally, we track it in the set of blocked operations,
%% given by the following blocked setup:
add_blocked_next(#state { blocked = Bs } = S, _V, [Pid, Op]) ->
    S#state { blocked = Bs ++ [{Pid, Op}] }.
    
del_blocked_next(#state { blocked = Bs } = S, _V, [Pid]) ->
    S#state { blocked = lists:keydelete(Pid, 1, Bs) }.

add_unique_id_next(#state { unique_ids = Us } = S, _V, [Peer]) ->
    S#state { unique_ids = Us ++ [Peer] }.
    
del_unique_id_next(#state { unique_ids = Us } = S, _V, [Peer]) ->
    S#state { unique_ids = lists:keydelete(Peer, 1, Us) }.

%% MAIN PROPERTY
%% ---------------------------------------------------------

%% Use a common postcondition for all commands, so we can utilize the valid return
%% of each command.
postcondition_common(S, Call, Res) ->
    eq(Res, return_value(S, Call)).

weight(_S, node_port) -> 2;
weight(_S, _) -> 10.

reset() ->
    case whereis(dht_net) of
        undefined -> ok;
        Pid when is_pid(Pid) ->
            exit(Pid, kill),
            timer:sleep(1)
    end,
    ok.

%% HELPER ROUTINES
%% -----------------------------------------------

initialized(#state { init = Init}) -> Init.
blocked(#state { blocked = B }) -> B.

%% Sending an UDP packet into the system:
inject(Socket, IP, Port, Packet) ->
    Enc = iolist_to_binary(dht_proto:encode(Packet)),
    dht_net ! {udp, Socket, IP, Port, Enc},
    dht_net:sync().
