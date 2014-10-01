-module(dht_state_eqc).
-compile(export_all).

-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_component.hrl").

-record(state,{
	id % The NodeID the node is currently running under
}).

api_spec() ->
	#api_spec {
		language = erlang,
		modules =
		  [
		  	#api_module {
		  		name = dht_net,
		  		functions = [
		  			#api_fun { name = ping, arity = 2 }
		  		]
		  	}
		  ]
	}.

%% Ask for the node id
node_id() ->
	dht_state:node_id().
	
node_id_args(_S) ->
	[].
	
node_id_return(#state { id = ID }, []) -> ID.

startup(NodeID) ->
	{ok, _Pid} = dht_state:start_link(NodeID, no_state_file, []),
	ok.
	
cleanup() ->
	process_flag(trap_exit, true),
	dht_state ! {stop, self()},
	receive
		stopped -> ok
	end,
	process_flag(trap_exit, false),
	ok.

prop_component_correct() ->
    ?SETUP(fun() ->
        eqc_mocking:start_mocking(api_spec()),
        fun() -> ok end
    end,
    ?FORALL(NodeID, dht_eqc:id(),
    ?FORALL(Cmds, commands(?MODULE, #state { id = NodeID }),
    ?TRAPEXIT(
        begin
            ok = startup(NodeID),
            {H, S, R} = run_commands(?MODULE, Cmds),
            ok = cleanup(),
            pretty_commands(?MODULE, Cmds, {H, S, R},
                aggregate(command_names(Cmds), R == ok))
        end)))).
