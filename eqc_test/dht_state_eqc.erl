-module(dht_state_eqc).
-compile(export_all).

-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_component.hrl").

-record(state,{
	init = false,
	time = 0, %% Current notion of where we are time-wise (in ms)
	id, % The NodeID the node is currently running under
	node_list % The list of nodes currently installed in the routing table
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
		  			#api_fun { name = ping, arity = 1 }
		  		]
		  	},
		  	#api_module {
		  		name = dht_time,
		  		functions = [
		  			#api_fun { name = monotonic_time, arity = 0},
		  			#api_fun { name = convert_time_unit, arity = 3 }
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

%% Commands we are skipping:
%% 
%% We skip the state load/store functions. Mostly due to jlouis@ not thinking this is where the bugs are
%% nor is it the place where interesting interactions happen:
%%
%% * load_state/2
%% * dump_state/0, dump_state/1, dump_state/2
%%

%% INITIALIZATION
start_node_pre(#state { init = I }) -> not I.

start_node(NodeID, _Nodes) ->
	{ok, Pid} = dht_state:start_link(NodeID, no_state_file, []),
	unlink(Pid),
	erlang:is_process_alive(Pid).
	
start_node_args(#state { id = ID }) ->
    Nodes = list(dht_eqc:peer()),
    [ID, Nodes].

ranges([]) -> [];
ranges([_|_]) -> [{0, 1 bsl 256 - 1}].

start_node_callouts(#state { id = ID, time = TS }, [ID, Nodes]) ->
    ?CALLOUT(dht_time, monotonic_time, [], TS),
    ?CALLOUT(dht_routing_table, new, [ID], rt_ref),
    ?CALLOUT(dht_routing_table, node_list, [rt_ref], Nodes),
    ?CALLOUT(dht_routing_table, node_id, [rt_ref], ID),
    ?APPLY(initialize_timers, [ID, Nodes]),
    ?RET(true).

start_node_next(#state{} = State, _V, [_, Nodes]) ->
	State#state { init = true, node_list = Nodes }.

initialize_timers_callouts(#state { time = TS }, [_ID, Nodes]) ->
    Ranges = ranges(Nodes),
    io:format("Ranges2: ~p", [Ranges]),
    ?CALLOUT(dht_routing_table, ranges, [rt_ref], Ranges),
    case Ranges of
        [] -> ?RET(ok);
        Rs ->
          ?SEQ(
           [?SEQ(
            ?CALLOUT(dht_time, monotonic_time, [], TS),
            ?CALLOUT(dht_time, convert_time_unit, [TS, native, milli_seconds], TS)) || _ <- Rs]),
          ?RET(ok)
    end.

%% NODE ID
%% ---------------------
node_id() ->
	dht_state:node_id().

node_id_pre(#state { init = Init }) -> Init.
	
node_id_args(_S) ->
	[].
	
node_id_return(#state { id = ID }, []) -> ID.

%% NODE LIST
%% ---------------------
node_list() ->
	dht_state:node_list().
	
node_list_pre(#state { init = Init }) -> Init.

node_list_args(_S) -> [].

node_list_callouts(_S, []) ->
    ?MATCH(R, ?CALLOUT(dht_routing_table, node_list, [rt_ref], list(dht_eqc:peer()))),
    ?RET(R).

%% NOTIFY
%% ---------------------
notify(Node, Event) ->
	dht_state:notify(Node, Event).
	
notify_pre(#state { init = Init, node_list = Nodes }) -> Init andalso (Nodes /= []).

notify_args(#state { node_list = Nodes }) ->
    [elements(Nodes), elements([request_timeout, request_success, request_from])].
    
notify_pre(#state { init = Init, node_list = Ns }, [Node, _]) ->
    Init andalso lists:member(Node, Ns).

notify_callouts(_S, [Node, request_timeout]) ->
    ?CALLOUT(dht_routing_table, is_member, [Node, rt_ref], true),
    ?RET(ok);
notify_callouts(S, [Node, request_from]) -> notify_callouts(S, [Node, request_success]);
notify_callouts(_S, [Node, request_success]) ->
    ?CALLOUT(dht_routing_table, is_member, [Node, rt_ref], true),
    ?APPLY(cycle_bucket_timers, []),
    ?RET(ok).

cycle_bucket_timers_callouts(#state { id = ID }, []) ->
    ?CALLOUT(dht_routing_table, range, [ID, rt_ref], range),
    ?CALLOUT(dht_routing_table, members, [range, rt_ref], list(dht_eqc:peer())).

%% PING
%% ---------------------
ping_pre(#state { init = S }) -> S.

ping(IP, Port) ->
	dht_state:ping(IP, Port).

ping_args(_S) ->
    [ip_address(), port_number()].

ping_callouts(_S, [IP, Port]) ->
    ?MATCH(R, ?CALLOUT(dht_net, ping, [{IP, Port}], pang)),
    ?RET(R).

%% CLOSEST TO
%% ------------------------
closest_to_pre(#state { init = S }) -> S.

closest_to(ID, Num) ->
	dht_state:closest_to(ID, Num).
	
closest_to_args(_S) ->
	[dht_eqc:id(), nat()].
	
closest_to_callouts(_S, [ID, Num]) ->
    ?MATCH(NN, ?CALLOUT(
                      dht_routing_table,
                      closest_to, [ID, ?WILDCARD, Num, ?WILDCARD],
                      list(dht_eqc:peer()))),
    ?RET(NN).

%% KEEPALIVE
%% ---------------------------
keepalive_pre(#state { init = S }) -> S.

keepalive(Node) ->
	dht_state:keepalive(Node).
	
keepalive_args(_S) ->
	[dht_eqc:peer()].
	
keepalive_callouts(_S, [{_, IP, Port} = Node]) ->
    ?APPLY(ping, [IP, Port]),
    ?CALLOUT(dht_routing_table, is_member, [Node, rt_ref], false),
    ?RET(ok).

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
postcondition_common(S, Call, Res) ->
    eq(Res, return_value(S, Call)).

gen_initial_state() ->
    ?LET(NodeID, dht_eqc:id(),
      #state { id = NodeID, init = false }).

prop_state_correct() ->
    ?SETUP(fun() ->
        eqc_mocking:start_mocking(api_spec()),
        fun() -> ok end
    end,
    ?FORALL(StartState, gen_initial_state(),
    ?FORALL(Cmds, commands(?MODULE, StartState),
    ?TRAPEXIT(
        begin
            {H, S, R} = run_commands(?MODULE, Cmds),
            ok = cleanup(),
            pretty_commands(?MODULE, Cmds, {H, S, R},
                collect(eqc_lib:summary('Length'), length(Cmds),
                aggregate(command_names(Cmds),
                  R == ok)))
        end)))).
