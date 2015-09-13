-module(dht_net_eqc).
-compile(export_all).

-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_component.hrl").

-record(state, {
	init = false,
	port = 1729,
	
	%% The current tokens in the system, stored newest-at-the-head
	tokens = [],
	
	%% Callers currently blocked
	blocked = []
}).

-record(request, {
	timer_ref,
	target,
	tag,
	query
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
                #api_fun { name = node_id, arity = 0, classify = dht_state_eqc },
                #api_fun { name = closest_to, arity = 1, classify =
                   {dht_state_eqc, closest_to, fun([ID]) -> [ID, 8] end} },
                #api_fun { name = request_success, arity = 2, classify = dht_state_eqc } ] },
          #api_module {
            name = dht_store,
            functions = [
                #api_fun { name = find, arity = 1, classify = dht_store_eqc },
                #api_fun { name = store, arity = 2, classify = dht_store_eqc }
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
%% We build a list of the error codes we think we'll hit in practice. The remaining error codes, we
%% skip, and then we handle them once we hit them in production.
error_posix() ->
  ?LET(PErr, elements([
  	eagain,
  	%% emsgsize,
  	%% EMSGSIZE is not likely to occur since we have built the system correctly, but if it occurs, we
  	%% have some kind of bug in the system.
  	enobufs,
  	ehostunreach,
  	econnrefused,
  	ehostdown,
  	enetdown]),
      {error, PErr}).
  	
socket_response_send() ->
    fault(error_posix(), ok).
    
unique_id(#state { blocked = Bs }, Peer) ->
    ?SUCHTHAT(N, choose(1, 16#FFFF),
        not has_unique_id(Peer, N, Bs)).

has_unique_id(_P, _N, []) -> false;
has_unique_id(P, N, [#request { target = P, tag = N}|_Bs]) -> true;
has_unique_id(P, N, [_ | Bs]) -> has_unique_id(P, N, Bs).

%% INITIALIZATION
%% -------------------------------------

init_pre(S) -> not initialized(S).

init(Port, Tokens) ->
    {ok, Pid} = dht_net:start_link(Port, #{ tokens => Tokens }),
    unlink(Pid),
    erlang:is_process_alive(Pid).

init_args(_S) ->
  [dht_eqc:port(), vector(2, dht_eqc:token())].

init_next(S, _, [Port, Tokens]) ->
    S#state {
        init = true,
        tokens = lists:reverse(Tokens),
        port = Port
    }.

init_callouts(_S, [P, _T]) ->
    ?APPLY(dht_store, ensure_started, []),
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
    ?MATCH(R, ?CALLOUT(dht_socket, sockname, ['SOCKET_REF'], {ok, dht_eqc:endpoint()})),
    case R of
        {ok, NP} -> ?RET(NP);
        Otherwise -> ?FAIL(Otherwise)
    end.

node_port_features(_S, _A, _R) -> [{dht_net, queried_for_node_port}].

%% STORE
%% -----------------------
store(Peer, Token, KeyID, Port) ->
	dht_net:store(Peer, Token, KeyID, Port).
	
store_pre(S) -> initialized(S).
store_args(_S) -> [{dht_eqc:ip(), dht_eqc:port()}, dht_eqc:token(), dht_eqc:id(), dht_eqc:port()].

store_callouts(_S, [{IP, Port}, Token, KeyID, MPort]) ->
    ?MATCH(R, ?APPLY(request, [{IP, Port}, {store, Token, KeyID, MPort}, ?SELF])),
    case R of
        {error, Reason} -> ?RET({error, Reason});
        {response, _, ID, _} -> ?RET({ok, ID})
    end.

store_features(_S, _A, _R) -> [{dht_net, store}].

%% FIND_NODE
%% -----------------------
find_node(Peer, Target) ->
    dht_net:find_node(Peer, Target).

find_node_callers() ->
	[dht_state_eqc].

find_node_pre(S) -> initialized(S).
find_node_args(_S) -> [{dht_eqc:ip(), dht_eqc:port()}, dht_eqc:id()].
find_node_callouts(_S, [{IP, Port}, ID]) ->
    ?MATCH(R, ?APPLY(request, [{IP, Port}, {find, node, ID}, ?SELF])),
    case R of
        {error, Reason} -> ?RET({error, Reason});
        {response, _, _, {find, node, Token, Nodes}} ->
            ?RET({nodes, ID, Token, Nodes})
    end.

find_node_features(_S, _A, _R) -> [{dht_net, find_node}].

%% FIND_VALUE
%% -------------------------
find_value(Peer, KeyID) ->
    dht_net:find_value(Peer, KeyID).
    
find_value_pre(S) -> initialized(S).
find_value_args(_S) -> [{dht_eqc:ip(), dht_eqc:port()}, dht_eqc:id()].
find_value_callouts(_S, [{IP, Port}, KeyID]) ->
    ?MATCH(R, ?APPLY(request, [{IP, Port}, {find, value, KeyID}, ?SELF])),
    case R of
        {error, Reason} -> ?RET({error, Reason});
        {response, _, ID, {find, node, Token, Nodes}} ->
            ?RET({nodes, ID, Token, Nodes});
        {response, _, ID, {find, value, Token, Values}} ->
            ?RET({values, ID, Token, Values})
    end.
find_value_features(_S, _A, _R) -> [{dht_net, find_value}].

%% PING
%% ------------
ping(Peer) ->
    dht_net:ping(Peer).
    
ping_callers() ->
	[dht_state_eqc].

ping_pre(S) -> initialized(S).
ping_args(_S) ->
    [{dht_eqc:ip(), dht_eqc:port()}].
    
ping_callouts(_S, [Target]) ->
    ?MATCH(R, ?APPLY(request, [Target, ping, ?SELF])),
    case R of
        {error, eagain} ->
            ?APPLY(ping, [Target]);
        {error, Reason} -> common_error(pang, Reason);
        {response, _Tag, PeerID, ping} -> ?RET({ok, PeerID})
    end.

ping_features(_S, _A, _R) -> [{dht_net, ping}].


%% PING VERIFY
%% ----------------------

ping_verify(Node, VNode, Opts) ->
    dht_net:ping_verify(Node, VNode, Opts),
    dht_net:sync().

ping_verify_callers() ->
	[dht_state_eqc].

ping_verify_pre(S) -> initialized(S).
%%ping_verify_args(_S) ->
%%	[dht_eqc:peer(), dht_eqc:peer(), #{ reachable => bool() }].
	
ping_verify_callouts(_S, [Node, VNode, Opts]) ->
    ?RET(ok).
    
ping_verify_features(_S, _A, _R) -> [{dht_net, ping_verify}].

%% INCOMING REQUESTS
%% ------------------------------

peer_request(Socket, IP, Port, Packet) ->
    inject(Socket, IP, Port, Packet),
    timer:sleep(5), %% Ugly wait, to make stuff catch up
    dht_net:sync().
    
valid_token(#state { tokens = Tokens }, Peer) ->
    elements([token_value(Peer, T) || T <- Tokens]).

invalid_token(#state { tokens = Tokens }, Peer) ->
    ?SUCHTHAT(GenTok, dht_eqc:token(),
       not lists:member(GenTok, [token_value(Peer, T) || T <- Tokens])).

peer_request_ty(S, Peer) ->
    oneof([
	ping,
	{find, node, dht_eqc:id()},
	{find, value, dht_eqc:id()},
	{store, fault(invalid_token(S, Peer), valid_token(S, Peer)), dht_eqc:id(), dht_eqc:port()}
    ]).


filter_caller(PeerIP, PeerPort, Ns) ->
    [N || N = {_, IP, Port} <- Ns, IP /= PeerIP andalso Port /= PeerPort].

peer_request_pre(S) -> initialized(S).
peer_request_args(S) ->
  ?LET({IP, Port}, {dht_eqc:ip(), dht_eqc:port()},
    ?LET(Packet, {query, dht_eqc:tag(), dht_eqc:id(), peer_request_ty(S, {IP, Port})},
      ['SOCKET_REF', IP, Port, Packet])).

token_value(Peer, Token) ->
    X = term_to_binary(Peer),
    crypto:hmac(sha256, Token, X, 8).

peer_request_callouts(#state { tokens = [T | _] = Tokens }, [_Sock, IP, Port, {query, Tag, PeerID, Query}]) ->
    Peer = {IP, Port},
    ?MATCH(OwnID, ?CALLOUT(dht_state, node_id, [], dht_eqc:id())),
    ?CALLOUT(dht_state, request_success, [{PeerID, IP, Port}, #{ reachable => false }], ok),
    case Query of
        ping ->
            ?APPLY(send_msg, [IP, Port, {response, Tag, OwnID, ping}]),
            ?RET(ok);
        {find, node, ID} ->
            ?MATCH(Nodes, ?CALLOUT(dht_state, closest_to, [ID], list(dht_eqc:peer()))),
            ?APPLY(send_msg, [IP, Port, {response, Tag, OwnID, {find, node, token_value(Peer, T), filter_caller(IP, Port, Nodes)}}]),
            ?RET(ok);
        {find, value, ID} ->
            ?MATCH(Stored, ?CALLOUT(dht_store, find, [ID], oneof([[], list(dht_eqc:endpoint())]))),
            case Stored of
              [] ->
                  ?MATCH(Nodes, ?CALLOUT(dht_state, closest_to, [ID], list(dht_eqc:peer()))),
                  ?APPLY(send_msg, [
                      IP,
                      Port,
                      {response, Tag, OwnID, {find, node, token_value(Peer, T), filter_caller(IP, Port, Nodes)}}]),
                      ?RET(ok);
              Peers ->
                  ?APPLY(send_msg, [IP, Port, {response, Tag, OwnID, {find, value, token_value(Peer, T), Peers}}]),
                  ?RET(ok)
            end;
        {store, PeerToken, ID, SPort} ->
            TokenValues = [token_value(Peer, Tok) || Tok <- Tokens],
            ValidToken = lists:member(PeerToken, TokenValues),
            ?WHEN(ValidToken, ?CALLOUT(dht_store, store, [ID, {IP, SPort}], ok)),
            ?APPLY(send_msg, [IP, Port, {response, Tag, OwnID, store}]),
            ?RET(ok)
   end.
   
peer_request_features(_S, [_, _, _, Query], Res) -> [{dht_net, {incoming, canonicalize(Query), Res}}].

%% Small helper for sending messages since it is common in the above
send_msg_callouts(_S, [IP, Port, Msg]) ->
    ?MATCH(SendRes, ?CALLOUT(dht_socket, send, ['SOCKET_REF', IP, Port, encode(Msg)],
        socket_response_send())),
    ?RET(SendRes).
    
%% REQUEST TIMEOUT
%% ----------------------------

request_timeout({_Ref, _Pid, Key}) ->
    dht_net ! {request_timeout, Key},
    dht_net:sync().
    
request_timeout_pre(S) ->
    initialized(S) andalso blocked(S) /= [].

request_timeout_args(S) ->
    [elements(timeouts(S))].

request_timeout_pre(S, [Timeout]) ->
    lists:member(Timeout, timeouts(S)).

request_timeout_callouts(_S, [{TRef, Pid, _Key}]) ->
    ?APPLY(dht_time_eqc, trigger, [TRef]),
    ?UNBLOCK(Pid, {error, timeout}),
    ?RET(ok).
    
request_timeout_features(_S, _A, _R) -> [{dht_net, request_timeout}].
    
%% REQUEST (Internal call)
%% --------------

%% All queries initiated by our side follows the pattern given here in the request:
request_callouts(S, [{IP, Port} = Target, Q, Self]) ->
    ?CALLOUT(dht_state, node_id, [], dht_eqc:id()),
    ?MATCH(Tag, ?CALLOUT(dht_rand, uniform, [16#FFFF], unique_id(S, {IP, Port}))),
    ?MATCH(SocketResponse,
        ?CALLOUT(dht_socket, send, ['SOCKET_REF', IP, Port, ?WILDCARD], socket_response_send())),
    case SocketResponse of
        {error, Reason} -> ?RET({error, Reason});
        ok ->
          Key = {Target, <<Tag:16/integer>>},
          ?MATCH(TimerRef,
              ?APPLY(dht_time_eqc, send_after, [?QUERY_TIMEOUT, dht_net, {request_timeout, Key}])),
          ?APPLY(add_blocked, [Self, #request { timer_ref = TimerRef, target = Target, tag = Tag, query = Q }]),
          ?MATCH(Response, ?BLOCK(Self)),
          ?APPLY(del_blocked, [Self]),
          case Response of
              {error, timeout} ->
                  ?RET({error, timeout});
              #response { packet = {response, _Tag, PeerID, _} = Resp } ->
                  ?CALLOUT(dht_state, node_id, [], dht_eqc:id()),
                  ?APPLY(dht_time_eqc, cancel_timer, [TimerRef]),
                  ?CALLOUT(dht_state, request_success, [{PeerID, IP, Port}, #{ reachable => true }], ok),
                  ?RET(Resp)
          end
    end.

%% UNIVERSE NETWORK_RESPONSE (Internal, injecting response packets)
%% -----------------------------------
universe_respond(_, #response {ip = IP, port = Port, packet = Packet }) ->
    inject('SOCKET_REF', IP, Port, Packet).

response_to({_Pid, #request { target = {IP, Port}, tag = Tag, query = Query }}) ->
    #response {
        ip = IP,
        port = Port,
        packet = {response, <<Tag:16/integer>>, dht_eqc:id(), q2r(Query)} }.

q2r(Q) ->
   q2r_ok(Q).
   
q2r_ok(ping) -> ping;
q2r_ok({find, node, _ID}) -> {find, node, dht_eqc:token(), list(dht_eqc:peer())};
q2r_ok({find, value, _KeyID}) ->
    oneof([
        {find, node, dht_eqc:token(), list(dht_eqc:peer())},
        {find, value, dht_eqc:token(), list(dht_eqc:endpoint())}
    ]);
q2r_ok({store, _Token, _KeyID, _Port}) -> store.
    

universe_respond_pre(S) -> blocked(S) /= [].
universe_respond_args(S) ->
    ?LET(R, elements(blocked(S)),
        [R, response_to(R)]).
        
universe_respond_pre(S, [E, _]) -> lists:member(E, blocked(S)).

universe_respond_callouts(_S, [{Who, _Request}, Response]) ->
    ?UNBLOCK(Who, Response),
    ?RET(ok).
        
universe_respond_features(_S, [{_, Request}, _], _R) -> [{dht_net, {universe_respond, canonicalize(Request)}}].

canonicalize({query, _, _, {store, _, _, _}}) -> {query, store};
canonicalize({query, _, _, {find, value, _}}) -> {query, find_value};
canonicalize({query, _, _, {find, node, _}}) -> {query, find_node};
canonicalize({query, _, _, ping}) -> {query, ping};
canonicalize(#request { query = Q }) ->
    case Q of
        ping -> ping;
        {find, node, _ID} -> find_node;
        {find, value, _Val} -> find_value;
        {store, _Token, _KeyID, _Port} -> store
    end.

%% RENEWING THE TOKEN
%% -----------------------------------------

renew_token() ->
    dht_net ! renew_token,
    dht_net:sync().
    
renew_token_pre(S) -> initialized(S).

renew_token_args(_S) -> [].

renew_token_callouts(_S, []) ->
    ?APPLY(dht_time_eqc, trigger_msg, [renew_token]),
    ?APPLY(dht_time_eqc, send_after, [?TOKEN_LIFETIME, dht_net, renew_token]),
    ?MATCH(Token, ?CALLOUT(dht_rand, crypto_rand_bytes, [16], binary(16))),
    ?APPLY(cycle_token, [Token]),
    ?RET(ok).

renew_token_features(_S, _A, _R) -> [{dht_net, renew_token}].

cycle_token_next(#state { tokens = Tokens } = S, _, [Token]) ->
    {Cycled, _} = lists:split(2, [Token | Tokens]),
    S#state { tokens = Cycled }.

%% INTERNAL HANDLING OF BLOCKING
%% -------------------------------------------

%% When we block a Pid internally, we track it in the set of blocked operations,
%% given by the following blocked setup:
add_blocked_next(#state { blocked = Bs } = S, _V, [Pid, Op]) ->
    S#state { blocked = Bs ++ [{Pid, Op}] }.
    
del_blocked_next(#state { blocked = Bs } = S, _V, [Pid]) ->
    S#state { blocked = lists:keydelete(Pid, 1, Bs) }.

%% MAIN PROPERTY
%% ---------------------------------------------------------

%% Use a common postcondition for all commands, so we can utilize the valid return
%% of each command.
postcondition_common(S, Call, Res) ->
    eq(Res, return_value(S, Call)).

weight(_S, renew_token) -> 1;
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

blocked(#state { blocked = Bs }) -> Bs.

timeouts(#state { blocked = Bs }) ->
    [{TRef, Pid, {Target, <<Tag:16/integer>>}} || {Pid, #request { timer_ref = TRef, target = Target, tag = Tag }} <- Bs ].

%% Sending an UDP packet into the system:
inject(Socket, IP, Port, Packet) ->
    Enc = iolist_to_binary(dht_proto:encode(Packet)),
    dht_net ! {udp, Socket, IP, Port, Enc},
    dht_net:sync().

encode(Data) -> dht_proto:encode(Data).

common_error(Ret, Reason) ->
    case analyze_error(Reason) of
        fail -> ?RET(Ret);
        Otherwise -> ?FAIL({unexpected_error_reason, Otherwise})
    end.

analyze_error(timeout) -> fail;
analyze_error(enobufs) -> fail;
analyze_error(ehostunreach) -> fail;
analyze_error(econnrefused) -> fail;
analyze_error(ehostdown) -> fail;
analyze_error(enetdown) -> fail;
analyze_error(Other) -> Other.

