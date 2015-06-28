-module(dht_net_eqc).
-compile(export_all).

-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_component.hrl").

-record(state, {
	init = false,
	port = 1729,
	token = undefined,
	
	%% Callers currently blocked
	blocked = []
}).

-define(TOKEN_LIFETIME, 300*1000).
-define(QUERY_TIMEOUT, 2000).

initial_state() -> #state{}.

api_spec() ->
    #api_spec {
        language = erlang,
        modules = [
          #api_module {
            name = dht_state,
            functions = [
                #api_fun { name = node_id, arity = 0 },
                #api_fun { name = closest_to, arity = 1 },
                #api_fun { name = insert_node, arity = 1 } ] },
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
    ?APPLY(dht_time, send_after, [?TOKEN_LIFETIME, dht_net, renew_token]),
    ?RET(true).
    
init_features(_S, _A, _R) -> [{dht_net, r00, initialized}].

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

node_port_features(_S, _A, _R) -> [{dht_net, r01, queried_for_node_port}].

%% PING
%% ------------

ping_pre(S) -> initialized(S).

ping(Peer) ->
    dht_net:ping(Peer).
    
ping_args(_S) ->
    [{dht_eqc:ip(), dht_eqc:port()}].
    
ping_callouts(_S, [{IP, Port}]) ->
    ?CALLOUT(dht_state, node_id, [], dht_eqc:id()),
    ?MATCH(SocketResponse,
        ?CALLOUT(dht_socket, send, ['SOCKET_REF', IP, Port, ?WILDCARD], socket_response_send())),
    case SocketResponse of
        {error, Reason} -> ?RET({error, Reason});
        ok ->
          ?APPLY(dht_time, send_after, [?QUERY_TIMEOUT, dht_net, {request_timeout, ?WILDCARD}]),
          ?APPLY(add_blocked, [?SELF, {ping, IP, Port}]),
          ?BLOCK,
          ?APPLY(del_blocked, [?SELF])
    end.

    

%% INTERNAL HANDLING OF BLOCKING
%% -------------------------------------------

%% When we block a Pid internally, we track it in the set of blocked operations,
%% given by the following blocked setup:
add_blocked_next(#state { blocked = Bs } = S, _V, [Pid, Op]) ->
    S#state { blocked = Bs ++ [Pid, Op] }.
    
del_blocked_next(#state { blocked = Bs } = S, _V, [Pid]) ->
    S#state { blocked = lists:keydelete(Pid, 1, Bs) }.


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
