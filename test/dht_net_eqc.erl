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
                 #api_fun { name = sockname, arity = 1 } ] },
          #api_module {
            name = dht_time,
            functions = [
                #api_fun { name = send_after, arity = 3 }
            ] }
        ]
    }.

%% Return typical POSIX error codes here
%% I'm not sure we hit them all, but...
error_posix() ->
  ?LET(PErr, elements([eagain]),
      {error, PErr}).
  	
socket_response_send() ->
    elements([ok, error_posix()]).

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
    ?CALLOUT(dht_time, send_after, [?TOKEN_LIFETIME, ?WILDCARD, renew_token], 'TOKEN'),
    ?RET(true).
    
%% MAIN PROPERTY
%% ---------------------------------------------------------

%% Use a common postcondition for all commands, so we can utilize the valid return
%% of each command.
%%postcondition_common(S, Call, Res) ->
%%    eq(Res, return_value(S, Call)).

reset() ->
    case whereis(dht_net) of
        undefined -> ok;
        Pid when is_pid(Pid) ->
            exit(Pid, kill),
            timer:sleep(1)
    end,
    ok.

prop_net_correct() ->
   ?SETUP(fun() ->
       application:load(dht),
       eqc_mocking:start_mocking(api_spec()),
       fun() -> ok end
     end,
     ?FORALL(Cmds, commands(?MODULE),
       begin
        ok = reset(),
        {H,S,R} = run_commands(?MODULE, Cmds),
        pretty_commands(?MODULE, Cmds, {H,S,R},
            aggregate(with_title('Commands'), command_names(Cmds),
            collect(eqc_lib:summary('Length'), length(Cmds),
            aggregate(with_title('Features'), eqc_statem:call_features(H),
            features(eqc_statem:call_features(H),
                R == ok)))))
       end)).


%% HELPER ROUTINES
%% -----------------------------------------------

initialized(#state { init = Init}) -> Init.
