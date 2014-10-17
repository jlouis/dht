-module(dht_net_eqc).
-compile(export_all).

-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_component.hrl").

-record(state, {
	init = false,
	port = 1729
}).

api_spec() ->
    #api_spec {
        language = erlang,
        modules = [
          #api_module {
            name = dht_state,
            functions = [
                #api_fun { name = node_id, arity = 0 } ] },
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
    elements([ok, {error, timeout}, {error, einval}, {error, enoent}]).

%% INITIALIZATION
init_pre(#state { init = false }) -> true;
init_pre(#state {}) -> false.

init(Port) ->
    {ok, _Pid} = dht_net:start_link(Port),
    ok.

init_args(#state { port = P }) -> [P].

init_next(State, _, _) ->
    State#state { init = true }.

init_callouts(#state { port = P }, [P]) ->
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
	dht_net ! {udp, Socket, IP, Port, Packet},
	dht_net:sync().

q_ping_args(_S) ->
      ?LET({IP, Port, Packet}, {dht_eqc:ip(), dht_eqc:port(), dht_proto_eqc:q(dht_proto_eqc:q_ping())},
          [sock_ref, IP, Port, Packet]).

q_ping_callouts(#state {}, [_Sock, _IP, _Port, _Packet]) ->
    ?SEQ([
        ?CALLOUT(dht_state, node_id, [], dht_eqc:id())
    ]).

%% PING - Not finished yet, this requires blocking calls >:-)
ping_pre(#state { init = I }) -> I.

ping(Peer) ->
	dht_net:ping(Peer).
	
%% ping_args(_S) ->
%%	[{dht_eqc:ip(), dht_eqc:port}].
	
ping_callouts(#state{}, [{IP, Port}]) ->
    ?CALLOUT(dht_socket, send, [sock_ref, IP, Port, ?WILDCARD], r_socket_send()).

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
