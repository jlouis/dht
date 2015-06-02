%% @doc EQC Model for the system state
%% The high-level entry-point for the DHT state. This model implements the public
%% interface for the dht_state gen_server which contains the routing table of the DHT
%%
%% The high-level view is relatively simple to define, since most of the advanced parts
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
%% @end
-module(dht_state_eqc).
-compile(export_all).

-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_component.hrl").

-record(state,{
	init = false, %% true when the model has been initialized
	id %% The NodeID the node is currently running under
}).

-define(K, 8).

%% API SPEC
%% -----------------
%%
%% We call out to the networking layer and also the routing meta-data layer.
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
		  			#api_fun { name = reset_range_timer, arity = 3 },
		  		
		  			#api_fun { name = is_member, arity = 2 },
		  			#api_fun { name = neighbors, arity = 3 },
		  			#api_fun { name = node_list, arity = 1},
		  			#api_fun { name = node_state, arity = 2 },
		  			#api_fun { name = range_members, arity = 2 },
		  			#api_fun { name = range_state, arity = 2}
		  		]
		  	},
		  	#api_module {
		  		name = dht_net,
		  		functions = [
		  			#api_fun { name = find_node, arity = 1 },
		  			#api_fun { name = ping, arity = 1 }
		  		]
		  	}
		  ]
	}.

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

%% Start up a new routing state tracker:
start_link(NodeID, Nodes) ->
    {ok, Pid} = dht_state:start_link(NodeID, no_state_file, Nodes),
    unlink(Pid),
    erlang:is_process_alive(Pid).
    
start_link_pre(S) -> not initialized(S).

start_link_args(#state { id = ID }) ->
    BootStrapNodes = [],
    [ID, BootStrapNodes].

%% Starting the routing state tracker amounts to initializing the routing meta-data layer
start_link_callouts(#state { id = ID }, [ID, []]) ->
    ?CALLOUT(dht_routing_meta, new, [?WILDCARD], {ok, ID, rt_ref}),
    ?RET(true).

%% Once started, we can't start the State system again.
start_link_next(State, _, _) ->
    State#state { init = true }.

%% CLOSEST TO
%% ------------------------

%% Return the `Num` nodes closest to `ID` known to the routing table system.
closest_to(ID, Num) ->
    dht_state:closest_to(ID, Num).
	
closest_to_pre(S) -> initialized(S).

closest_to_args(_S) ->
    [dht_eqc:id(), nat()].
	
%% This call is likewise just served by the underlying system
closest_to_callouts(_S, [ID, Num]) ->
    ?MATCH(Ns, ?CALLOUT(dht_routing_meta, neighbors, [ID, Num, rt_ref],
        list(dht_eqc:peer()))),
    ?RET(Ns).

%% NODE ID
%% ---------------------

%% Request the node ID of the system
node_id() -> dht_state:node_id().

node_id_pre(S) -> initialized(S).
	
node_id_args(_S) -> [].
	
node_id_callouts(#state { id = ID }, []) -> ?RET(ID).

%% INSERT
%% ---------------------

%% Insert either an `{IP, Port}` pair or a known `Node` into the routing table.
%% It is used by calls whenever there is a possibility of adding a new node.
%%
%% The call may block on the network, to execute ping commands, but this model does
%% not encode this behavior.
insert_node(Input) ->
    dht_state:insert_node(Input).
    
insert_node_pre(S) -> initialized(S).

insert_node_args(_S) ->
    Input = oneof([
       {dht_eqc:ip(), dht_eqc:port()},
       dht_eqc:peer()
    ]),
    [Input].

%% The rules split into two variants
%% • an IP/Port pair is first pinged to learn the ID of the pair, and then it is inserted.
%% • A node is assumed to be valid already and is just inserted. If you doubt the validity of
%%   a node, then supply it's IP/Port pair in which case the node will be inserted with a ping.
%%
%% Note that if the gen_server returns `{verify, QuestionableNode}` then that node is being
%% pinged by the call in order to possible refresh this node. And then we recurse. This means
%% there is a behavior where we end up pinging all the nodes in a bucket/range before insertion
%% succeeds/fails.
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

%% Ping a node, updating the response correctly on a succesful pong message
%% TODO: Consider if the pang response should error/timeout the node in question.
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

%% Tell the routing system a node responded succesfully
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

%% Tell the routing system a node did not respond in a timely fashion
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

%% TODO: Consider this call, it may be what `ping` should be in the first place!
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

%% INACTIVE_RANGE (GenServer Message)
%% --------------------------------

%% Refreshing a range proceeds based on the state of that range.
%% • The range is not a member: do nothing
%% • The range is ok: set a new timer for the range.
%%		This sets a timer based on the last activity of the range. In turn, it sets a timer
%%		somewhere between 0 and ?RANGE_TIMEOUT. Ex: The last activity was 5 minutes
%%		ago. So the timer should trigger in 10 minutes rather than 15 minutes.
%% • The range needs refreshing:
%%		refreshing the range amounts to executing a FIND_NODE call on a random ID in the range
%%		which is supplied by the underlying meta-data code. The timer is alway set to 15 minutes
%%		in this case (by a forced set), since we use the timer for progress.

inactive_range(Msg) ->
    dht_state:sync(Msg, 500).

inactive_range_pre(S) -> initialized(S).

inactive_range_args(_S) ->
    [{inactive_range, dht_eqc:range()}].
    
%% Analyze the state of the range and let the result guide what happens.
inactive_range_callouts(_S, [{inactive_range, Range}]) ->
    ?MATCH(RS, ?CALLOUT(dht_routing_meta, range_state, [Range, rt_ref],
        oneof([{error, not_member}, ok, {needs_refresh, dht_eqc:id()}]))),
    case RS of
        {error, not_member} -> ?EMPTY;
        ok ->
            ?CALLOUT(dht_routing_meta, reset_range_timer, [Range, #{ force => false }, rt_ref], rt_ref);
        {needs_refresh, ID} ->
            ?CALLOUT(dht_routing_meta, reset_range_timer, [Range, #{ force => true }, rt_ref], rt_ref),
            ?APPLY(refresh_range, [ID])
    end,
    ?RET(ok).

%% REFRESH_RANGE (Internal private call)

%% This encodes the invariant that once we have found nodes close to the refreshing, they are
%% used as a basis for insertion.
refresh_range_callouts(_S, [ID]) ->
    ?MATCH(FNRes, ?CALLOUT(dht_net, find_node, [ID],
        oneof([{error, timeout}, {dummy, list(dht_eqc:peer())}]))),
    case FNRes of
        {error, timeout} -> ?EMPTY;
        {_, Near} ->
            ?SEQ([?APPLY(insert_node, [N]) || N <- Near])
    end.

%% INSERT_NODE (GenServer Internal Call)
%% --------------------------------

%% Insertion of a node on the gen_server side amounts to analyzing the state of the
%% range/bucket in which the node would fall. We generate random bucket data by
%% means of the following calls:
g_node_state(L) ->
    ?LET(S, vector(length(L), oneof([good, bad, {questionable, largeint()}])),
        lists:zip(L, S)).

bucket_members() ->
    ?SUCHTHAT(L, list(dht_eqc:peer()),
       length(L) =< 8).

%% Given a set of pairs {Node, NodeState} we can analyze them and sort them into
%% the good, bad, and questionable nodes. The sort order matter.
analyze_node_state(Nodes) ->
    GoodNodes = [N || {N, good} <- Nodes],
    BadNodes = lists:sort([N || {N, bad} <- Nodes]),
    QNodes = [{N,T} || {N, {questionable, T}} <- Nodes],
    QSorted = [N || {N, _} <- lists:keysort(2, QNodes)],
    analyze_node_state(BadNodes, GoodNodes, QSorted).
    
%% Provide a view-type for the analyzed node state
analyze_node_state(_Bs, Gs, _Qs) when length(Gs) == ?K -> range_full;
analyze_node_state(Bs ,Gs, Qs) when length(Bs) + length(Gs) + length(Qs) < ?K -> room;
analyze_node_state([B|_], _Gs, _Qs) -> {bad, B};
analyze_node_state([], _, [Q | _Qs]) -> {questionable, Q}.
        
%% Insertion requests the current bucket members, then analyzes the state of the bucket.
%% There are 4 possible cases:
%% • The bucket is full of good nodes—ignore the new node
%% • The bucket has room for another node—insert the new node
%% • The bucket has at least one bad node—swap the new node for the bad node
%% • The bucket has no bad nodes, but a questionable node—verify responsiveness
%%		of the questionable node (by means of interaction with the caller of
%%		insert_node/1)
%%
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