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
            name = dht_socket,
            functions = [
                 #api_fun { name = send, arity = 4 },
                 #api_fun { name = open,  arity = 2 },
                 #api_fun { name = sockname, arity = 1 } ] }]
    }.

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

prop_component_correct() ->
   ?SETUP(fun() ->
       application:load(dht),
       eqc_mocking:start_mocking(api_spec()),
       fun() -> ok end
     end,
     ?FORALL(Port, dht_eqc:port(),
     ?FORALL(Cmds, commands(?MODULE, #state { port = Port}),
     ?TRAPEXIT(
       begin
           {H, S, R} = run_commands(?MODULE, Cmds),
           ok = cleanup(),
           pretty_commands(?MODULE, Cmds, {H, S, R},
               aggregate(command_names(Cmds), R == ok))
       end)))).
