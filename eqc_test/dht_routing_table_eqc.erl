-module(dht_routing_table_eqc).

-compile(export_all).

-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_statem.hrl").

-record(state,
	{ self,
	  nodes = [],
	  deleted = []
    }).

initial_state() ->
	#state{ self = dht_eqc:id() }.

%% Insertion of new entries into the routing table
%% -----------------------------------------------
insert(Self, {ID, IP, Port}) ->
	routing_table:insert(Self, {ID, IP, Port}).
	
insert_args(#state { self = Self }) ->
	?LET({ID, IP, Port}, {dht_eqc:id(), dht_eqc:ip(), dht_eqc:port()},
	  [Self, {ID, IP, Port}]).
	  
insert_next(#state { nodes = Nodes } = State, _V, [_Self, Node]) ->
	State#state { nodes = Nodes ++ [Node] }.

%% Ask the system for the current state table ranges
%% -------------------------------------------------
ranges() ->
	routing_table:ranges().
	
ranges_args(_S) ->
	[].

%% Range validation is simple. The set of all ranges should form a contiguous
%% space of split ranges. If it doesn't something is wrong.
ranges_post(#state {}, [], Ranges) ->
	contiguous(Ranges).

%% Ask in what range a random ID falls in
%% --------------------------------------
range(ID, Self) ->
	routing_table:range(ID, Self).
	
range_args(#state { self = Self }) ->
	[dht_eqc:id(), Self].
	
%% Delete a node from the routing table
%% In this case, the node does not exist
%% ------------------------------------
delete_not_existing(Node, Self) ->
	routing_table:delete(Node, Self).
	
delete_not_existing_args(#state { self = Self}) ->
	?LET({ID, IP, Port}, {dht_eqc:id(), dht_eqc:ip(), dht_eqc:port()},
	  [{ID, IP, Port}, Self]).
	  
delete_not_existing_pre(#state { nodes = Ns }, [N, _]) ->
    not lists:member(N, Ns).

%% Delete a node from the routing table
%% In this case, the node does exist in the table
%% ------------------------------------
delete(Node, Self) ->
	routing_table:delete(Node, Self).
	
delete_pre(S) ->
	has_nodes(S).

delete_args(#state { self = Self, nodes = Ns}) ->
	[elements(Ns), Self].
	
delete_next(#state { nodes = Ns, deleted = Ds } = State, _, [Node, _]) ->
	State#state {
		nodes = lists:delete(Node, Ns),
		deleted = Ds ++ [Node]
	}.

%% Ask for members of a given ID
%% Currently, we only ask for existing members, but this could also fault-inject
%% -----------------------------
members(ID, Self) ->
	routing_table:members(ID, Self).

members_pre(S) ->
    has_nodes(S).

members_args(#state { nodes = Ns, self = Self }) ->
	[elements(ids(Ns)), Self].

members_post(#state{}, [_ID, _], Res) ->
	length(Res) =< 8.

%% Ask for membership of the Routing Table
%% ---------------------------------------
is_member(Node, Self) ->
	routing_table:is_member(Node, Self).

is_member_pre(S) ->
	has_nodes(S) orelse has_deleted_nodes(S).

is_member_args(#state { nodes = Ns, deleted = DNs, self = Self }) ->
	[elements(Ns ++ DNs), Self].

is_member_post(#state { deleted = DNs }, [N, _], Res) ->
    case lists:member(N, DNs) of
      true ->
        %% Among the deleted nodes, must never be in the routing table
        Res == false;
      false ->
        %% Not among the deleted nodes, can be a subset so this is always ok
        true
    end.

%% Ask for the node list
%% -----------------------
node_list() ->
    routing_table:node_list().
    
node_list_args(_S) ->
	[].
	
node_list_post(#state { nodes = Ns }, _Args, RNs) ->
	is_subset(RNs, Ns).

%% Currently skipped commands
%% has_bucket/2
%% closest_to(ID, Self, Buckets, Filter, Num)/5
%% node_list/0 - easy to implement

%% Invariant
%% ---------
%%
%% · No bucket has more than 8 members
%% · Buckets can't overlap
%% · Members of a bucket share a property: a common prefix
%% · The common prefix is given by the depth/width of the bucket
invariant(_S) ->
	routing_table:invariant().


%% Properties
%% ----------

prop_seq() ->
    ?SETUP(fun() ->
        ok,
        fun() -> ok end
      end,
    ?FORALL(Cmds, commands(?MODULE),
      begin
        ok = routing_table:reset(),
        {H, S, R} = run_commands(?MODULE, Cmds),
        aggregate(command_names(Cmds),
          pretty_commands(?MODULE, Cmds, {H, S, R}, R == ok))
      end)).

%% Internal functions
%% ------------------

contiguous([]) -> true;
contiguous([{_Min, _Max}]) -> true;
contiguous([{_Low, M1}, {M2, High} | T]) when M1 == M2 ->
  contiguous([{M2, High} | T]);
contiguous([X, Y | _T]) ->
  {error, X, Y}.

has_nodes(#state { nodes = [] }) -> false;
has_nodes(#state { nodes = [_|_] }) -> true.

has_deleted_nodes(#state { deleted = [] }) -> false;
has_deleted_nodes(#state { deleted = [_|_] }) -> true.

ids(Nodes) ->
  [ID || {ID, _, _} <- Nodes].

is_subset([X | Xs], Set) ->
    lists:member(X, Set) andalso is_subset(Xs, Set);
is_subset([], _Set) -> true.
