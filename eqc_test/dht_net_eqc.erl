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
            name = gen_udp,
            functions = [
                 #api_fun { name = send, arity = 2 } ] }]
    }.

%% INITIALIZATION
init_pre(#state { init = false }) -> true;
init_pre(#state {}) -> false.

init(Port) ->
    {ok, _Pid} = dht_state:start_link(Port),
    ok.

init_args(#state { port = P }) -> [P].

init_next(State, _, _) ->
    State#state { init = true }.

init_return(_, [_]) -> ok.

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
