-module(dht_state_eqc).
-compile(export_all).

-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_component.hrl").

-record(state,{
	init = false,
	id % The NodeID the node is currently running under
}).

api_spec() ->
	#api_spec {
		language = erlang,
		modules =
		  [
		  	#api_module {
		  		name = dht_routing_table,
		  		functions = [
		  			#api_fun { name = new, arity = 1 },
		  			#api_fun { name = delete, arity = 2 },
		  			#api_fun { name = insert, arity = 2},

		  			#api_fun { name = closest_to, arity = 4 },
		  			#api_fun { name = has_bucket, arity = 2},
		  			#api_fun { name = is_member, arity = 2},
		  			#api_fun { name = members, arity = 2},
		  			#api_fun { name = node_id, arity = 1},
		  			#api_fun { name = node_list, arity = 1},
		  			#api_fun { name = range, arity = 2},
		  			#api_fun { name = ranges, arity = 1}		  			
		  		]
		  	},
		  	#api_module {
		  		name = dht_net,
		  		functions = [
		  			#api_fun { name = ping, arity = 2 }
		  		]
		  	}
		  ]
	}.

%% GENERATORS
%% -----------------
ip_address() ->
    oneof([ipv4_address(), ipv6_address()]).
    
ipv4_address() ->
    ?LET(L, vector(4, choose(0, 255)),
        list_to_tuple(L)).
        
ipv6_address() ->
    ?LET(L, vector(8, choose(0, 255)),
        list_to_tuple(L)).

port_number() ->
    choose(0, 1024*64 - 1).

g_node() ->
	{dht_eqc:id(), ip_address(), port_number()}.

%% Commands we are skipping:
%% 
%% We skip the state load/store functions. Mostly due to jlouis@ not thinking this is where the bugs are
%% nor is it the place where interesting interactions happen:
%%
%% * load_state/2
%% * dump_state/0, dump_state/1, dump_state/2
%%

%% INITIALIZATION
init_pre(#state { init = false }) -> true;
init_pre(#state {}) -> false.

init(NodeID) ->
	{ok, _Pid} = dht_state:start_link(NodeID, no_state_file, []),
	ok.
	
init_args(#state { id = ID }) -> [ID].

init_callouts(#state { id = ID }, [ID]) ->
    ?SEQ([
        ?CALLOUT(dht_routing_table, new, [ID], rt_ref),
        ?CALLOUT(dht_routing_table, node_list, [rt_ref], []),
        ?CALLOUT(dht_routing_table, node_id, [rt_ref], ID),
        ?CALLOUT(dht_routing_table, ranges, [rt_ref], [])
    ]).

init_next(#state{} = State, _V, _) ->
	State#state { init = true }.

init_return(_, [_]) -> ok.

%% NODE ID
%% ---------------------
node_pre(#state { init = S }) -> S.

node_id() ->
	dht_state:node_id().
	
node_id_args(_S) ->
	[].
	
node_id_return(#state { id = ID }, []) -> ID.

%% PING
%% ---------------------
ping_pre(#state { init = S }) -> S.

ping(IP, Port) ->
	dht_state:ping(IP, Port).

ping_args(_S) ->
	[ip_address(), port_number()].
	
ping_callouts(_S, [IP, Port]) ->
    ?SEQ([
    	?BIND(R, ?CALLOUT(dht_net, ping, [IP, Port], pang),
    		?RET(R))
    ]).

%% CLOSEST TO
%% ------------------------
closest_to_pre(#state { init = S }) -> S.

closest_to(ID, Num) ->
	dht_state:closest_to(ID, Num).
	
closest_to_args(_S) ->
	[dht_eqc:id(), nat()].
	
closest_to_callouts(_S, [ID, Num]) ->
    ?SEQ([
        ?BIND(NN, ?CALLOUT(
        				dht_routing_table,
        				closest_to, [ID, ?WILDCARD, Num, ?WILDCARD],
        				list(g_node())),
        	?RET(NN))
    ]).

%% KEEPALIVE
%% ---------------------------
keepalive_pre(#state { init = S }) -> S.

keepalive(Node) ->
	dht_state:keepalive(Node).
	
keepalive_args(_S) ->
	[g_node()].
	
keepalive_callouts(_S, [{_, IP, Port} = Node]) ->
    ?SEQ([
            ?SELFCALL(ping, [IP, Port]),
            ?CALLOUT(dht_routing_table, is_member, [Node, rt_ref], false),
            ?RET(ok)
    ]).
        
%% MODEL CLEANUP
%% ------------------------------

cleanup() ->
	process_flag(trap_exit, true),
	case whereis(dht_state) of
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
%% -----------------------

prop_component_correct() ->
    ?SETUP(fun() ->
        eqc_mocking:start_mocking(api_spec()),
        fun() -> ok end
    end,
    ?FORALL(NodeID, dht_eqc:id(),
    ?FORALL(Cmds, commands(?MODULE, #state { id = NodeID }),
    ?TRAPEXIT(
        begin
            {H, S, R} = run_commands(?MODULE, Cmds),
            ok = cleanup(),
            pretty_commands(?MODULE, Cmds, {H, S, R},
                aggregate(command_names(Cmds), R == ok))
        end)))).
