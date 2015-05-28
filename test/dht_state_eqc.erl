%% @doc EQC Model for the system state
%% The high-level entry-point for the DHT state. This model implements the public
%% interface for the dht_state gen_server which contains the routing table of the DHT
%%
%% The high-level view is relatively simple to define since most of the advanced parts
%% pertaining to routing has already been handled in dht_routing_meta and its corresponding
%% EQC model.
%%
%% This model defines the large-scale policy rules of the DHT routing table. It uses dht_routing_meta
%% and dht_routing_table for the hard work at the low level and just delegates necessary work to
%% those parts of the code (and their respective models).
%%
%% The dht_state code is a gen_server which occasionally spawns functions to handle background
%% work. Some states are gen_server internal and are marked as such. They refer to callout
%% specifications which are done inside the gen_server. The code path is usually linear in this
%% case as well, however.
%%
%% TODO:
%% · Handle node/timer refresh events
%% · Handle internal invocations of node/timer refresh events
%% · Improve feature coverage of the model. We can cover far more ground with a little bit
%%   of work.
%% @end
-module(dht_state_eqc).
-compile(export_all).

-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_component.hrl").

-record(state,{
	init = false,
	time = 0, %% Current notion of where we are time-wise (in ms)
	id % The NodeID the node is currently running under
}).

-define(K, 8).

api_spec() ->
	#api_spec {
		language = erlang,
		modules =
		  [
		  	#api_module {
		  		name = dht_routing_meta,
		  		functions = [
		  			#api_fun { name = can_insert, arity = 2 },
		  			#api_fun { name = export, arity = 1 },
		  			#api_fun { name = inactive, arity = 2 },
		  			#api_fun { name = is_member, arity = 2 },
		  			#api_fun { name = neighbors, arity = 3 },
		  			#api_fun { name = new, arity = 1 },
		  			#api_fun { name = node_list, arity = 1},
		  			#api_fun { name = node_timeout, arity = 2 },
		  			#api_fun { name = node_timer_state, arity = 2 },
		  			#api_fun { name = range_members, arity = 2 },
		  			#api_fun { name = refresh_node, arity = 2 },
		  			#api_fun { name = remove_node, arity = 2 }
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

%% Commands we are skipping:
%% 
%% We skip the state load/store functions. Mostly due to jlouis@ not thinking this is where the bugs are
%% nor is it the place where interesting interactions happen:
%%
%% * load_state/2
%% * dump_state/0, dump_state/1, dump_state/2
%%

%% INITIAL STATE
%% -----------------------

gen_initial_state() ->
    ?LET(NodeID, dht_eqc:id(),
      #state { id = NodeID, init = false }).

%% START_LINK
%% -----------------------

start_link(NodeID, Nodes) ->
    {ok, Pid} = dht_state:start_link(NodeID, no_state_file, Nodes),
    unlink(Pid),
    erlang:is_process_alive(Pid).
    
start_link_pre(S) -> not initialized(S).

start_link_args(#state { id = ID }) ->
    BootStrapNodes = [],
    [ID, BootStrapNodes].

start_link_callouts(#state { id = ID }, [ID, []]) ->
    ?CALLOUT(dht_routing_meta, new, [?WILDCARD], {ok, ID, rt_ref}),
    ?RET(true).

%% Once started, we can't start the State system again.
start_link_next(State, _, _) ->
    State#state { init = true }.

%% CLOSEST TO
%% ------------------------
closest_to_pre(#state { init = S }) -> S.

closest_to(ID, Num) ->
    dht_state:closest_to(ID, Num).
	
closest_to_args(_S) ->
    [dht_eqc:id(), nat()].
	
closest_to_callouts(_S, [ID, Num]) ->
    ?MATCH(Ns, ?CALLOUT(dht_routing_meta, neighbors, [ID, Num, rt_ref],
        list(dht_eqc:peer()))),
    ?RET(Ns).

%% NODE ID
%% ---------------------
node_id() ->
	dht_state:node_id().

node_id_pre(S) -> initialized(S).
	
node_id_args(_S) -> [].
	
node_id_callouts(#state { id = ID }, []) -> ?RET(ID).

%% NODE LIST
%% ---------------------
node_list() ->
	dht_state:node_list().
	
node_list_pre(S) -> initialized(S).

node_list_args(_S) -> [].

node_list_callouts(_S, []) ->
    ?MATCH(R, ?CALLOUT(dht_routing_meta, node_list, [rt_ref], list(dht_eqc:peer()))),
    ?RET(R).

%% INSERT
%% ---------------------
insert_node({IP, Port}) ->
    dht_state:insert_node({IP, Port});
insert_node({_, _, _} = Node) ->
    dht_state:insert_node(Node).
    
insert_node_pre(S) -> initialized(S).

insert_node_args(_S) ->
    N = ?LET({_ID, IP, Port} = N, dht_eqc:peer(), oneof([ {unknown, IP, Port}, N ])),
    [N].

insert_node_callouts(_S, [{unknown, IP, Port}]) ->
    ?MATCH(PingRes, ?APPLY(ping, [IP, Port])),
    case PingRes of
      pang -> ?RET({error, timeout});
      {ok, ID} ->
        ?APPLY(insert_node_gs, [{ID, IP, Port}])
    end;
insert_node_callouts(_S, [{ID, IP, Port} = Node]) ->
    ?MATCH(NodeState, ?APPLY(node_state, [Node])),
    case NodeState of
      not_interesting -> ?RET({not_interesting, Node});
      interesting ->
        ?MATCH(PingRes, ?APPLY(ping, [IP, Port])),
        case PingRes of
          pang -> ?RET({error, timeout});
          {ok, ID} ->
            ?APPLY(insert_node_gs, [{ID, IP, Port}]);
          {ok, _OtherID} ->
            ?RET({error, inconsistent_id})
        end
    end.

%% PING
%% ---------------------
ping_pre(#state { init = S }) -> S.

ping(IP, Port) ->
    dht_state:ping(IP, Port).

ping_args(_S) ->
    [dht_eqc:ip(), dht_eqc:port()].

%% TODO: also generate valid ping responses.
ping_callouts(_S, [IP, Port]) ->
    ?MATCH(R, ?CALLOUT(dht_net, ping, [{IP, Port}], oneof([pang]))),
    case R of
        pang -> ?RET(pang);
        ID ->
            ?APPLY(request_success, [{ID, IP, Port}]),
            ?RET({ok, ID})
    end.

%% REQUEST_SUCCESS
%% ----------------

request_success(Node) ->
    dht_state:request_success(Node).
    
request_success_pre(S) -> initialized(S).

request_success_args(_S) ->
    [dht_eqc:peer()].
    
request_success_callouts(_S, [Node]) ->
    ?MATCH(Member,
      ?CALLOUT(dht_routing_meta, is_member, [Node, rt_ref], bool())),
    case Member of
        false -> ?RET(ok);
        true ->
          ?CALLOUT(dht_routing_meta, refresh_node, [Node, rt_ref], rt_ref),
          ?RET(ok)
    end.

%% REQUEST_TIMEOUT
%% ----------------

request_timeout(Node) ->
    dht_state:request_timeout(Node).
    
request_timeout_pre(S) -> initialized(S).

request_timeout_args(_S) ->
    [dht_eqc:peer()].

request_timeout_callouts(_S, [Node]) ->
    ?MATCH(Member,
      ?CALLOUT(dht_routing_meta, is_member, [Node, rt_ref], bool())),
    case Member of
        false -> ?RET(ok);
        true ->
          ?CALLOUT(dht_routing_meta, node_timeout, [Node, rt_ref], rt_ref),
          ?MATCH(R, ?CALLOUT(dht_routing_meta, node_timer_state, [Node, rt_ref],
              oneof([good, bad, {questionable, nat()}]))),
          case R of
            good -> ?RET(ok);
            {questionable, _} -> ?RET(ok);
            bad ->
              ?CALLOUT(dht_routing_meta, remove_node, [Node, rt_ref], rt_ref),
              ?RET(ok)
          end
    end.

%% REFRESH_NODE
%% ------------------------------

refresh_node(Node) ->
    dht_state:refresh_node(Node).
    
refresh_node_pre(S) -> initialized(S).

refresh_node_args(_S) -> [dht_eqc:peer()].

refresh_node_callouts(_S, [{_, IP, Port} = Node]) ->
    ?MATCH(PingRes, ?APPLY(ping, [IP, Port])),
    case PingRes of
        pang -> ?APPLY(request_timeout, [Node]);
        {ok, _ID} -> ?RET(ok)
    end.

%% NODE_STATE (Internal call)
%% ------------------------------

node_state_callouts(_S, [Node]) ->
    ?MATCH(Member, ?CALLOUT(dht_routing_meta, is_member, [Node, rt_ref], bool())),
    case Member of
        true ->
          ?RET(not_interesting);
        false ->
          ?MATCH(RangeMembers, ?CALLOUT(dht_routing_meta, range_members, [Node, rt_ref],
              list(dht_eqc:peer()))),
          ?MATCH(Inactive, ?CALLOUT(dht_routing_meta, inactive, [RangeMembers, rt_ref],
              oneof([[], [x]]))),
          case (Inactive /= []) orelse ( length(RangeMembers) < ?K ) of
            true -> ?RET(interesting);
            false ->
              ?MATCH(CanInsert,
                  ?CALLOUT(dht_routing_meta, can_insert, [Node, rt_ref], bool())),
              case CanInsert of
                  true -> ?RET(interesting);
                  false -> ?RET(not_interesting)
              end
          end
    end.

%% INSERT_NODE (GenServer Internal Call)
%% --------------------------------

insert_node_gs_callouts(_S, [Node]) ->
    ?MATCH(Insert, ?CALLOUT(dht_routing, insert, [Node, rt_ref],
      oneof([{already_member, rt_ref}, {ok, rt_ref}, {not_inserted, rt_ref}]))),
    case Insert of
      {ok, rt_ref} -> ?RET(true);
      {already_member, rt_ref} -> ?RET(false);
      {not_inserted, rt_ref} -> ?RET(false)
    end.

%% MODEL CLEANUP
%% ------------------------------

reset() ->
	case whereis(dht_state) of
	    undefined -> ok;
	    Pid when is_pid(Pid) ->
	        exit(Pid, kill),
	        timer:sleep(1)
	end,
	ok.

%% PROPERTY
%% -----------------------
postcondition_common(S, Call, Res) ->
    eq(Res, return_value(S, Call)).

prop_state_correct() ->
    ?SETUP(fun() ->
        eqc_mocking:start_mocking(api_spec()),
        fun() -> eqc_mocking:stop_mocking(), ok end
    end,
    ?FORALL(StartState, gen_initial_state(),
    ?FORALL(Cmds, commands(?MODULE, StartState),
        begin
            ok = reset(),
            {H, S, R} = run_commands(?MODULE, Cmds),
            pretty_commands(?MODULE, Cmds, {H, S, R},
                collect(eqc_lib:summary('Length'), length(Cmds),
                aggregate(command_names(Cmds),
                  R == ok)))
        end))).

%% INTERNAL MODEL HELPERS
%% -----------------------

initialized(#state { init = I }) -> I.