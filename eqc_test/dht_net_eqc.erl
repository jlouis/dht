-module(dht_net_eqc).
-compile(export_all).

-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_component.hrl").

-record(state, {
	init = false,
	port = 1729,
	token = undefined,
	blocked = []
}).

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

%% Typical socket responses:
r_socket_send() ->
    elements([ok]).

%% INITIALIZATION
init_pre(#state { init = false }) -> true;
init_pre(#state {}) -> false.

init(Port, Tokens) ->
    {ok, _Pid} = dht_net:start_link(Port, #{ tokens => Tokens }),
    ok.

init_args(#state { }) ->
    [dht_eqc:port(), [dht_eqc:token()]].

init_next(State, _V, [Port, [Token]]) ->
    State#state { init = true, token = Token, port = Port }.

init_callouts(#state { }, [P, _T]) ->
    ?SEQ([
      ?CALLOUT(dht_socket, open, [P, ?WILDCARD], {ok, sock_ref})
    ]).

init_return(_, [_]) -> ok.

%% NODE_PORT
node_port_pre(#state { init = I }) -> I.

node_port() ->
	dht_net:node_port().
	
node_port_args(_S) -> [].

node_port_callouts(#state { }, []) ->
    ?BIND(R, ?CALLOUT(dht_socket, sockname, [sock_ref], {ok, dht_eqc:socket()}),
        ?RET(R)).

%% QUERY of a PING message
q_ping_pre(#state { init = I }) -> I.

q_ping(Socket, IP, Port, Packet) ->
	inject(Socket, IP, Port, Packet).

q_ping_args(_S) ->
      ?LET({IP, Port, Packet}, {dht_eqc:ip(), dht_eqc:port(), dht_proto_eqc:q(dht_proto_eqc:q_ping())},
          [sock_ref, IP, Port, Packet]).

q_ping_callouts(#state {}, [_Sock, IP, Port, _Packet]) ->
    ?SEQ([
        ?CALLOUT(dht_state, node_id, [], dht_eqc:id()),
        ?PAR(
           [?CALLOUT(dht_state, insert_node, [{?WILDCARD, IP, Port}], elements([{error, timeout}, true, false])),
            ?CALLOUT(dht_socket, send, [sock_ref, IP, Port, ?WILDCARD], return(ok))
           ])
    ]).

%% QUERY of a FIND message for a node
q_find_node_pre(#state { init = I }) -> I.

q_find_node(Socket, IP, Port, Packet) ->
	inject(Socket, IP, Port, Packet).
	
q_find_node_args(_S) ->
	[sock_ref, dht_eqc:ip(), dht_eqc:port(), dht_proto_eqc:q(dht_proto_eqc:q_find_node())].
	
q_find_node_callouts(#state {}, [_Sock, IP, Port, _Packet]) ->
    ?SEQ([
        ?CALLOUT(dht_state, node_id, [], dht_eqc:id()),
        ?PAR([
            ?CALLOUT(dht_state, insert_node, [{?WILDCARD, IP, Port}], elements([{error, timeout}, true, false])),
            ?SEQ([
              ?CALLOUT(dht_state, closest_to, [?WILDCARD], return([])),
              ?CALLOUT(dht_socket, send, [sock_ref, IP, Port, ?WILDCARD], return(ok))
            ]) ])
    ]).

%% QUERY of a FIND message for a value
q_find_value_pre(#state { init = I }) -> I.

q_find_value(Socket, IP, Port, Packet) ->
	inject(Socket, IP, Port, Packet).
	
q_find_value_args(_S) ->
	[sock_ref, dht_eqc:ip(), dht_eqc:port(), dht_proto_eqc:q(dht_proto_eqc:q_find_value())].
	
q_find_value_callouts(#state {}, [_Sock, IP, Port, _Packet]) ->
    ?SEQ([
        ?CALLOUT(dht_state, node_id, [], dht_eqc:id()),
        ?PAR([
            ?CALLOUT(dht_state, insert_node, [{?WILDCARD, IP, Port}], elements([{error, timeout}, true, false])),
            ?SEQ([
              ?CALLOUT(dht_store, find, [?WILDCARD], list(dht_eqc:node_t())),
              ?OPTIONAL(?CALLOUT(dht_state, closest_to, [?WILDCARD], return([]))),
              ?CALLOUT(dht_socket, send, [sock_ref, IP, Port, ?WILDCARD], return(ok))
            ]) ])
    ]).

%% QUERY of a STORE message
q_store_pre(#state { init = I }) -> I.

q_store(Socket, IP, Port, Packet) ->
	inject(Socket, IP, Port, Packet).
	
q_store_args(#state { token = BaseToken }) ->
    ?LET([IP, Port], [dht_eqc:ip(), dht_eqc:port()],
        begin
          Token = erlang:phash2({IP, Port, BaseToken}),
          [sock_ref, IP, Port, dht_proto_eqc:q(dht_proto_eqc:q_store(<<Token:32>>))]
        end).

q_store_callouts(#state {}, [_Sock, IP, Port, _Packet]) ->
    ?SEQ([
      ?CALLOUT(dht_state, node_id, [], dht_eqc:id()),
      ?PAR([
          ?CALLOUT(dht_state, insert_node, [{?WILDCARD, IP, Port}], elements([{error, timeout}, true, false])),
          ?SEQ([
              ?CALLOUT(dht_store, store, [?WILDCARD, {IP, ?WILDCARD}], ok),
              ?CALLOUT(dht_socket, send, [sock_ref, IP, Port, ?WILDCARD], return(ok))])])
    ]).

%% QUERY of a STORE message with an invalid token
q_store_invalid_pre(#state { init = I }) -> I.

q_store_invalid(Socket, IP, Port, Packet) ->
	inject(Socket, IP, Port, Packet).
	
invalid_token(Token) ->
    ?SUCHTHAT(T, dht_eqc:token(),
        T /= Token).

q_store_invalid_args(#state { token = BaseToken }) ->
    ?LET([IP, Port, Token], [dht_eqc:ip(), dht_eqc:port(), invalid_token(BaseToken)],
        begin
            [sock_ref, IP, Port, dht_proto_eqc:q(dht_proto_eqc:q_store(Token))]
        end).

q_store_invalid_callouts(#state {}, [_Sock, IP, Port, _Packet]) ->
    ?SEQ([
      ?CALLOUT(dht_state, node_id, [], dht_eqc:id()),
      ?PAR([
          ?CALLOUT(dht_state, insert_node, [{?WILDCARD, IP, Port}], elements([{error, timeout}, true, false])),
          ?CALLOUT(dht_socket, send, [sock_ref, IP, Port, ?WILDCARD], return(ok))])
    ]).

%% FIND_NODE - execute find_node commands
find_node_pre(#state { init = I }) -> I.

find_node(Node) ->
	dht_net:find_node(Node).
	
find_node_args(_S) ->
	[dht_eqc:node_t()].
	
find_node_callouts(#state{}, [Node]) ->
    ?SEQ([
        ?CALLOUT(dht_state, node_id, [], dht_eqc:id()),
        ?CALLOUT(dht_socket, send, [sock_ref, ?WILDCARD, ?WILDCARD, ?WILDCARD], r_socket_send()),
        ?SELFCALL(add_blocked, [?SELF, find_node]),
        ?BLOCK,
        ?SELFCALL(del_blocked, [?SELF])
    ]).

%% PING - execute ping commands
ping_pre(#state { init = I }) -> I.

ping(Peer) ->
	dht_net:ping(Peer).
	
ping_args(_S) ->
	[{dht_eqc:ip(), dht_eqc:port()}].
	
ping_callouts(#state{}, [{IP, Port}]) ->
    ?SEQ([
        ?CALLOUT(dht_state, node_id, [], dht_eqc:id()),
        ?CALLOUT(dht_socket, send, [sock_ref, IP, Port, ?WILDCARD], r_socket_send()),
        ?SELFCALL(add_blocked, [?SELF, ping]),
        ?BLOCK,
        ?SELFCALL(del_blocked, [?SELF])
    ]).

add_blocked_next(#state { blocked = Bs } = S, _V, [Pid, Op]) ->
    S#state { blocked = [{Pid, Op} | Bs] }.

del_blocked_next(#state { blocked = Bs } = S, _V, [Pid]) ->
    S#state { blocked = lists:keydelete(Pid, 1, Bs) }.

%% Packet Injection
%% ------------------

inject(Socket, IP, Port, Packet) ->
    Enc = iolist_to_binary(dht_proto:encode(Packet)),
    dht_net ! {udp, Socket, IP, Port, Enc},
    timer:sleep(2),
    dht_net:sync().


cleanup() ->
    process_flag(trap_exit, true),
    case whereis(dht_net) of
        undefined -> ok;
        Pid ->
           Pid ! {stop, self()},
           receive
             stopped -> ok
           end,
           timer:sleep(1)
   end,
   process_flag(trap_exit, false),
   ok.

%% PROPERTY

prop_net_correct() ->
   ?SETUP(fun() ->
       application:load(dht),
       eqc_mocking:start_mocking(api_spec()),
       fun() -> ok end
     end,
     ?FORALL(Port, dht_eqc:port(),
     ?FORALL(Cmds, commands(?MODULE, #state { port = Port}),
     ?TIMEOUT(1000,
     ?TRAPEXIT(
       begin
           {H, S, R} = run_commands(?MODULE, Cmds),
           ok = cleanup(),
           pretty_commands(?MODULE, Cmds, {H, S, R},
               aggregate(command_names(Cmds), R == ok))
       end))))).
