-module(dht_routing_table_eqc).

-compile(export_all).

-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_component.hrl").

-include("dht_eqc.hrl").

-record(state,
    { self,
      init = false,
      tree = #{} }).

api_spec() ->
    #api_spec {
      language = erlang,
      modules = []}.

%% Generators
%% ----------

gen_state() ->
    ?LET(Self, dht_eqc:id(), #state { self = Self }).

initial_state() -> #state {  }.
initial_tree() ->
    K = {?ID_MIN, ?ID_MAX},
    #{ K => [] }.

new(Self) ->
    routing_table:reset(Self).

new_callers() -> [dht_state_eqc, dht_routing_meta_eqc].

new_pre(S) -> not initialized(S).
new_args(_S) -> [dht_eqc:id()].

new_return(_S, [_Self]) -> ok.
new_next(S, _, [Self]) -> S#state { self = Self, init = true, tree = initial_tree() }.

new_features(_S, _, _) -> ["NEW: Created a new routing table"].

%% Insertion of new entries into the routing table
%% -----------------------------------------------
insert(Node, _) ->
    routing_table:insert(Node).

insert_callers() -> [dht_routing_meta_eqc].
insert_pre(S) -> initialized(S).

insert_args(#state {}) ->
    [dht_eqc:peer(), 'ROUTING_TABLE'].
      
insert_pre(#state { self = Self } = S, [{NodeID, _, _} = Node, _]) ->
    (not lists:member(Node, current_nodes(S))) andalso has_space(Node, S) andalso (Self /= NodeID).
    
has_space(Node, #state { self = Self } = S) ->
    {{Lo, Hi}, Members} = find_range({node, Node}, S),
    case length(Members) of
        L when L < ?MAX_RANGE_SZ -> true;
        L when L == ?MAX_RANGE_SZ -> between(Lo, Self, Hi)
    end.

insert_callouts(#state { self = Self } = S, [Node, _]) ->
    {{Lo, Hi}, Members} = find_range({node, Node}, S),
    case length(Members) of
        L when L < ?MAX_RANGE_SZ ->
            ?APPLY(add_node, [Node]),
            ?RET('ROUTING_TABLE');
        L when L == ?MAX_RANGE_SZ ->
            case between(Lo, Self, Hi) of
                true ->
                    ?APPLY(insert_split_range, [Node, 7]),
                    ?RET('ROUTING_TABLE');
                false ->
                    ?FAIL('inserted illegal node')
            end;
        L when L > ?MAX_RANGE_SZ ->
            ?FAIL('range has too many members')
     end.

insert_features(_State, _Args, _Return) ->
    %% TODO: There are more features here, but we don't cover them yet
    ["INSERT001: Insert a new node into the routing table"].

%% Ask the system for the current state table ranges
%% -------------------------------------------------
ranges(_) ->
    routing_table:ranges().

ranges_callers() -> [dht_routing_meta_eqc].

ranges_pre(S) -> initialized(S).

ranges_args(_S) -> ['ROUTING_TABLE'].

%% Range validation is simple. The set of all ranges should form a contiguous
%% space of split ranges. If it doesn't something is wrong.
ranges_return(S, [_Dummy]) ->
    lists:sort(current_ranges(S)).

ranges_features(_S, _A, _Res) ->
    ["RANGES001: Ask for the current ranges in the routing table"].

%% Ask in what range a random ID falls in
%% --------------------------------------
range(ID, _) ->
    routing_table:range(ID).
    
range_callers() -> [dht_routing_meta_eqc].
range_pre(S) -> initialized(S).
range_args(_S) -> [dht_eqc:id(), 'ROUTING_TABLE'].
    
range_return(S, [ID, _Tbl]) ->
    [Range] = [{Lo, Hi} || {Lo, Hi} <- current_ranges(S), between(Lo, ID, Hi)],
    Range.

range_features(_S, _A, _Res) ->
    ["RANGE001: Asking for a range for a random ID"].

%% Delete a node from the routing table
%% If the node is not present, this is a no-op.
%% ------------------------------------
delete(Node, _) ->
    routing_table:delete(Node).
    
delete_callers() -> [dht_routing_meta_eqc].

delete_pre(S) -> initialized(S) andalso has_nodes(S).

nonexisting_node(Ns) ->
  ?SUCHTHAT(Node, dht_eqc:peer(), not lists:member(Node, Ns)).

delete_args(S) ->
    Ns = current_nodes(S),
    Node = frequency(
      lists:append(
    	[{1, nonexisting_node(Ns)}],
    	[{10, elements(Ns)} || Ns /= [] ])),
    [Node, 'ROUTING_TABLE'].
    
delete_next(#state { tree = TR } = S, _, [Node, _]) ->
    {Range, Members} = find_range({node, Node}, S),
    S#state { tree = TR#{ Range := Members -- [Node] } }.

%% TODO: Fix this, as we have to return the routing table itself
delete_return(_S, [_, _]) -> 'ROUTING_TABLE'.

delete_features(S, [Node, _], _R) ->
    case lists:member(Node, current_nodes(S)) of
        true -> ["DELETE001: Delete an existing node from the routing table"];
        false -> ["DELETE002: Delete a non-existing node from the routing table"]
    end.

%% Ask for members of a given ID
%% Currently, we only ask for existing members, but this could also fault-inject
%% -----------------------------
members(Node, _) ->
    lists:sort(routing_table:members(Node)).

nonexisting_id(IDs) ->
  ?SUCHTHAT({ID, _, _}, dht_eqc:peer(),
      not lists:member(ID, IDs)).

members_callers() -> [dht_routing_meta_eqc].

members_pre(S) -> initialized(S).

%% TODO: Ask for ranges here as well!
members_args(S) ->
    Ns = current_nodes(S),
    Node = frequency(
      lists:append(
    	[{1, nonexisting_id(ids(Ns))}],
    	[{10, elements(Ns)} || Ns /= [] ])),
    [{node, Node}, 'ROUTING_TABLE'].

members_return(S, [Node, _]) ->
    {_, Members} = find_range(Node, S),
    lists:sort(Members).

members_post(_S, _A, Res) -> length(Res) =< 8.
    
members_features(S, [{node, Node}, _], _Res) ->
    case lists:member(Node, ids(current_nodes(S))) of
        true -> ["MEMBERS001: Members on a node which has an existing ID"];
        false -> ["MEMBERS002: Members of a non-existing node"]
    end.

%% Ask for membership of the Routing Table
%% ---------------------------------------
is_member(Node, _) ->
    routing_table:is_member(Node).

is_member_callers() -> [dht_routing_meta_eqc].

is_member_pre(S) ->
    initialized(S) andalso has_nodes(S).

is_member_args(S) ->
    Node = oneof([
        elements(current_nodes(S)),
        dht_eqc:peer()
    ]),
    [Node, 'ROUTING_TABLE'].

is_member_return(S, [N, _]) ->
    lists:member(N, current_nodes(S)).

is_member_features(S, [N, _], _Res) ->
    case lists:member(N, current_nodes(S)) of
      true -> ["IS_MEMBER001: is_member on existing node"];
      false -> ["IS_MEMBER002: is_member on nonexisting node"]
    end.

%% Ask for the node id
%% --------------------------
node_id(_) ->routing_table:node_id().
    
node_id_callers() -> [dht_routing_meta_eqc].

node_id_pre(S) -> initialized(S).

node_id_args(_S) -> ['ROUTING_TABLE'].

node_id_return(#state { self = Self }, _) -> Self.

node_id_features(_S, [_], _R) ->
    ["NODE_ID001: Asked for the node ID"].

%% Ask for the node list
%% -----------------------
node_list(_) ->
    lists:sort(
    	routing_table:node_list() ).
    
node_list_callers() -> [dht_routing_meta_eqc].

node_list_pre(S) -> initialized(S).

node_list_args(_S) -> ['ROUTING_TABLE'].
    
node_list_return(S, [_], _) ->
    lists:sort(current_nodes(S)).

node_list_features(_S, _A, _R) ->
    ["NODE_LIST001: Asking for the current node list"].

%% Ask if the routing table has a bucket
%% -------------------------------------
is_range(B, _) ->
    routing_table:is_range(B).
    
is_range_callers() -> [dht_routing_meta_eqc].

is_range_pre(S) -> initialized(S).

is_range_args(S) ->
    Rs = current_ranges(S),
    Range = oneof([elements(Rs), dht_eqc:range()]),
    [Range, 'ROUTING_TABLE'].

is_range_return(S, [Range, _]) ->
    lists:member(Range, current_ranges(S)).

is_range_features(_S, _, true) -> ["IS_RANGE001: Existing range"];
is_range_features(_S, _, false) -> ["IS_RANGE002: Non-existing range"].

%% Ask who is closest to a given ID
%% --------------------------------
closest_to(ID, F, Num, _) ->
    lists:sort(
      routing_table:closest_to(ID, F, Num) ).
    
closest_to_callers() -> [dht_routing_meta_eqc].

closest_to_pre(S) -> initialized(S).

%%closest_to_args(_S) ->
%%    [dht_eqc:id(), function1(bool()), nat(), 'ROUTING_TABLE'].

closest_to_return(S, [TargetID, _, N, _]) ->
    Ns = current_nodes(S),
    D = fun({ID, _IP, _Port}) -> dht_metric:d(TargetID, ID) end,
    Sorted = lists:sort(fun(X, Y) -> D(X) =< D(Y) end, Ns),
    take(N, Sorted).
    
take(0, _) -> [];
take(_, []) -> [];
take(K, [X|Xs]) when K > 0 -> [X | take(K-1, Xs)].

closest_to_features(_S, _A, _R) ->
    ["CLOSEST_TO: Asking for the N nodes closest to an ID"].

%% INSERT_SPLIT_RANGE / SPLIT_RANGE (Internal calls)

insert_split_range_callouts(_S, [_, 0]) ->
    ?FAIL('recursion depth');
insert_split_range_callouts(#state { self = Self } = S, [Node, K]) ->
    {{Lo, Hi}, Members} = find_range({node, Node}, S),
    case length(Members) of
        L when L < ?MAX_RANGE_SZ ->
            ?APPLY(add_node, [Node]);
        L when L == ?MAX_RANGE_SZ ->
            case between(Lo, Self, Hi) of
                true ->
                    ?APPLY(split_range, [{Lo, Hi}]),
                    ?APPLY(insert_split_range, [Node, K-1]);
                false ->
                    ?FAIL('impossible insert_split_range')
            end
     end.

split_range_callouts(_S, [{0, 1}]) -> ?FAIL('range too small to split');
split_range_callouts(_S, [_Range]) -> ?EMPTY.

split_range_next(#state { tree = TR } = S, _, [{Lo, Hi} = Range]) ->
    Members = maps:get(Range, TR),
    Half = (Hi - Lo) bsr 1,
    {Lower, Upper} = lists:partition(fun({ID, _, _}) -> ID < Half end, Members),
    SplitTree = (maps:remove(Range, TR))#{ {Lo, Half} => Lower, {Half, Hi} => Upper },
    S#state { tree = SplitTree }.

%% ADD_NODE (Internal call)
%% ----------------------------------

add_node_next(#state { tree = TR } = S, _, [Node]) ->
    {Range, Members} = find_range({node, Node}, S),
    S#state { tree = TR#{ Range := [Node | Members] } }.

%% Invariant
%% ---------
%%
%% Initialized routing tables support the following invariants:
%%
%% • No bucket has more than 8 members
%% • Buckets can't overlap
%% • Members of a bucket share a property: a common prefix
%% • The common prefix is given by the depth/width of the bucket
invariant(#state { init = false }) -> true;
invariant(#state { init = true }) -> routing_table:invariant().

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

%% Use a common postcondition for all commands, so we can utilize the valid return
%% of each command.
postcondition_common(S, Call, Res) ->
    eq(Res, return_value(S, Call)).

prop_component_correct() ->
    ?SETUP(fun() -> ok, fun() -> ok end end,
    ?FORALL(Cmds, commands(?MODULE),
      begin
        {H, S, R} = run_commands(?MODULE, Cmds),
        pretty_commands(?MODULE, Cmds, {H, S, R},
            aggregate(with_title('Commands'), command_names(Cmds),
            collect(eqc_lib:summary('Length'), length(Cmds),
            aggregate(eqc_statem:call_features(H),
            features(eqc_statem:call_features(H),
                R == ok)))))
      end)).

t() -> t(5).

t(Time) ->
    eqc:quickcheck(eqc:testing_time(Time, eqc_statem:show_states(prop_component_correct()))).

%% Internal functions
%% ------------------

has_nodes(S) -> current_nodes(S) /= [].

ids(Nodes) -> [ID || {ID, _, _} <- Nodes].

tree(#state { tree = T }) -> T.
current_nodes(#state { tree = TR }) -> lists:append(maps:values(TR)).
current_ranges(#state { tree = TR }) -> maps:keys(TR).

find_range({node, {ID, _, _}}, S) ->
    [{Range, Members}] = maps:to_list(maps:filter(fun({Lo, Hi}, _) -> between(Lo, ID, Hi) end, tree(S))),
    {Range, Members}.

between(L, X, H) when L =< X, X < H -> true;
between(_, _, _) -> false.
