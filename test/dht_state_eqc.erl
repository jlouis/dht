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
%%
%% • Correctly call node_touch/3, not node_touch/2!
%%
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
		  			#api_fun { name = new, arity = 1 },
		  			#api_fun { name = export, arity = 1 },
		  			
		  			#api_fun { name = insert, arity = 2 },
		  			#api_fun { name = replace, arity = 3 },
		  			#api_fun { name = remove, arity = 2 },
		  			#api_fun { name = node_touch, arity = 3 },
		  			#api_fun { name = node_timeout, arity = 2 },
		  			#api_fun { name = refresh_range, arity = 2 },
		  		

		  			#api_fun { name = is_member, arity = 2 },
		  			#api_fun { name = neighbors, arity = 3 },
		  			#api_fun { name = node_list, arity = 1},
		  			#api_fun { name = node_state, arity = 2 },
		  			#api_fun { name = range_members, arity = 2 }
		  		]
		  	},
		  	#api_module {
		  		name = dht_net,
		  		functions = [
		  			#api_fun { name = ping, arity = 1 }
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
insert_node(Input) ->
    dht_state:insert_node(Input).
    
insert_node_pre(S) -> initialized(S).

insert_node_args(_S) ->
    N = ?LET({_ID, IP, Port} = N, dht_eqc:peer(), oneof([ {IP, Port}, N ])),
    [N].

insert_node_callouts(_S, [{IP, Port}]) ->
    ?MATCH(R, ?APPLY(ping, [IP, Port])),
    case R of
        pang -> ?RET({error, noreply});
        {ok, ID} -> ?APPLY(insert_node, [{ID, IP, Port}])
    end;
insert_node_callouts(_S, [Node]) ->
    ?MATCH(NodeState, ?APPLY(insert_node_gs, [Node])),
    case NodeState of
        ok -> ?RET(ok);
        {error, Reason} -> ?RET({error, Reason});
        {verify, QN} ->
            ?APPLY(refresh_node, [QN]),
            ?APPLY(insert_node, [Node])
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

request_success(Node, Opts) ->
    dht_state:request_success(Node, Opts).
    
request_success_pre(S) -> initialized(S).

request_success_args(_S) ->
    [dht_eqc:peer(), #{ reachable => bool() }].
    
request_success_callouts(_S, [Node, Opts]) ->
    ?MATCH(Member,
      ?CALLOUT(dht_routing_meta, is_member, [Node, rt_ref], bool())),
    case Member of
        false -> ?RET(ok);
        true ->
          ?CALLOUT(dht_routing_meta, node_touch, [Node, Opts, rt_ref], rt_ref),
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
          ?RET(ok)
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

%% INSERT_NODE (GenServer Internal Call)
%% --------------------------------

g_node_state(L) ->
    ?LET(S, vector(length(L), oneof([good, bad, {questionable, largeint()}])),
        lists:zip(L, S)).

analyze_node_state(Nodes) ->
    GoodNodes = [N || {N, good} <- Nodes],
    BadNodes = lists:sort([N || {N, bad} <- Nodes]),
    QNodes = [{N,T} || {N, {questionable, T}} <- Nodes],
    QSorted = [N || {N, _} <- lists:keysort(2, QNodes)],
    analyze_node_state(BadNodes, GoodNodes, QSorted).
    
analyze_node_state(_Bs, Gs, _Qs) when length(Gs) == ?K -> range_full;
analyze_node_state(Bs ,Gs, Qs) when length(Bs) + length(Gs) + length(Qs) < ?K -> room;
analyze_node_state([B|_], _Gs, _Qs) -> {bad, B};
analyze_node_state([], _, [Q | _Qs]) -> {questionable, Q}.
        
bucket_members() ->
    ?SUCHTHAT(L, list(dht_eqc:peer()),
       length(L) =< 8).

insert_node_gs_callouts(_S, [Node]) ->
    ?MATCH(Near, ?CALLOUT(dht_routing_meta, range_members, [Node, rt_ref],
        bucket_members())),
    ?MATCH(NodeState, ?CALLOUT(dht_routing_meta, node_state, [Near, rt_ref],
        g_node_state(Near))),
    R = analyze_node_state(NodeState),
    case R of
        range_full -> ?RET(range_full);
        room ->
            %% TODO: Alter the return here so it is also possible to fail
            ?CALLOUT(dht_routing_meta, insert, [Node, rt_ref], {ok, rt_ref}),
            ?RET(ok);
        {bad, Bad} ->
            ?CALLOUT(dht_routing_meta, replace, [Bad, Node, rt_ref], {ok, rt_ref}),
            ?RET(ok);
        {questionable, Q} -> ?RET({verify, Q})
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