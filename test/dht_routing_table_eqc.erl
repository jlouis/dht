-module(dht_routing_table_eqc).

-compile(export_all).

-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_component.hrl").

-record(state,
	{ self,
	  init = false,
	  nodes = [],
	  deleted = []
    }).

api_spec() ->
    #api_spec {
      language = erlang,
      modules = []}.

%% Generators
%% ----------

g_range() ->
    MaxID = 1 bsl 160,
    g_range(0, MaxID).
    
g_range(Low, High) when High - Low < 8 -> return({Low, High});
g_range(Low, High) ->
  Diff = High - Low,
  Half = High - (Diff div 2),

  frequency([
    {1, return({Low, High})},
    {8, ?SHRINK(
            oneof([
                ?LAZY(g_range(Half, High)),
                ?LAZY(g_range(Low, Half))]),
            [return({Low, High})])}
  ]).

gen_state() ->
    ?LET(Self, dht_eqc:id(),
        #state { self = Self }).

initial_state() ->
	#state {  }.

new(Self) ->
    routing_table:reset(Self).

new_callers() -> [dht_state_eqc, dht_routing_meta_eqc].
new_pre(S) -> not initialized(S).
new_args(_S) -> [dht_eqc:id()].

new_return(_S, [_Self]) -> ok.
new_next(S, _, _) -> S#state { init = true }.

%% Insertion of new entries into the routing table
%% -----------------------------------------------
insert(Node, _) ->
	routing_table:insert(Node).

insert_callers() -> [dht_routing_meta_eqc].
insert_pre(S) -> initialized(S).

insert_args(#state {}) ->
    [dht_eqc:peer(), dummy].
	  
insert_next(#state { nodes = Nodes } = State, _V, [Node, _]) ->
    State#state { nodes = Nodes ++ [Node] }.

insert_features(_State, _Args, _Return) ->
    ["R001: Insert a new node into the routing table"].

%% Ask the system for the current state table ranges
%% -------------------------------------------------
ranges(_) ->
	routing_table:ranges().

ranges_callers() -> [dht_routing_meta_eqc].
ranges_pre(S) -> initialized(S).
ranges_args(_S) -> [dummy].

%% Range validation is simple. The set of all ranges should form a contiguous
%% space of split ranges. If it doesn't something is wrong.
ranges_post(#state {}, [_Dummy], Ranges) ->
	contiguous(Ranges).

ranges_features(_S, _A, _Res) ->
	["R002: Ask for the current routing table ranges"].

%% Ask in what range a random ID falls in
%% --------------------------------------
range(ID, _) ->
	routing_table:range(ID).
	
range_callers() -> [dht_routing_meta_eqc].
range_pre(S) -> initialized(S).
range_args(_S) -> [dht_eqc:id(), dummy].
	
range_features(_S, _A, _Res) ->
	["R003: Asking for a range for a random ID"].

%% Delete a node from the routing table
%% If the node is not present, this is a no-op.
%% ------------------------------------
delete(Node, _) ->
	routing_table:delete(Node).
	
delete_callers() -> [dht_routing_meta_eqc].
delete_pre(S) -> initialized(S) andalso has_nodes(S).

nonexisting_node(Ns) ->
  ?SUCHTHAT(Node, {dht_eqc:id(), dht_eqc:ip(), dht_eqc:port()},
      not lists:member(Node, Ns)).

delete_args(#state { nodes = Ns}) ->
	Node = frequency(
		[{1, nonexisting_node(Ns)}] ++
		[{10, elements(Ns)} || Ns /= [] ]),
	[Node, dummy].
	
delete_next(#state { nodes = Ns, deleted = Ds } = State, _, [Node, _]) ->
    case lists:member(Node, Ns) of
        true -> State#state { nodes = lists:delete(Node, Ns), deleted = Ds ++ [Node] };
        false -> State
    end.

delete_features(#state { nodes = Ns }, [Node, _], _R) ->
    case lists:member(Node, Ns) of
        true -> ["R004: Delete an existing node from the routing table"];
        false -> ["R005: Delete a non-existing node from the routing table"]
    end.

%% Ask for members of a given ID
%% Currently, we only ask for existing members, but this could also fault-inject
%% -----------------------------
members(Node, _) ->
	routing_table:members(Node).

nonexisting_id(IDs) ->
  ?SUCHTHAT({ID, _, _}, dht_eqc:peer(),
      not lists:member(ID, IDs)).

members_callers() -> [dht_routing_meta_eqc].
members_pre(S) -> initialized(S).

members_args(#state { nodes = Ns }) ->
    Node = frequency(
    	[{1, nonexisting_id(ids(Ns))}] ++
    	[{10, elements(Ns)} || Ns /= [] ]),
    [{node, Node}, dummy].

members_post(_S, _A, Res) -> length(Res) =< 8.
    
members_features(#state { nodes = Ns }, [{node, Node}, _], _Res) ->
    case lists:member(Node, ids(Ns)) of
        true -> ["R006: Members of an existing ID"];
        false -> ["R007: Members of a non-existing ID"]
    end.

%% Ask for membership of the Routing Table
%% ---------------------------------------
is_member(Node, _) ->
    routing_table:is_member(Node).

is_member_callers() -> [dht_routing_meta_eqc].
is_member_pre(S) ->
	initialized(S) andalso (has_nodes(S) orelse has_deleted_nodes(S)).

is_member_args(#state { nodes = Ns, deleted = DNs }) ->
	[elements(Ns ++ DNs), dummy].

is_member_post(#state { deleted = DNs }, [N, _], Res) ->
    case lists:member(N, DNs) of
      true -> Res == false;
      false -> true
    end.

is_member_features(#state { deleted = DNs}, [N, _], _Res) ->
    case lists:member(N, DNs) of
      true -> ["R008: is_member on deleted node"];
      false -> ["R009: is_member on an existing node"]
    end.

%% Ask for the node id
%% --------------------------
node_id(_) ->routing_table:node_id().
    
node_id_callers() -> [dht_routing_meta_eqc].
node_id_pre(S) -> initialized(S).
node_id_args(_S) -> [dummy].
node_id_return(#state { self = Self }, _) -> Self.

%% Ask for the node list
%% -----------------------
node_list(_) ->
    routing_table:node_list().
    
node_list_callers() -> [dht_routing_meta_eqc].
node_list_pre(S) -> initialized(S).

node_list_args(_S) -> [dummy].
	
node_list_post(#state { nodes = Ns }, _Args, RNs) ->
	is_subset(RNs, Ns).

node_list_features(_S, _A, _R) ->
	["R010: Asking for the current node list"].

%% Ask if the routing table has a bucket
%% -------------------------------------
is_range(B, _) ->
	routing_table:is_range(B).
	
is_range_callers() -> [dht_routing_meta_eqc].
is_range_pre(S) -> initialized(S).
is_range_args(_S) -> [g_range(), dummy].

is_range_features(_S, _A, true) -> ["R011: Asking for a bucket which exists"];
is_range_features(_S, _A, false) -> ["R012: Asking for a bucket which does not exist"].

%% Ask who is closest to a given ID
%% --------------------------------
closest_to(ID, _, Num, _) ->
	routing_table:closest_to(ID, fun(_X) -> true end, Num).
	
closest_to_callers() -> [dht_routing_meta_eqc].
closest_to_pre(S) -> initialized(S).

closest_to_args(#state { }) ->
	[dht_eqc:id(), dummy, nat(), dummy].

closest_to_features(_S, _A, _R) ->
	["R013: Asking for the nodes closest to another node"].

%% Currently skipped commands
%% closest_to(ID, Self, Buckets, Filter, Num)/5

%% Invariant
%% ---------
%%
%% • No bucket has more than 8 members
%% • Buckets can't overlap
%% • Members of a bucket share a property: a common prefix
%% • The common prefix is given by the depth/width of the bucket
invariant(#state { init = false }) -> true;
invariant(#state { init = true }) ->
    routing_table:invariant().

%% Weights
%% -------
%%
%% It is more interesting to manipulate the structure than it is to query it:
weight(_S, insert) -> 3;
weight(_S, delete) -> 3;
weight(_S, _Cmd) -> 1.

%% Properties
%% ----------
self(#state { self = S }) -> S.

initialized(#state { init = I }) -> I.

prop_seq() ->
    ?SETUP(fun() -> ok, fun() -> ok end end,
    ?FORALL(Cmds, commands(?MODULE),
      begin
        {H, S, R} = run_commands(?MODULE, Cmds),
        pretty_commands(?MODULE, Cmds, {H, S, R},
            aggregate(with_title('Commands'), command_names(Cmds),
            collect(eqc_lib:summary('Length'), length(Cmds),
                R == ok)))
      end)).

t() ->
    eqc:quickcheck(eqc_statem:show_states(prop_seq())).

%% Internal functions
%% ------------------

contiguous([]) -> true;
contiguous([{_Min, _Max}]) -> true;
contiguous([{_Low, M1}, {M2, High} | T]) when M1 == M2 -> contiguous([{M2, High} | T]);
contiguous([X, Y | _T]) -> {error, X, Y}.

has_nodes(#state { nodes = [] }) -> false;
has_nodes(#state { nodes = [_|_] }) -> true.

has_deleted_nodes(#state { deleted = [] }) -> false;
has_deleted_nodes(#state { deleted = [_|_] }) -> true.

ids(Nodes) ->
  [ID || {ID, _, _} <- Nodes].

is_subset([X | Xs], Set) -> lists:member(X, Set) andalso is_subset(Xs, Set);
is_subset([], _Set) -> true.
